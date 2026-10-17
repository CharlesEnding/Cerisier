// Cerisier front-end (vanilla JS, no framework, no build step).
// Depends on /static/math.js and /static/rich.js (loaded by layout.nim).

// ---------------------------------------------------------------- helpers
function toggleSidebar() {
  document.body.classList.toggle('sidebar-collapsed');
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function humanSize(n) {
  if (n == null) return '';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1024 / 1024).toFixed(1) + ' MB';
}

// Remove <tool_call>…</tool_call> blocks (and a trailing, still-streaming one)
// from text shown to the user. Mirrors stripToolCalls in toolcalls.nim.
function stripToolCalls(text) {
  let out = text.replace(/<tool_call>[\s\S]*?<\/tool_call>/g, '');
  const open = out.indexOf('<tool_call>');
  if (open >= 0) out = out.slice(0, open);
  return out.trim();
}

function richInto(node, text) {
  node.innerHTML = window.CerisierRich ? window.CerisierRich.render(text) : '';
  if (!window.CerisierRich) node.textContent = text;
}

function copyText(t) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(t);
  return new Promise((resolve) => {
    const ta = document.createElement('textarea');
    ta.value = t;
    ta.style.cssText = 'position:fixed;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (_) { /* ignore */ }
    ta.remove();
    resolve();
  });
}

function fileChip(f) {
  const url = f.url || `/files/${f.id}`;
  const a = el('a', 'file-chip');
  a.href = url;
  if ((f.mime || '').startsWith('image/')) {
    a.classList.add('file-image');
    a.target = '_blank';
    const img = el('img');
    img.src = url;
    img.alt = f.name;
    a.appendChild(img);
    a.appendChild(el('span', '', f.name));
  } else {
    a.download = f.name;
    a.textContent = `📄 ${f.name}` + (f.size != null ? ` (${humanSize(f.size)})` : '');
  }
  return a;
}

