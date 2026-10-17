/* rich.js — dependency-free rich-text renderer for chat messages.
 *
 *   Markdown (headings, lists, tables, quotes, links, emphasis, code)
 *   + fenced code blocks with syntax highlighting
 *   + LaTeX math ($..$, $$..$$, \(..\), \[..\]) via math.js
 *   + colour / style tags the model can emit:
 *        [[color:#e06c75]]text[[/color]]   [[bg:gold]]text[[/bg]]
 *        [[tag]]text[[/tag]]  for any tag registered on the Formats page
 *
 * SECURITY: every piece of model/user text is HTML-escaped before it is
 * turned into markup; generated markup is built only from validated pieces
 * (colours, class names, http(s)/same-origin URLs).
 *
 * Public API:  CerisierRich.render(text) -> HTML string
 */
(function (global) {
'use strict';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/* ------------------------------------------------------------------ */
/* Stash: park generated HTML behind opaque tokens so later regex      */
/* passes (emphasis etc.) can't touch it.                              */
/* ------------------------------------------------------------------ */
function makeStash() {
  const items = [];
  return {
    put(html) { items.push(html); return '\uE000' + (items.length - 1) + '\uE001'; },
    restore(s) {
      for (let n = 0; n < 8 && s.indexOf('\uE000') >= 0; n++) {
        s = s.replace(/\uE000(\d+)\uE001/g, (_, i) => (items[+i] !== undefined ? items[+i] : ''));
      }
      return s;
    },
  };
}

/* ------------------------------------------------------------------ */
/* Syntax highlighting                                                 */
/* ------------------------------------------------------------------ */
const C_COMMENT = /\/\/[^\n]*|\/\*[\s\S]*?(?:\*\/|(?![\s\S]))/.source;
const HASH_COMMENT = /#[^\n]*/.source;
const DQ = /"(?:\\[\s\S]|[^"\\\n])*"?/.source;
const SQ = /'(?:\\[\s\S]|[^'\\\n])*'?/.source;
const SQ_CHAR = /'(?:\\.[^'\n]*|[^'\\\n])'/.source;
const BT = /`(?:\\[\s\S]|[^`\\])*`?/.source;
const NUM = /\b0[xX][0-9a-fA-F_]+\b|\b0[bB][01_]+\b|\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?\b/.source;
const IDENT = /[A-Za-z_][A-Za-z0-9_]*/.source;
const words = (s) => new Set(s.split(/\s+/).filter(Boolean));

const LANGS = {};
function defLang(names, spec) { for (const n of names.split(' ')) LANGS[n] = spec; }

const JS_KW = 'async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield';
const TS_KW = JS_KW + ' interface type enum implements namespace declare readonly public private protected abstract as is keyof satisfies';
const JS_TYPES = 'string number boolean any unknown never object Array Map Set Promise Record Date Error RegExp Object Symbol';
defLang('js jsx mjs cjs javascript', { kw: JS_KW, lit: 'true false null undefined NaN Infinity', types: JS_TYPES, comment: C_COMMENT, str: [DQ, SQ, BT].join('|') });
defLang('ts tsx typescript', { kw: TS_KW, lit: 'true false null undefined NaN Infinity', types: JS_TYPES, comment: C_COMMENT, str: [DQ, SQ, BT].join('|') });
defLang('py python python3', {
  kw: 'and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case',
  lit: 'True False None', types: 'int float str bool list dict set tuple bytes object type self cls print len range Exception',
  comment: HASH_COMMENT,
  str: /[rRbBfFuU]{0,2}(?:"""[\s\S]*?(?:"""|(?![\s\S]))|'''[\s\S]*?(?:'''|(?![\s\S])))|[rRbBfFuU]{0,2}(?:"(?:\\[\s\S]|[^"\\\n])*"?|'(?:\\[\s\S]|[^'\\\n])*'?)/.source,
  extra: [[/@[A-Za-z_][\w.]*/.source, 'tok-m']],
});
defLang('c h', { kw: 'auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while',
  lit: 'NULL true false', types: 'int char float double void long short signed unsigned size_t bool uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t FILE',
  comment: C_COMMENT, str: [DQ, SQ_CHAR].join('|'), extra: [[/^[ \t]*#[ \t]*\w+/.source, 'tok-m']] });
defLang('cpp cc cxx hpp c++', { kw: 'alignas auto break case catch class concept const consteval constexpr continue co_await co_return co_yield decltype default delete do else enum explicit export extern final for friend goto if inline mutable namespace new noexcept operator override private protected public register requires return sizeof static static_assert struct switch template this throw try typedef typename union using virtual volatile while',
  lit: 'nullptr true false NULL', types: 'int char float double void long short signed unsigned bool size_t string vector map set unordered_map unique_ptr shared_ptr optional',
  comment: C_COMMENT, str: [DQ, SQ_CHAR].join('|'), extra: [[/^[ \t]*#[ \t]*\w+/.source, 'tok-m']] });
defLang('java', { kw: 'abstract assert break case catch class continue default do else enum extends final finally for if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var record sealed permits',
  lit: 'true false null', types: 'int long short byte float double boolean char void String Integer Long Double List Map Set Object',
  comment: C_COMMENT, str: [DQ, SQ_CHAR].join('|'), extra: [[/@[A-Za-z_]\w*/.source, 'tok-m']] });
defLang('cs csharp', { kw: 'abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while async await var record init',
  lit: 'true false null', types: 'int long short byte sbyte uint ulong ushort float double decimal bool char string object void List Dictionary',
  comment: C_COMMENT, str: [DQ, SQ_CHAR].join('|') });
defLang('go golang', { kw: 'break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var',
  lit: 'true false nil iota', types: 'int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 string bool byte rune error any',
  comment: C_COMMENT, str: [DQ, SQ_CHAR, BT].join('|') });
defLang('rs rust', { kw: 'as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while',
  lit: 'true false None Some Ok Err', types: 'i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc',
  comment: C_COMMENT, str: [DQ, SQ_CHAR].join('|'), extra: [[/#!?\[[^\]\n]*\]/.source, 'tok-m'], [/[A-Za-z_]\w*!/.source, 'tok-f']] });
defLang('nim nims nimble', { kw: 'addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type using var when while xor yield',
  lit: 'true false nil', types: 'int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float float32 float64 string char bool seq array set Table Option Future JsonNode cstring',
  comment: /#\[[\s\S]*?(?:\]#|(?![\s\S]))|#[^\n]*/.source,
  str: /"""[\s\S]*?(?:"""|(?![\s\S]))|[rR]"(?:""|[^"\n])*"|"(?:\\[\s\S]|[^"\\\n])*"?|'(?:\\.[^'\n]*|[^'\\\n])'/.source,
  extra: [[/\{\.[\s\S]*?\.\}/.source, 'tok-m']] });
defLang('sh bash zsh shell console', { kw: 'if then else elif fi for while until do done case esac in function select time return exit break continue export local readonly declare unset source alias',
  lit: '', types: 'echo cd ls cat grep sed awk find mkdir rm cp mv chmod chown sudo curl wget git npm pip python python3 nim nimble make tar ssh test',
  comment: /(?<![\w$])#[^\n]*/.source, str: /"(?:\\[\s\S]|[^"\\])*"?|'[^']*'?/.source,
  extra: [[/\$(?:\{[^}\n]*\}?|[A-Za-z_]\w*|[0-9@#?!*$-])/.source, 'tok-v']] });
defLang('json jsonc json5', { lit: 'true false null', str: DQ, keyStrings: true, comment: C_COMMENT });
defLang('yaml yml', { lit: 'true false null yes no on off', comment: /(?<![\w"'])#[^\n]*/.source, str: [DQ, SQ].join('|'),
  extra: [[/[\w.\-/]+(?=[ \t]*:(?:[ \t]|\n|(?![\s\S])))/.source, 'tok-a']] });
defLang('toml ini conf cfg', { lit: 'true false', comment: /(?:^|(?<=\s))[#;][^\n]*/.source, str: [DQ, SQ].join('|'),
  extra: [[/^\[[^\]\n]+\]/.source, 'tok-k'], [/^[ \t]*[\w.\-]+(?=[ \t]*=)/.source, 'tok-a']] });
defLang('sql', { ci: true, kw: 'select from where insert into values update set delete create table alter drop index view join inner left right outer full cross on as and or not null is in exists between like group by order having limit offset union all distinct case when then else end primary key foreign references default unique check constraint with returning begin commit rollback pragma',
  lit: 'true false', types: 'int integer bigint smallint text varchar char boolean bool date timestamp timestamptz real float double numeric decimal blob serial',
  comment: /--[^\n]*|\/\*[\s\S]*?(?:\*\/|(?![\s\S]))/.source, str: /'(?:''|[^'])*'?/.source });
defLang('css scss less', { comment: /\/\*[\s\S]*?(?:\*\/|(?![\s\S]))/.source, str: [DQ, SQ].join('|'),
  extra: [[/@[\w-]+/.source, 'tok-k'], [/#[0-9a-fA-F]{3,8}\b/.source, 'tok-n'], [/[\w-]+(?=\s*:)/.source, 'tok-a'], [/\d*\.?\d+(?:px|em|rem|%|vh|vw|s|ms|deg|fr)\b/.source, 'tok-n']] });

for (const k in LANGS) {
  const L = LANGS[k];
  if (L.compiled) continue;
  L.compiled = true;
}

const compiledCache = new Map();
function compile(spec) {
  if (compiledCache.has(spec)) return compiledCache.get(spec);
  const parts = [];
  if (spec.comment) parts.push([spec.comment, 'tok-c']);
  if (spec.str) parts.push([spec.str, 'tok-s']);
  for (const e of spec.extra || []) parts.push(e);
  parts.push([NUM, 'tok-n']);
  parts.push([IDENT, null]);
  const c = {
    re: new RegExp(parts.map((p) => '(' + p[0] + ')').join('|'), 'gm' + (spec.ci ? 'i' : '')),
    classes: parts.map((p) => p[1]),
    kw: words(spec.kw || ''), lit: words(spec.lit || ''), types: words(spec.types || ''),
    ci: !!spec.ci, keyStrings: !!spec.keyStrings,
  };
  compiledCache.set(spec, c);
  return c;
}

function highlightGeneric(code, spec) {
  const c = compile(spec);
  const re = c.re;
  re.lastIndex = 0;
  let out = '', last = 0, m;
  while ((m = re.exec(code))) {
    if (m[0].length === 0) { re.lastIndex++; continue; }
    out += esc(code.slice(last, m.index));
    last = m.index + m[0].length;
    let g = 1;
    while (g < m.length && m[g] === undefined) g++;
    let cls = c.classes[g - 1];
    const text = m[0];
    if (cls === null) {
      const w = c.ci ? text.toLowerCase() : text;
      if (c.kw.has(w)) cls = 'tok-k';
      else if (c.lit.has(w)) cls = 'tok-l';
      else if (c.types.has(w)) cls = 'tok-t';
      else if (code[last] === '(') cls = 'tok-f';
    } else if (cls === 'tok-s' && c.keyStrings && /^\s*:/.test(code.slice(last, last + 24))) {
      cls = 'tok-a';
    }
    out += cls ? `<span class="${cls}">${esc(text)}</span>` : esc(text);
  }
  return out + esc(code.slice(last));
}

function highlightTag(tag) {
  let out = '', last = 0, m;
  const re = /^(<\/?)([\w:.-]+)|("[^"]*"?|'[^']*'?)|([\w:@.-]+)(?==)/g;
  while ((m = re.exec(tag))) {
    out += esc(tag.slice(last, m.index));
    last = m.index + m[0].length;
    if (m[2]) out += esc(m[1]) + '<span class="tok-k">' + esc(m[2]) + '</span>';
    else if (m[3]) out += '<span class="tok-s">' + esc(m[3]) + '</span>';
    else out += '<span class="tok-a">' + esc(m[4]) + '</span>';
  }
  return out + esc(tag.slice(last));
}
function highlightHtml(code) {
  const re = /<!--[\s\S]*?(?:-->|(?![\s\S]))|<\/?[A-Za-z][\w:.-]*(?:[^<>"']|"[^"]*"|'[^']*')*>/g;
  let out = '', last = 0, m;
  while ((m = re.exec(code))) {
    out += esc(code.slice(last, m.index));
    last = m.index + m[0].length;
    out += m[0].startsWith('<!--') ? '<span class="tok-c">' + esc(m[0]) + '</span>' : highlightTag(m[0]);
  }
  return out + esc(code.slice(last));
}
function highlightDiff(code) {
  return code.split('\n').map((l) => {
    const e = esc(l);
    if (/^(\+\+\+|---)/.test(l)) return '<span class="tok-k">' + e + '</span>';
    if (l.startsWith('+')) return '<span class="tok-add">' + e + '</span>';
    if (l.startsWith('-')) return '<span class="tok-del">' + e + '</span>';
    if (l.startsWith('@@')) return '<span class="tok-m">' + e + '</span>';
    return e;
  }).join('\n');
}

function highlight(code, lang) {
  lang = (lang || '').toLowerCase();
  if (code.length > 100000) return esc(code);
  if (/^(html|xml|svg|xhtml|vue)$/.test(lang)) return highlightHtml(code);
  if (/^(diff|patch)$/.test(lang)) return highlightDiff(code);
  const spec = LANGS[lang];
  return spec ? highlightGeneric(code, spec) : esc(code);
}

/* ------------------------------------------------------------------ */
/* Colour / style tags: [[color:#f00]]x[[/color]]                      */
/* ------------------------------------------------------------------ */
const COLOR_TAGS = new Set(['color', 'colour', 'c', 'fg']);
const BG_TAGS = new Set(['bg', 'hl', 'highlight', 'mark']);

function safeColor(p) {
  p = String(p || '').trim();
  if (/^#[0-9a-fA-F]{3,8}$/.test(p)) return p;
  if (/^[a-zA-Z]{3,24}$/.test(p)) return p;
  if (/^(?:rgb|hsl)a?\(\s*[\d.]+%?(?:\s*[, ]\s*[\d.]+%?){2}(?:\s*[,/]\s*[\d.]+%?)?\s*\)$/.test(p)) return p;
  return null;
}
function formatClassFor(tag) {
  const F = global.CERISIER_FORMATS;
  if (!F) return null;
  for (const k of Object.keys(F)) {
    if (k.toLowerCase() === tag) return /^[\w -]+$/.test(F[k]) ? F[k] : '';
  }
  return null;
}
function isKnownTag(tag) {
  return COLOR_TAGS.has(tag) || BG_TAGS.has(tag) || formatClassFor(tag) !== null;
}
function openSpan(tag, rawParam) {
  const param = rawParam.replace(/[\uE000\uE001]/g, '').trim();
  if (COLOR_TAGS.has(tag)) {
    const c = safeColor(param);
    return c ? `<span class="fmt fmt-color" style="color:${c}">` : '<span class="fmt">';
  }
  if (BG_TAGS.has(tag)) {
    const c = safeColor(param) || '#ffd54f';
    return `<span class="fmt fmt-bg" style="background:${c};background:color-mix(in srgb, ${c} 38%, transparent)">`;
  }
  const cls = formatClassFor(tag) || '';
  const title = param ? ` title="${param}"` : ''; // param is already HTML-escaped text
  return `<span class="fmt ${cls}"${title}>`;
}
function applyFormatTags(text, st) {
  const re = /\[\[(\/)?([A-Za-z][\w-]*)(?::([^\]\n]*))?\]\]/g;
  const stack = [];
  let out = '', last = 0, m;
  while ((m = re.exec(text))) {
    const tag = m[2].toLowerCase();
    if (!isKnownTag(tag)) continue;
    out += text.slice(last, m.index);
    last = m.index + m[0].length;
    if (!m[1]) {
      stack.push(tag);
      out += st.put(openSpan(tag, m[3] || ''));
    } else {
      const at = stack.lastIndexOf(tag);
      if (at < 0) continue; // stray closer: drop it
      while (stack.length > at) { stack.pop(); out += st.put('</span>'); }
    }
  }
  out += text.slice(last);
  while (stack.length) { stack.pop(); out += st.put('</span>'); }
  return out;
}

/* ------------------------------------------------------------------ */
/* Inline                                                              */
/* ------------------------------------------------------------------ */
function mathHtml(tex, display) {
  return global.CerisierMath ? global.CerisierMath.render(tex, display) : '<code>' + esc(tex) + '</code>';
}
function safeUrl(u) {
  return /^(?:https?:\/\/|mailto:|\/(?!\/)|#)/i.test(u) ? u : null;
}

function inline(raw) {
  const st = makeStash();
  let s = raw;
  s = s.replace(/(`+)(?!`)([\s\S]*?[^`])\1(?!`)/g, (_, t, code) => st.put('<code>' + esc(code.replace(/^\s(.+)\s$/s, '$1')) + '</code>'));
  s = s.replace(/\\\$/g, () => st.put('$'));
  s = s.replace(/\\\((.+?)\\\)/gs, (_, t) => st.put(mathHtml(t, false)));
  s = s.replace(/\\\[(.+?)\\\]/gs, (_, t) => st.put(mathHtml(t, false)));
  s = s.replace(/\$\$(.+?)\$\$/gs, (_, t) => st.put(mathHtml(t, false)));
  s = s.replace(/(?<![\w$\\])\$(?!\s)((?:\\.|[^$\\\n])+?)(?<![\s\\])\$(?!\d)/g, (_, t) => st.put(mathHtml(t, false)));
  s = s.replace(/\\([\\`*_{}\[\]()#+\-.!|~<>])/g, (_, c) => st.put(esc(c)));
  s = esc(s);
  s = applyFormatTags(s, st);
  s = s.replace(/!\[([^\]\[\n]*)\]\((\/files\/\d+)\)/g, (_, alt, url) => st.put(`<img class="md-img" src="${url}" alt="${alt}">`));
  s = s.replace(/\[([^\]\[\n]+)\]\(([^\s()\uE000\uE001]+)(?:\s+&quot;[^\n]*?&quot;)?\)/g, (m, text, url) => {
    const ok = safeUrl(url);
    return ok ? st.put(`<a href="${ok}" target="_blank" rel="noopener noreferrer">${text}</a>`) : m;
  });
  s = s.replace(/\*\*\*(?=\S)([^\n]*?\S)\*\*\*/g, '<strong><em>$1</em></strong>');
  s = s.replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(?<!\w)__(?=\S)([\s\S]*?\S)__(?!\w)/g, '<strong>$1</strong>');
  s = s.replace(/(?<![*\w])\*(?=[^\s*])([^*\n]*?[^\s*])\*(?![*\w])/g, '<em>$1</em>');
  s = s.replace(/(?<!\w)_(?=[^\s_])([^_\n]*?[^\s_])_(?!\w)/g, '<em>$1</em>');
  s = s.replace(/~~(?=\S)([^\n]*?\S)~~/g, '<del>$1</del>');
  s = s.replace(/\n/g, '<br>');
  return st.restore(s);
}

