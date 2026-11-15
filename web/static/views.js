/* views.js — presentation registry for tool-call results.
 *
 * The canonical {ok,data}/{error} envelope that reaches the model stays
 * untouched (it's what the model reads back). This module decides how the *human*
 * reads it: a tool declares a "view" (in its manifest), the server ships a name->view
 * map (window.CERISIER_VIEWS), and this registry turns (name, args, result) into
 * readable HTML. Common kinds live here; a tool may also ship its own renderer file
 * (a "custom kind") which self-registers via CerisierViews.register — loaded lazily.
 *
 * A view declares how to render two independent slots of a card:
 *   "view": {
 *     "renderer": "tools/scripts/foo.view.js",   // optional file this tool ships
 *     "args":   { "kind": "diff" },              // optional; default "json"
 *     "result": { "kind": "text", "field": "content" }  // optional; default "json"
 *   }
 * A slot kind not in the built-in registry is a custom kind: its renderer file (the
 * tool's "renderer") is loaded on demand, registers the kind, and the slot re-renders.
 *
 * API (window.CerisierViews):
 *   register(kind, fn)            fn(ctx, spec) -> HTML string; ctx =
 *         { name, target: 'args'|'result', data, argsJson, args, resultJson, ok, status }
 *   renderArgs(name, argsJson)    -> HTML string for the args slot
 *   renderResult(name, resultJson, status) -> HTML string for the result slot
 *   processReload(logEl)          post-process server-rendered history <pre> blocks
 */
(function (global) {
'use strict';

const esc = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const escAttr = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function humanSize(n) {
  if (n == null || typeof n !== 'number') return '';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1024 / 1024).toFixed(1) + ' MB';
}

/* ------------------------------------------------------------------ */
/* Line diff (reused by the "diff" kind). Deletions/additions share    */
/* rich.js's palette via the existing .tool-diff / .drow CSS.          */
/* ------------------------------------------------------------------ */
function lineDiff(oldText, newText) {
  const a = oldText.split('\n'), b = newText.split('\n');
  const n = a.length, m = b.length;
  const dp = new Array(n + 1);
  for (let i = 0; i <= n; i++) dp[i] = new Uint32Array(m + 1);
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i + 1][j + 1]);
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push({ op: ' ', t: a[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ op: '-', t: a[i] }); i++; }
    else { ops.push({ op: '+', t: b[j] }); j++; }
  }
  while (i < n) { ops.push({ op: '-', t: a[i++] }); }
  while (j < m) { ops.push({ op: '+', t: b[j++] }); }
  return ops;
}
function diffGap(skipped) {
  return '<span class="drow dgap">' + skipped + ' unchanged line' + (skipped === 1 ? '' : 's') + '</span>';
}
function diffBodyHtml(ops) {
  const CTX = 2;
  const keep = new Array(ops.length).fill(false);
  for (let k = 0; k < ops.length; k++) {
    if (ops[k].op === ' ') continue;
    const lo = Math.max(0, k - CTX), hi = Math.min(ops.length, k + CTX + 1);
    for (let u = lo; u < hi; u++) keep[u] = true;
  }
  let html = '', gaps = 0;
  for (let k = 0; k < ops.length; k++) {
    if (!keep[k]) { gaps++; continue; }
    if (gaps > 0) { html += diffGap(gaps); gaps = 0; }
    const o = ops[k];
    html += '<span class="drow d' + (o.op === ' ' ? 'ctx' : o.op) + '">' + o.op + esc(o.t) + '</span>';
  }
  if (gaps > 0) html += diffGap(gaps);
  return html;
}

/* ------------------------------------------------------------------ */
/* Built-in kinds. Each: fn(ctx, spec) -> HTML string.                 */
/* ctx.data is the slot value: for args it's the parsed args object    */
/* (or raw string if unparseable); for result it's the envelope's data */
/* (or the raw string if the envelope isn't JSON).                     */
/* ------------------------------------------------------------------ */
const KINDS = {};