// ---------------------------------------------------------------- chat page
// Only this page updates in place; every other page is a normal page load.
function connectChat(conversationId) {
  const log = document.getElementById('chat-log');
  if (!log) return;
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const ws = new WebSocket(`${proto}//${location.host}/ws/chat/${conversationId}`);

  const form = document.getElementById('chat-form');
  const input = document.getElementById('chat-input');
  const sendBtn = form ? form.querySelector('button[type="submit"]') : null;
  const stopBtn = document.getElementById('stop-btn');
  const attachBtn = document.getElementById('attach-btn');
  const fileInput = document.getElementById('file-input');
  const attachBox = document.getElementById('attachments');
  const noteBox = document.getElementById('compose-note');
  const todoBox = document.getElementById('todo-widget');
  const compose = document.getElementById('chat-compose');

  let container = log;     // where new live events go (switches into a sub-agent block)
  let stream = null;       // current streaming assistant bubble: {div, text, raf}
  let reasoning = null;    // current reasoning block: {details, body}
  let sub = null;          // active sub-agent block: {details, body, status}
  let attachments = [];    // composer attachments: {name, size, mime, id, status}
  let todoCollapsed = false;
  let noteTimer = 0;

  // ---- scrolling: only follow the stream if the user is already at the bottom
  function nearBottom() { return log.scrollHeight - log.scrollTop - log.clientHeight < 120; }
  function withScroll(fn) {
    const pin = nearBottom();
    fn();
    if (pin) log.scrollTop = log.scrollHeight;
  }

  function note(msg) {
    if (!noteBox) return;
    noteBox.textContent = msg;
    clearTimeout(noteTimer);
    if (msg) noteTimer = setTimeout(() => { noteBox.textContent = ''; }, 4000);
  }

  function setGenerating(isGenerating) {
    if (stopBtn) stopBtn.style.display = isGenerating ? '' : 'none';
    if (input) input.disabled = isGenerating;
    if (sendBtn) sendBtn.disabled = isGenerating;
    if (attachBtn) attachBtn.disabled = isGenerating;
    if (!isGenerating && input) input.focus();
  }

  // ---- streaming bubbles ------------------------------------------------
  function pushStream(tok) {
    if (!stream) {
      const div = el('div', 'msg assistant md');
      container.appendChild(div);
      stream = { div, text: '', raf: 0 };
    }
    const s = stream;
    s.text += tok;
    if (!s.raf) {
      s.raf = requestAnimationFrame(() => {
        s.raf = 0;
        withScroll(() => richInto(s.div, stripToolCalls(s.text)));
      });
    }
  }
  // keep: leave the bubble in place (rendered); otherwise drop it
  function finishStream(keep) {
    if (!stream) return;
    const s = stream;
    stream = null;
    if (s.raf) cancelAnimationFrame(s.raf);
    const visible = stripToolCalls(s.text);
    if (keep && visible) richInto(s.div, visible);
    else s.div.remove();
  }
  function pushReasoning(tok) {
    if (!reasoning) {
      const details = el('details', 'reasoning');
      details.open = true; // visible while actively reasoning
      details.appendChild(el('summary', '', 'Reasoning'));
      const body = el('div');
      details.appendChild(body);
      container.appendChild(details);
      reasoning = { details, body };
    }
    reasoning.body.textContent += tok;
  }
  function finishReasoning() {
    if (!reasoning) return;
    reasoning.details.open = false;
    reasoning = null;
  }

  // ---- todo widget ------------------------------------------------------
  function renderTodos(items) {
    if (!todoBox) return;
    todoBox.textContent = '';
    if (!items || !items.length) { todoBox.style.display = 'none'; return; }
    todoBox.style.display = '';
    const done = items.filter((i) => i.status === 'completed').length;
    const head = el('div', 'todo-head');
    head.appendChild(el('span', 'todo-title', `Todo ${done}/${items.length}`));
    const bar = el('div', 'todo-bar');
    const fill = el('div');
    fill.style.width = Math.round((done / items.length) * 100) + '%';
    bar.appendChild(fill);
    head.appendChild(bar);
    const toggle = el('button', 'todo-btn', todoCollapsed ? '▸' : '▾');
    toggle.type = 'button';
    toggle.title = todoCollapsed ? 'Expand' : 'Collapse';
    toggle.addEventListener('click', () => { todoCollapsed = !todoCollapsed; renderTodos(items); });
    head.appendChild(toggle);
    const clear = el('button', 'todo-btn', '✕');
    clear.type = 'button';
    clear.title = 'Clear list';
    clear.addEventListener('click', () => {
      fetch(`/chat/${conversationId}/todos/clear`, { method: 'POST' }).catch(() => {});
      renderTodos([]);
    });
    head.appendChild(clear);
    todoBox.appendChild(head);
    if (!todoCollapsed) {
      const ul = el('ul', 'todo-list');
      for (const it of items) {
        const li = el('li', 'todo-item ' + it.status);
        li.appendChild(el('span', 'todo-box', it.status === 'completed' ? '☑' : it.status === 'in_progress' ? '▶' : '☐'));
        li.appendChild(el('span', 'todo-text', it.content));
        ul.appendChild(li);
      }
      todoBox.appendChild(ul);
    }
  }
  try { renderTodos(JSON.parse((todoBox && todoBox.dataset.todos) || '[]')); } catch (_) { renderTodos([]); }

  // ---- tool call cards --------------------------------------------------
  function showToolPending(data) {
    const details = el('details', 'tool-call pending');
    details.open = true;
    details.dataset.toolCallId = data.id;
    const where = data.target ? ` — runs on ${data.target}` : '';
    details.appendChild(el('summary', '', `Tool call: ${data.name}${where}`));
    details.appendChild(el('pre', '', data.args));
    const btns = el('div', 'tool-call-actions');
    const mkBtn = (label, msgType, always) => {
      const b = el('button', '', label);
      b.type = 'button';
      b.addEventListener('click', () => {
        ws.send(JSON.stringify({ type: msgType, id: data.id, always }));
        details.className = 'tool-call pending-resolved';
        btns.remove();
        details.appendChild(el('div', 'tool-call-note', `(${label.toLowerCase()} — waiting for result)`));
      });
      return b;
    };
    btns.appendChild(mkBtn('Approve', 'tool_call_approve', false));
    btns.appendChild(mkBtn('Approve always', 'tool_call_approve', true));
    btns.appendChild(mkBtn('Deny', 'tool_call_deny', false));
    btns.appendChild(mkBtn('Deny always', 'tool_call_deny', true));
    const killBtn = el('button', 'tool-call-kill', 'Kill');
    killBtn.type = 'button';
    killBtn.addEventListener('click', () => ws.send(JSON.stringify({ type: 'tool_call_kill', id: data.id })));
    btns.appendChild(killBtn);
    details.appendChild(btns);
    container.appendChild(details);
  }

  function showToolResult(data) {
    const existing = log.querySelector(`[data-tool-call-id="${data.id}"]`);
    const parent = existing ? existing.parentNode : container;
    if (existing) existing.remove();
    const details = el('details', 'tool-call result ' + data.status);
    details.appendChild(el('summary', '', `Tool call${data.name ? ': ' + data.name : ''} (${data.status})`));
    if (data.args) details.appendChild(el('pre', '', data.args));
    details.appendChild(el('pre', '', data.result || ''));
    parent.appendChild(details);
    // Files produced by a tool (write_file) get a download chip.
    try {
      const f = JSON.parse(data.result || '{}').data;
      if (f && f.file) parent.appendChild(el('div', 'attachments')).appendChild(fileChip(f.file));
    } catch (_) { /* not JSON */ }
  }

  // ---- sub-agent blocks -------------------------------------------------
  function startSubAgent(data) {
    finishStream(true);
    finishReasoning();
    const details = el('details', 'subagent');
    details.open = true;
    const summary = el('summary');
    const task = (data.task || '').replace(/\s+/g, ' ');
    summary.appendChild(el('span', 'subagent-label', 'Sub-agent: '));
    summary.appendChild(el('span', 'subagent-task', task.length > 90 ? task.slice(0, 90) + '…' : task));
    const status = el('span', 'subagent-status', 'running…');
    summary.appendChild(status);
    details.appendChild(summary);
    const body = el('div', 'subagent-body');
    body.appendChild(el('div', 'msg user', data.task || ''));
    details.appendChild(body);
    container.appendChild(details);
    sub = { details, body, status };
    container = body;
  }
  function endSubAgent(data) {
    finishStream(true);
    finishReasoning();
    if (sub) {
      sub.status.textContent = data.ok ? 'done' : 'failed';
      sub.status.className = 'subagent-status ' + (data.ok ? 'ok' : 'bad');
      sub.details.open = false;
    }
    sub = null;
    container = log;
  }

  // ---- incoming events --------------------------------------------------
  ws.onmessage = (ev) => handleMessage(JSON.parse(ev.data));

  function handleMessage(data) {
    switch (data.type) {
      case 'batch':
        withScroll(() => { for (const item of data.items) handleMessage(item); });
        return;
      case 'reasoning_token':
      case 'subagent_reasoning':
        pushReasoning(data.content);
        return;
      case 'assistant_token':
      case 'subagent_token':
        finishReasoning();
        pushStream(data.content);
        return;
      case 'subagent_start': startSubAgent(data); return;
      case 'subagent_end': endSubAgent(data); return;
      case 'tool_call_pending':
        finishStream(true); finishReasoning();
        showToolPending(data);
        return;
      case 'tool_call_result':
        finishStream(true); finishReasoning();
        showToolResult(data);
        return;
      case 'todo_update': renderTodos(data.items); return;
      case 'title_updated': {
        const t = document.getElementById('chat-title');
        if (t) t.textContent = data.title;
        return;
      }
      case 'error': {
        finishStream(false);
        finishReasoning();
        if (sub) endSubAgent({ ok: false });
        const div = el('div', 'msg error', data.content);
        log.appendChild(div);
        log.scrollTop = log.scrollHeight;
        setGenerating(false);
        return;
      }
      case 'assistant_message': {
        finishStream(false);
        finishReasoning();
        if (sub) endSubAgent({ ok: false });
        setGenerating(false);
        if (data.content) {
          const div = el('div', 'msg assistant md');
          richInto(div, data.content);
          log.appendChild(div);
          log.scrollTop = log.scrollHeight;
        }
        return;
      }
      default:
        appendEvent(log, data);
    }
  }

  ws.onclose = () => {
    setGenerating(false);
    log.appendChild(el('div', 'msg error', '(disconnected — reload the page to reconnect)'));
  };

  // ---- initial history render ------------------------------------------
  log.querySelectorAll('[data-md]').forEach((node) => {
    richInto(node, node.textContent);
    node.removeAttribute('data-md');
  });
  log.scrollTop = log.scrollHeight;

  log.addEventListener('click', (e) => {
    const btn = e.target.closest('.copy-btn');
    if (!btn) return;
    const code = btn.closest('.codeblock').querySelector('pre code');
    copyText(code.textContent).then(() => {
      btn.textContent = 'Copied';
      setTimeout(() => { btn.textContent = 'Copy'; }, 1200);
    });
  });

  // ---- composer: textarea (Enter sends, Shift+Enter = newline) ----------
  function autosize() {
    if (!input) return;
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 220) + 'px';
  }

  function addUserMessage(text, files) {
    withScroll(() => {
      const div = el('div', 'msg user');
      if (text) div.appendChild(document.createTextNode(text));
      if (files.length) {
        const box = el('div', 'attachments');
        files.forEach((f) => box.appendChild(fileChip(f)));
        div.appendChild(box);
      }
      log.appendChild(div);
    });
    log.scrollTop = log.scrollHeight;
  }

  function sendMessage() {
    if (!input || input.disabled) return;
    if (attachments.some((a) => a.status === 'uploading')) { note('Wait for uploads to finish…'); return; }
    const ready = attachments.filter((a) => a.status === 'ready');
    const text = input.value;
    if (!text.trim() && !ready.length) return;
    if (ws.readyState !== WebSocket.OPEN) { note('Not connected to the server.'); return; }
    ws.send(JSON.stringify({ type: 'user_message', content: text, files: ready.map((a) => a.id) }));
    addUserMessage(text, ready);
    input.value = '';
    attachments = [];
    renderAttachments();
    autosize();
    setGenerating(true);
  }

  if (input) {
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        sendMessage();
      }
    });
    input.addEventListener('input', autosize);
    input.addEventListener('paste', (e) => {
      const cd = e.clipboardData;
      if (cd && cd.files && cd.files.length && !cd.getData('text/plain')) {
        e.preventDefault();
        addFiles(cd.files);
      }
    });
    autosize();
  }
  if (form) form.addEventListener('submit', (e) => { e.preventDefault(); sendMessage(); });
  if (stopBtn) stopBtn.addEventListener('click', () => ws.send(JSON.stringify({ type: 'cancel_generation' })));

  // ---- attachments --------------------------------------------------------
  function renderAttachments() {
    if (!attachBox) return;
    attachBox.textContent = '';
    attachments.forEach((a, idx) => {
      const chip = el('span', 'attach-chip ' + a.status);
      chip.appendChild(el('span', 'attach-name', a.name));
      const state = a.status === 'uploading' ? ' …' : a.status === 'error' ? ' ⚠ ' + (a.error || 'failed') : ' (' + humanSize(a.size) + ')';
      chip.appendChild(el('small', '', state));
      const rm = el('button', 'attach-remove', '✕');
      rm.type = 'button';
      rm.title = 'Remove';
      rm.addEventListener('click', () => { attachments.splice(idx, 1); renderAttachments(); });
      chip.appendChild(rm);
      attachBox.appendChild(chip);
    });
  }

  async function uploadFile(file) {
    const item = { name: file.name || 'file', size: file.size, mime: file.type || '', id: null, status: 'uploading' };
    attachments.push(item);
    renderAttachments();
    try {
      const url = `/chat/${conversationId}/upload?name=${encodeURIComponent(item.name)}&type=${encodeURIComponent(item.mime)}`;
      const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: file });
      const data = await r.json();
      if (!data.success) throw new Error(data.error || 'upload failed');
      Object.assign(item, data.file, { status: 'ready' });
    } catch (e) {
      item.status = 'error';
      item.error = String((e && e.message) || e);
    }
    renderAttachments();
  }
  function addFiles(list) { Array.from(list).forEach(uploadFile); }

  if (attachBtn && fileInput) {
    attachBtn.addEventListener('click', () => fileInput.click());
    fileInput.addEventListener('change', () => { addFiles(fileInput.files); fileInput.value = ''; });
  }
  [log, compose].forEach((zone) => {
    if (!zone) return;
    zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('dragging'); });
    zone.addEventListener('dragleave', () => zone.classList.remove('dragging'));
    zone.addEventListener('drop', (e) => {
      e.preventDefault();
      zone.classList.remove('dragging');
      if (e.dataTransfer && e.dataTransfer.files.length) addFiles(e.dataTransfer.files);
    });
  });

  // ---- tool location selector (todo #6) -----------------------------------
  const targetSelect = document.getElementById('tool-target-select');
  if (targetSelect) {
    let prev = targetSelect.value;
    targetSelect.addEventListener('change', () => {
      const requested = targetSelect.value;
      fetch(`/chat/${conversationId}/tool-target`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target: requested }),
      })
        .then((r) => r.json())
        .then((d) => {
          if (d.success) { prev = requested; return; }
          targetSelect.value = prev;
          note('Could not change tool location: ' + (d.error || 'unknown error'));
        })
        .catch((err) => { targetSelect.value = prev; note('Could not change tool location: ' + err); });
    });
  }

  // ---- model switching ----------------------------------------------------
  const modelSelect = document.getElementById('model-select');
  if (modelSelect) {
    const previousValue = modelSelect.value;
    const fail = (msg) => {
      modelSelect.disabled = false;
      modelSelect.value = previousValue;
      log.appendChild(el('div', 'msg error', msg));
      log.scrollTop = log.scrollHeight;
    };
    modelSelect.addEventListener('change', () => {
      const requested = modelSelect.value;
      modelSelect.disabled = true;
      fetch(`/chat/${conversationId}/model`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: requested }),
      })
        .then((r) => r.json())
        .then((data) => {
          if (!data.success) { fail(`Failed to switch model: ${data.error || 'unknown error'}`); return; }
          // Accepted doesn't mean loaded — a too-big model can crash the
          // router seconds later. Poll until it's loaded or the router fails.
          pollChatModelOutcome(requested, previousValue, modelSelect, log);
        })
        .catch((err) => fail(`Failed to switch model: ${err}`));
    });
  }
}

