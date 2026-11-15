// Custom result renderer shipped WITH the show_machine_config tool.
// The manifest declares { "renderer": "tools/scripts/show_machine_config.view.js",
// "result": { "kind": "show_machine_config" } }. views.js loads this file lazily via
// /views/show_machine_config and this self-registers the kind. It gets the same ctx as
// any renderer: ctx.data is the tool's `data` object (the canonical model payload).
(function () {
  const V = window.CerisierViews;
  if (!V) return;
  // Ship this tool's own styling. Namespaced under .show_machine_config so it can't
  // clobber the harness or a sibling tool; a template literal avoids backslash
  // escaping (CSS uses \ a lot). registerCss dedupes by name, replacing on reload.
  V.registerCss('show_machine_config', `
.show_machine_config { font: 0.85rem/1.4 system-ui, sans-serif; }
.show_machine_config .mhead { font-weight: 700; color: var(--accent); margin-bottom: 0.35rem; }
.show_machine_config .mrow { display: flex; gap: 0.6rem; margin: 0.12rem 0; }
.show_machine_config .mlbl { color: var(--muted); min-width: 6rem; }
.show_machine_config .mval { flex: 1; }
.show_machine_config .mbar { display: inline-block; width: 11rem; height: 0.4rem; background: var(--border); border-radius: 0.2rem; vertical-align: middle; margin-left: 0.5rem; overflow: hidden; }
.show_machine_config .mbar-fill { height: 100%; background: #7ee787; }
`);
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  // Reuse the registry's humanSize; MB values are pre-scaled here.
  const fmtMB = (mb) => (typeof mb === 'number' && mb > 0) ? V.humanSize(mb * 1024 * 1024) : '';

  function row(label, value) {
    if (value === '' || value == null) return '';
    return '<div class="mrow"><span class="mlbl">' + esc(label) + '</span><span class="mval">' + value + '</span></div>';
  }

  V.register('show_machine_config', function (ctx) {
    const d = (ctx && ctx.data) || {};
    const os = d.os || {};
    const cpu = d.cpu || {};
    const mem = d.memory || {};
    const up = d.uptime || {};
    const disk = Array.isArray(d.disk) ? d.disk : [];

    let html = '<div class="tool-view show_machine_config">';
    html += '<div class="mhead">' + esc(d.hostname || 'host') + '</div>';

    const osLabel = [os.name, os.version, os.codename].filter(Boolean).join(' ');
    html += row('OS', esc(osLabel));
    if (d.kernel) html += row('Kernel', esc(d.kernel));
    html += row('Arch', esc(d.arch || '') + (d.python_version ? ' · ' + esc('Python ' + d.python_version) : ''));
    html += row('CPU', esc(String(cpu.cores || '?')) + ' cores' + (cpu.model ? ' · ' + esc(cpu.model) : ''));

    // Memory with a fill bar.
    const total = mem.total_mb || 0, used = mem.used_mb || 0;
    const pct = total > 0 ? Math.min(100, Math.round((used / total) * 100)) : 0;
    const memBar = '<div class="mbar"><div class="mbar-fill" style="width:' + pct + '%"></div></div>';
    html += row('Memory', fmtMB(used) + ' / ' + fmtMB(total) + ' (' + pct + '%)' + memBar);

    if (up.load_1m !== undefined)
      html += row('Load', esc(String(up.load_1m) + ' / ' + String(up.load_5m) + ' / ' + String(up.load_15m)));
    const secs = up.seconds || 0;
    const days = Math.floor(secs / 86400);
    const hrs = Math.floor((secs % 86400) / 3600);
    html += row('Uptime', esc((days ? days + 'd ' : '') + hrs + 'h'));

    if (disk.length) {
      html += '<table class="tool-view tool-view-table"><thead><tr><th>Mount</th><th>Type</th><th>Used</th><th>Free</th></tr></thead><tbody>';
      for (const r of disk) {
        html += '<tr><td>' + esc(r.mountpoint) + '</td><td>' + esc(r.fstype) + '</td>' +
          '<td>' + esc(fmtMB(r.used_mb) + ' / ' + fmtMB(r.total_mb)) + '</td>' +
          '<td>' + esc(fmtMB(r.free_mb)) + '</td></tr>';
      }
      html += '</tbody></table>';
    }
    html += '</div>';
    return html;
  });
})();