function pre(text, cls) {
  if (text === '' || text == null) return '';
  return '<pre class="tool-view tool-view-' + cls + '">' + text + '</pre>';
}
function headerLine(v) {
  return v == null || v === '' ? '' : '<div class="tool-view-header">' + esc(String(v)) + '</div>';
}
function metaLine(parts) {
  const s = parts.filter(Boolean).join(' ');
  return s ? '<div class="tool-view-meta">' + s + '</div>' : '';
}
function errorPre(text) {
  if (text == null || text === '') return '';
  return '<pre class="tool-view tool-view-error">' + esc(String(text)) + '</pre>';
}
function jsonValue(v) {
  if (typeof v === 'string') return v === '' ? '' : esc(v);
  if (v == null) return '';
  return esc(JSON.stringify(v, null, 2));
}

KINDS.json = function (ctx) {
  if (ctx.target === 'result' && !ctx.ok) return errorPre(ctx.error);
  const v = ctx.data;
  if (ctx.target === 'args' && v && typeof v === 'object' && !Array.isArray(v)) {
    if (Object.keys(v).length === 0) return ''; // no args -> nothing to show
  }
  return pre(jsonValue(v), 'json');
};

KINDS.text = function (ctx, spec) {
  if (ctx.target === 'result' && !ctx.ok) return errorPre(ctx.error);
  const field = spec.field;
  let val;
  if (field && ctx.data && typeof ctx.data === 'object') val = ctx.data[field];
  else val = ctx.data;
  const d = (ctx.data && typeof ctx.data === 'object') ? ctx.data : {};
  let head = '';
  if (spec.status && d[spec.status] !== undefined) {
    const ec = d[spec.status];
    head = '<div class="tool-view-status ' + (ec === 0 ? 'ok' : 'bad') + '">exit ' + esc(String(ec)) + '</div>';
  }
  const note = (spec.note && d[spec.note]) ? '<span class="tool-view-note">truncated</span>' : '';
  const body = (typeof val === 'string') ? (val === '' ? '' : esc(val)) : jsonValue(val);
  if (body === '') return headerLine(d[spec.header]) + head + metaLine([note]);
  return headerLine(d[spec.header]) + head + metaLine([note]) + pre(body, 'text');
};

function fmtCell(v, fmt) {
  if (v == null) return '';
  if (fmt === 'size') return esc(humanSize(v));
  if (fmt === 'type') {
    if (v === 'dir') return '📁 dir';
    if (v === 'file') return '📄 file';
    return esc(String(v));
  }
  return esc(String(v));
}

KINDS.table = function (ctx, spec) {
  if (ctx.target === 'result' && !ctx.ok) return errorPre(ctx.error);
  const d = (ctx.data && typeof ctx.data === 'object') ? ctx.data : {};
  const rows = Array.isArray(d[spec.rows]) ? d[spec.rows] : [];
  const cols = spec.columns || [];
  const headRow = cols.map((c) => '<th>' + esc(c.label || c.field) + '</th>').join('');
  const body = rows.map((r) =>
    '<tr>' + cols.map((c) => '<td>' + fmtCell(r ? r[c.field] : '', c.format) + '</td>').join('') + '</tr>'
  ).join('');
  const cnt = (spec.count && d[spec.count] != null) ? (d[spec.count] + ' items') : '';
  const note = (spec.note && d[spec.note]) ? '<span class="tool-view-note">truncated</span>' : '';
  return headerLine(d[spec.header]) + metaLine([cnt, note]) +
    '<table class="tool-view tool-view-table"><thead><tr>' + headRow + '</tr></thead><tbody>' + body + '</tbody></table>';
};

KINDS.diff = function (ctx, spec) {
  const b = spec.bindings || {};
  const oldF = b.old || 'old', newF = b.new || 'new', pathF = b.path || 'path', cntF = b.count || 'count';
  const src = ctx.data;
  if (!src || typeof src !== 'object') return KINDS.json(ctx); // can't diff -> raw args
  const o = src[oldF], n = src[newF];
  if (typeof o !== 'string' || typeof n !== 'string') return KINDS.json(ctx);
  if (o === n) return KINDS.json(ctx); // nothing changed
  const ops = lineDiff(o, n);
  const body = diffBodyHtml(ops);
  if (!body) return KINDS.json(ctx);
  let meta = '';
  if (typeof src[cntF] === 'number') meta = ' · ' + src[cntF] + ' replacement' + (src[cntF] === 1 ? '' : 's');
  const head = '<div class="tdiff-head"><span class="tdiff-path">' + esc(String(src[pathF] || '')) +
    '</span><span class="tdiff-meta">' + meta + '</span></div>';
  return '<div class="tool-diff">' + head + '<div class="tdiff-body">' + body + '</div></div>';
};