/* ------------------------------------------------------------------ */
/* Blocks                                                              */
/* ------------------------------------------------------------------ */
const reFence = /^(\s*)(`{3,}|~{3,})\s*([A-Za-z0-9_+#.\-]*)[^`]*$/;
const reList = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const reHr = /^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
const reTableSep = /^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/;
const reMathOpen = /^\s*(\$\$|\\\[)(.*)$/;

function codeBlock(code, lang) {
  const l = (lang || '').toLowerCase();
  return `<div class="codeblock"><div class="codeblock-head"><span class="codelang">${esc(l || 'text')}</span>` +
    `<button type="button" class="copy-btn">Copy</button></div><pre><code>${highlight(code, l)}</code></pre></div>`;
}
function mathBlock(tex) { return mathHtml(tex, true); }

function splitRow(line) {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));
}
function startsBlock(line, next) {
  if (reFence.test(line) || reMathOpen.test(line) || reHr.test(line) || reList.test(line)) return true;
  if (/^\s{0,3}(#{1,6}\s|>)/.test(line)) return true;
  if (line.indexOf('|') >= 0 && next !== undefined && next.indexOf('|') >= 0 && reTableSep.test(next)) return true;
  return false;
}

function parseList(lines, start) {
  const first = reList.exec(lines[start]);
  const baseIndent = first[1].length;
  const ordered = /\d/.test(first[2][0]);
  const startNum = ordered ? parseInt(first[2], 10) : 1;
  const items = [];
  const n = lines.length;
  let i = start;
  while (i < n) {
    const line = lines[i];
    if (/^\s*$/.test(line)) {
      let j = i + 1;
      while (j < n && /^\s*$/.test(lines[j])) j++;
      if (j < n && items.length) {
        const nm = reList.exec(lines[j]);
        const ind = (/^\s*/.exec(lines[j])[0]).length;
        const sameLevel = nm && ind <= baseIndent + 1 && ind >= baseIndent - 1;
        const kindMismatch = sameLevel && /\d/.test(nm[2][0]) !== ordered;
        if (!kindMismatch && ((nm && ind >= baseIndent) || ind > baseIndent)) {
          for (let k = i; k < j; k++) items[items.length - 1].lines.push('');
          i = j;
          continue;
        }
      }
      break;
    }
    const m = reList.exec(line);
    const ind = (/^\s*/.exec(line)[0]).length;
    if (m && ind <= baseIndent + 1 && ind >= baseIndent - 1 && !reHr.test(line)) {
      if (items.length && /\d/.test(m[2][0]) !== ordered) break; // bullet <-> numbered switch starts a new list
      items.push({ lines: [m[3]], contentIndent: ind + m[2].length + 1 });
      i++;
      continue;
    }
    if (m && ind < baseIndent) break;
    if (!items.length) break;
    const it = items[items.length - 1];
    if (ind > baseIndent || !startsBlock(line, lines[i + 1])) {
      it.lines.push(line.replace(new RegExp('^\\s{0,' + Math.min(ind, it.contentIndent) + '}'), ''));
      i++;
      continue;
    }
    break;
  }
  const lis = items.map((it) => {
    let body = renderBlocks(it.lines.map((l, idx) => (idx === 0 ? l.replace(/^\[([ xX])\]\s+/, (_, c) => (c === ' ' ? '☐ ' : '☑ ')) : l)));
    if (/^<p>/.test(body) && /<\/p>$/.test(body) && (body.match(/<p>/g) || []).length === 1) body = body.slice(3, -4);
    return `<li>${body}</li>`;
  }).join('');
  const tag = ordered ? 'ol' : 'ul';
  const startAttr = ordered && startNum !== 1 ? ` start="${startNum}"` : '';
  return [`<${tag}${startAttr}>${lis}</${tag}>`, i];
}

function renderBlocks(lines) {
  const out = [];
  const n = lines.length;
  let i = 0;
  while (i < n) {
    const line = lines[i];
    if (/^\s*$/.test(line)) { i++; continue; }
    let m;

    if ((m = reFence.exec(line))) {
      const indent = m[1].length, fence = m[2], lang = m[3];
      const closeRe = new RegExp('^\\s*' + (fence[0] === '`' ? '`' : '~') + '{' + fence.length + ',}\\s*$');
      const stripRe = new RegExp('^\\s{0,' + indent + '}');
      const body = [];
      i++;
      while (i < n && !closeRe.test(lines[i])) { body.push(lines[i].replace(stripRe, '')); i++; }
      if (i < n) i++;
      out.push(codeBlock(body.join('\n'), lang));
      continue;
    }

    if ((m = reMathOpen.exec(line))) {
      const open = m[1], close = open === '$$' ? '$$' : '\\]';
      const rest = m[2];
      const idx = rest.indexOf(close);
      if (idx >= 0) {
        if (rest.slice(idx + close.length).trim() === '') { out.push(mathBlock(rest.slice(0, idx))); i++; continue; }
        // text after the closer: let the paragraph/inline path handle the whole line
      } else {
        const buf = [rest];
        i++;
        while (i < n) {
          const j = lines[i].indexOf(close);
          if (j >= 0) {
            buf.push(lines[i].slice(0, j));
            const trailing = lines[i].slice(j + close.length);
            if (trailing.trim() === '') i++; else lines[i] = trailing;
            break;
          }
          buf.push(lines[i]);
          i++;
        }
        out.push(mathBlock(buf.join('\n')));
        continue;
      }
    }

    if ((m = /^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/.exec(line))) {
      const lvl = m[1].length;
      out.push(`<h${lvl}>${inline(m[2])}</h${lvl}>`);
      i++;
      continue;
    }
    if (reHr.test(line)) { out.push('<hr>'); i++; continue; }

    if (/^\s{0,3}>/.test(line)) {
      const buf = [];
      while (i < n && /^\s{0,3}>/.test(lines[i])) { buf.push(lines[i].replace(/^\s{0,3}>\s?/, '')); i++; }
      out.push('<blockquote>' + renderBlocks(buf) + '</blockquote>');
      continue;
    }

    if (line.indexOf('|') >= 0 && i + 1 < n && lines[i + 1].indexOf('|') >= 0 && reTableSep.test(lines[i + 1])) {
      const header = splitRow(line);
      const aligns = splitRow(lines[i + 1]).map((c) => (/^:-+:$/.test(c) ? 'center' : /-:$/.test(c) ? 'right' : /^:-/.test(c) ? 'left' : ''));
      if (header.length === aligns.length) {
        i += 2;
        const rows = [];
        while (i < n && lines[i].trim() !== '' && lines[i].indexOf('|') >= 0) { rows.push(splitRow(lines[i])); i++; }
        const cell = (tag, c, ci) => `<${tag}${aligns[ci] ? ` style="text-align:${aligns[ci]}"` : ''}>${inline(c || '')}</${tag}>`;
        out.push('<div class="table-wrap"><table><thead><tr>' + header.map((c, ci) => cell('th', c, ci)).join('') + '</tr></thead><tbody>' +
          rows.map((r) => '<tr>' + header.map((_, ci) => cell('td', r[ci], ci)).join('') + '</tr>').join('') + '</tbody></table></div>');
        continue;
      }
    }

    if (reList.test(line)) {
      const [html, next] = parseList(lines, i);
      out.push(html);
      i = next;
      continue;
    }

    const buf = [line];
    i++;
    while (i < n && !/^\s*$/.test(lines[i]) && !startsBlock(lines[i], lines[i + 1])) { buf.push(lines[i]); i++; }
    out.push('<p>' + inline(buf.join('\n')) + '</p>');
  }
  return out.join('\n');
}

function render(src) {
  const text = String(src == null ? '' : src).replace(/[\uE000\uE001]/g, '').replace(/\r\n?/g, '\n');
  try {
    return renderBlocks(text.split('\n'));
  } catch (e) {
    return '<p>' + esc(text).replace(/\n/g, '<br>') + '</p>';
  }
}

global.CerisierRich = { render, highlight, esc };
})(typeof window !== 'undefined' ? window : globalThis);
