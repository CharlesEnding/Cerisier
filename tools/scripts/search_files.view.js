// Custom result renderer shipped WITH the search_files tool.
// The manifest declares { "renderer": "tools/scripts/search_files.view.js",
// "result": { "kind": "search_files" } }. views.js loads this file lazily via
// /views/search_files and this self-registers the kind. ctx.data is the tool's
// `data` object (the same payload the model sees): { pattern, path, matches,
// count, truncated }. `matches` is the raw joined grep output, which can be:
//   - match lines     `path:line:content`
//   - context lines   `path-line-content`   (hyphen separators, from -A/-B/-C)
//   - group breaks    `--`                  (between non-adjacent matches)
//   - a truncation marker `...(output truncated)`
//   - in files_with_matches mode, just bare file paths
// A plain text block can't tell any of those apart, so we render it as a monospace
// block with the `path:line` prefix highlighted so the actual matches are scannable
// at a glance, dimmed context, a faint break, and a muted marker/file path.
//
// The canonical {ok,data} envelope the model reads back is unchanged; this is
// human-facing presentation only.
(function () {
  const V = window.CerisierViews;
  if (!V) return;

  // Namespaced under .search_files so it can't clobber the harness or a sibling
  // tool. registerCss dedupes by name. Reuse the harness tokens (--accent, --muted).
  V.registerCss('search_files', `
.search_files { font: 0.85rem/1.4 system-ui, sans-serif; }
.search_files .sf-head { font-weight: 600; color: var(--muted); margin-bottom: 0.2rem; }
.search_files .sf-meta { color: var(--muted); font-size: 0.78rem; margin-bottom: 0.4rem; }
.search_files .sf-body { font: 0.83rem/1.35 monospace; white-space: pre-wrap; word-break: break-word; margin: 0; padding: 0; }
.search_files .sf-path { color: var(--muted); }
.search_files .sf-no { color: var(--accent); font-weight: 600; }
.search_files .sf-ctx { opacity: 0.55; }
.search_files .sf-sep { color: var(--muted); }
.search_files .sf-empty, .search_files .sf-note { color: var(--muted); font-style: italic; }
`);

  // Every renderer escapes its own output; views.js injects this HTML verbatim.
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  // `path:line:content` or `path-line-content`. Lazy path so a colon inside the
  // content stays content; the two separators around the line number tell us the
  // kind (colon = match, hyphen = context).
  const LINE = /^(.+?)(:|-)(\d+)(:|-)(.*)$/;

  function renderLine(line) {
    if (line === '--') return '<span class="sf-sep">--</span>';
    if (line.startsWith('...(')) return '<span class="sf-note">' + esc(line) + '</span>';
    const m = line.match(LINE);
    if (m) {
      const ctxCls = m[2] === '-' ? ' sf-ctx' : '';
      // Prefix: muted path, then the number (with its separators) in accent.
      const prefix = '<span class="sf-path">' + esc(m[1]) + '</span>' +
                     '<span class="sf-no">' + esc(m[2]) + esc(m[3]) + esc(m[4]) + '</span>';
      return '<span class="sf-line' + ctxCls + '">' + prefix +
             '<span class="sf-text">' + esc(m[5]) + '</span></span>';
    }
    // files_with_matches mode: the whole line is a file path (also any other
    // line grep emits verbatim, e.g. a "Binary file ... matches" notice).
    return '<span class="sf-path">' + esc(line) + '</span>';
  }

  V.register('search_files', function (ctx) {
    // On a failed call the tool's envelope is {ok:false, error:"..."} and ctx.data
    // is null, so without this guard the empty `matches` would render as "no
    // matches" and hide the error — every built-in kind guards this way.
    if (ctx && ctx.target === 'result' && ctx.ok === false) {
      const err = (ctx && ctx.error) || '';
      return err === '' ? '' : '<pre class="tool-view tool-view-error">' + esc(err) + '</pre>';
    }
    const d = (ctx && ctx.data) || {};
    const raw = typeof d.matches === 'string' ? d.matches : '';
    const lines = raw === '' ? [] : raw.split('\n');

    // Meta line: the pattern that was searched, how many hits, and a truncation
    // badge. The path is shown as the header above.
    let meta = '';
    if (d.pattern !== undefined && d.pattern !== null)
      meta += '"<span class="sf-pat">' + esc(String(d.pattern)) + '</span>"';
    if (typeof d.count === 'number') {
      if (meta) meta += ' · ';
      meta += d.count + ' match' + (d.count === 1 ? '' : 'es');
    }
    if (d.truncated) {
      if (meta) meta += ' · ';
      meta += '<span class="tool-view-note">truncated</span>';
    }

    let html = '<div class="tool-view search_files">';
    html += '<div class="sf-head">' + esc(d.path || '') + '</div>';
    if (meta) html += '<div class="sf-meta">' + meta + '</div>';
    if (lines.length === 0)
      html += '<pre class="sf-body"><span class="sf-empty">no matches</span></pre>';
    else
      html += '<pre class="sf-body">' + lines.map(renderLine).join('\n') + '</pre>';
    html += '</div>';
    return html;
  });
})();