KINDS.search = function (ctx, spec) {
  const d = ctx.data;
  if (!d || typeof d !== 'object' || !d.source) return KINDS.json(ctx);
  const rich = global.CerisierRich;
  if (!rich || typeof rich.searchCardsHtml !== 'function') return KINDS.json(ctx);
  const store = global.CERISIER_SEARCH_RESULTS || {};
  if (!store[d.source]) store[d.source] = d;
  return rich.searchCardsHtml(d.source);
};

/* ------------------------------------------------------------------ */
/* Envelope + context helpers                                          */
/* ------------------------------------------------------------------ */
function parseEnvelope(raw) {
  // -> { ok, data, error } for a result slot. Non-JSON raw is treated as a
  //    plain-text payload (success unless the card says otherwise).
  let obj = null;
  try { obj = JSON.parse(raw); } catch (_) { obj = null; }
  if (obj && typeof obj === 'object' && !Array.isArray(obj) && ('ok' in obj)) {
    return { ok: obj.ok === true, data: obj.data === undefined ? null : obj.data, error: obj.error || '' };
  }
  return null; // not an envelope
}
function parseArgs(raw) {
  let obj = null;
  try { obj = JSON.parse(raw); } catch (_) { obj = null; }
  if (obj && typeof obj === 'object' && !Array.isArray(obj)) return obj;
  return raw; // keep raw so the json kind can still show it
}
function ctxArgs(name, raw) {
  return { name: name, target: 'args', argsJson: raw || '', args: parseArgs(raw), data: parseArgs(raw), ok: true, status: '' };
}
function ctxResult(name, raw, status) {
  const env = parseEnvelope(raw);
  if (env) return { name: name, target: 'result', resultJson: raw || '', data: env.data, ok: env.ok, error: env.error, status: status || '' };
  return { name: name, target: 'result', resultJson: raw || '', data: raw, ok: status === 'succeeded', error: '', status: status || '' };
}

/* ------------------------------------------------------------------ */
/* Custom renderer loading (lazy, cached). A file declares window.     */
/* CerisierViews.register(kind, fn); when it loads, pending slots      */
/* re-render.                                                          */
/* ------------------------------------------------------------------ */
const loadCache = {};     // url -> Promise
const loadDone = {};      // url -> true once settled (loaded or failed)
const loadNames = {};     // url -> Set(tool names waiting on it)

function rendererUrl(view, name) {
  if (!view || typeof view.renderer !== 'string' || !view.renderer) return '';
  // The manifest carries a project-relative path (e.g. tools/scripts/foo.view.js);
  // the server serves the tool's declared file at /views/<name>.
  return '/views/' + encodeURIComponent(name);
}
function ensureLoaded(url, name) {
  if (loadCache[url]) { if (loadNames[url]) loadNames[url].add(name); return loadCache[url]; }
  const set = new Set([name]); loadNames[url] = set;
  loadCache[url] = new Promise((resolve) => {
    const s = global.document.createElement('script');
    s.src = url; s.async = true; s.type = 'text/javascript';
    const settle = () => { loadDone[url] = true; set.forEach((n) => rerenderPending(n)); set.clear(); resolve(); };
    s.onload = settle;
    s.onerror = settle;
    (global.document.head || global.document.documentElement).appendChild(s);
  });
  return loadCache[url];
}
function pendingPlaceholder(name, target, raw) {
  return '<div class="tool-view tool-view-pending" data-view-pending="1" data-view-tool="' +
    escAttr(name) + '" data-view-target="' + target + '" data-view-raw="' + escAttr(raw) +
    '">loading view…</div>';
}
function rerenderPending(name) {
  if (!global.document.querySelectorAll) return;
  const sel = '[data-view-pending="1"][data-view-tool="' + name + '"]';
  const nodes = global.document.querySelectorAll(sel);
  for (const el of Array.from(nodes)) {
    const target = el.dataset.viewTarget;
    const raw = el.dataset.viewRaw || '';
    const card = el.closest ? el.closest('.tool-call') : null;
    const status = card && card.classList && card.classList.contains('succeeded') ? 'succeeded' : 'failed';
    const view = viewFor(name);
    let html;
    if (target === 'args') html = renderSlot(view, 'args', view && view.args, ctxArgs(name, raw));
    else html = renderSlot(view, 'result', view && view.result, ctxResult(name, raw, status));
    const w = global.document.createElement('div');
    w.innerHTML = html;
    if (w.firstChild) el.replaceWith(...w.childNodes);
  }
}