// ---------------------------------------------------------------- models page
// The router's /models/load response only means "request accepted" — with a
// model too big for VRAM it can accept and then crash seconds later. A
// successful POST therefore starts a poll loop instead of declaring victory.
const MODEL_POLL_INTERVAL_MS = 1000;

function pollChatModelOutcome(model, previousValue, modelSelect, log) {
  const tick = () => {
    Promise.all([
      fetch('/router/status.json').then((r) => r.json()).catch(() => null),
      fetch('/models/status.json').then((r) => r.json()).catch(() => null),
    ]).then(([routerStatus, modelsStatus]) => {
      if (routerStatus && (routerStatus.state === 'crashed' || routerStatus.state === 'stopped')) {
        modelSelect.disabled = false;
        modelSelect.value = previousValue;
        const reason = routerStatus.lastCrashReason || routerStatus.state;
        log.appendChild(el('div', 'msg error', `Failed to switch model: router ${routerStatus.state} (${reason}) — see Router page`));
        log.scrollTop = log.scrollHeight;
        return;
      }
      if (modelsStatus && modelsStatus.success) {
        const entry = modelsStatus.models.find((m) => m.id === model);
        if (entry && entry.status === 'loaded') { modelSelect.disabled = false; return; }
      }
      setTimeout(tick, MODEL_POLL_INTERVAL_MS);
    });
  };
  setTimeout(tick, MODEL_POLL_INTERVAL_MS);
}

function pollModelOutcome(model, isLoad, msgSpan, btn) {
  const tick = () => {
    Promise.all([
      fetch('/router/status.json').then((r) => r.json()).catch(() => null),
      fetch('/models/status.json').then((r) => r.json()).catch(() => null),
    ]).then(([routerStatus, modelsStatus]) => {
      if (routerStatus && (routerStatus.state === 'crashed' || routerStatus.state === 'stopped')) {
        btn.disabled = false;
        if (msgSpan) {
          const reason = routerStatus.lastCrashReason || routerStatus.state;
          msgSpan.textContent = `error: router ${routerStatus.state} (${reason}) — see Router page`;
        }
        return;
      }
      if (modelsStatus && modelsStatus.success) {
        const entry = modelsStatus.models.find((m) => m.id === model);
        const status = entry ? entry.status : null;
        if (isLoad && status === 'loaded') { location.reload(); return; }
        if (!isLoad && (status === 'unloaded' || !entry)) { location.reload(); return; }
      }
      setTimeout(tick, MODEL_POLL_INTERVAL_MS);
    });
  };
  setTimeout(tick, MODEL_POLL_INTERVAL_MS);
}

function initModelsPage() {
  const table = document.getElementById('models-table');
  if (!table) return;
  table.addEventListener('click', (e) => {
    const btn = e.target.closest('.load-btn, .unload-btn');
    if (!btn) return;
    const model = btn.dataset.model;
    const isLoad = btn.classList.contains('load-btn');
    const row = document.getElementById(`model-row-${model}`);
    const msgSpan = row ? row.querySelector('.model-msg') : null;
    btn.disabled = true;
    if (msgSpan) msgSpan.textContent = isLoad ? 'loading…' : 'unloading…';
    fetch(isLoad ? '/models/load' : '/models/unload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model }),
    })
      .then((r) => r.json())
      .then((data) => {
        if (data.success) {
          pollModelOutcome(model, isLoad, msgSpan, btn);
        } else {
          btn.disabled = false;
          if (msgSpan) msgSpan.textContent = `error: ${data.error || 'unknown error'}`;
        }
      })
      .catch((err) => {
        btn.disabled = false;
        if (msgSpan) msgSpan.textContent = `error: ${err}`;
      });
  });
}

document.addEventListener('DOMContentLoaded', initModelsPage);

// Fallback renderer for event types without a dedicated handler.
function appendEvent(log, data) {
  const div = document.createElement('div');
  switch (data.type) {
    case 'user_message':
      div.className = 'msg user';
      div.textContent = data.content;
      break;
    case 'sub_conversation':
      div.className = 'sub-conversation';
      div.textContent = `[sub-conversation] ${data.summary}`;
      break;
    default:
      div.textContent = JSON.stringify(data);
  }
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
}