/* ------------------------------------------------------------------ */
/* Slot resolution                                                     */
/* ------------------------------------------------------------------ */
function viewFor(name) {
  const m = global.CERISIER_VIEWS;
  if (!m || typeof m !== 'object') return null;
  const v = m[name];
  return v && typeof v === 'object' ? v : null;
}
function renderSlot(view, target, spec, ctx) {
  const kind = (spec && typeof spec.kind === 'string') ? spec.kind : 'json';
  const fn = KINDS[kind];
  if (fn) { try { return fn(ctx, spec); } catch (_) { return pre(jsonValue(ctx.data), 'json'); } }
  // custom kind: load this tool's renderer file (registers the kind), placeholder till ready
  const url = rendererUrl(view, ctx.name);
  if (url && !loadDone[url]) { ensureLoaded(url, ctx.name); return pendingPlaceholder(ctx.name, target, ctx.target === 'args' ? ctx.argsJson : ctx.resultJson); }
  return pre(jsonValue(ctx.data), 'json'); // tried/none -> readable fallback
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */
function renderArgs(name, argsJson) {
  const view = viewFor(name);
  return renderSlot(view, 'args', view && view.args, ctxArgs(name, argsJson));
}
function renderResult(name, resultJson, status) {
  const view = viewFor(name);
  return renderSlot(view, 'result', view && view.result, ctxResult(name, resultJson, status));
}
function applyViews(cardEl) {
  const name = cardEl.dataset ? cardEl.dataset.toolName : '';
  if (!name) return;
  const ok = cardEl.classList && cardEl.classList.contains('succeeded');
  const status = ok ? 'succeeded' : 'failed';
  const argsEl = cardEl.querySelector('pre.tool-args');
  const allPres = Array.from(cardEl.querySelectorAll('pre'));
  let resEl = null;
  if (argsEl) { resEl = allPres.find((p) => p !== argsEl); }
  // args slot
  if (argsEl) {
    const html = renderArgs(name, argsEl.textContent);
    const w = global.document.createElement('div'); w.innerHTML = html;
    if (w.firstChild) argsEl.replaceWith(...w.childNodes);
  }
  // result slot
  if (resEl) {
    const html = renderResult(name, resEl.textContent, status);
    const w = global.document.createElement('div'); w.innerHTML = html;
    if (w.firstChild) resEl.replaceWith(...w.childNodes);
    else resEl.remove(); // empty payload -> nothing, like the live path
  }
}
function processReload(logEl) {
  if (!logEl || !logEl.querySelectorAll) return;
  logEl.querySelectorAll('.tool-call[data-tool-name]').forEach((el) => applyViews(el));
}

// registerCss: a tool's stylesheet, keyed by kind name. Appends (or replaces) a
// single <style data-view="name"> in <head>, so a shipped renderer can carry its
// own styling — the CSS channel that mirrors register(). Selectors must be
// namespaced with the tool's name (e.g. .mydiff-row) so injected CSS can't clobber
// the harness or a sibling tool. Re-registering the same name replaces, never stacks.
function registerCss(name, css) {
  if (!name || typeof css !== 'string' || css.trim() === '') return;
  const d = global.document;
  if (!d || !d.head || !d.querySelector || !d.createElement) return;
  let el = d.querySelector('style[data-view="' + name + '"]');
  if (!el) {
    el = d.createElement('style');
    el.setAttribute('data-view', name);
    d.head.appendChild(el);
  }
  el.textContent = css;
}

global.CerisierViews = {
  register: function (kind, fn) { KINDS[kind] = fn; },
  registerCss,
  renderArgs, renderResult, processReload, applyViews,
  humanSize,
  _kinds: KINDS, // exposed for tests
};
})(typeof window !== 'undefined' ? window : globalThis);
