// Sidebar toggle (vanilla JS, no framework).
function toggleSidebar() {
  document.body.classList.toggle('sidebar-collapsed');
}

// Chat page live updates over WebSocket. Only this page updates in-place;
// every other page in the app is a normal full-page load.
function connectChat(conversationId) {
  const log = document.getElementById('chat-log');
  if (!log) return;
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const ws = new WebSocket(`${proto}//${location.host}/ws/chat/${conversationId}`);
  const stopBtn = document.getElementById('stop-btn');
  const input = document.getElementById('chat-input');
  const sendBtn = document.querySelector('#chat-form button[type="submit"]');
  let streamingDiv = null;
  let reasoningDetails = null;
  let reasoningBody = null;

  function setGenerating(isGenerating) {
    if (stopBtn) stopBtn.style.display = isGenerating ? '' : 'none';
    if (input) input.disabled = isGenerating;
    if (sendBtn) sendBtn.disabled = isGenerating;
  }

  ws.onmessage = (ev) => {
    const data = JSON.parse(ev.data);
    handleMessage(data);
  };

  function handleMessage(data) {
    if (data.type === 'batch') {
      for (const item of data.items) handleMessage(item);
      return;
    }
    if (data.type === 'reasoning_token') {
      if (!reasoningDetails) {
        reasoningDetails = document.createElement('details');
        reasoningDetails.className = 'reasoning';
        reasoningDetails.open = true; // visible while actively reasoning
        const summary = document.createElement('summary');
        summary.textContent = 'Reasoning';
        reasoningBody = document.createElement('div');
        reasoningDetails.appendChild(summary);
        reasoningDetails.appendChild(reasoningBody);
        log.appendChild(reasoningDetails);
      }
      reasoningBody.textContent += data.content;
      log.scrollTop = log.scrollHeight;
      return;
    }
    if (data.type === 'assistant_token') {
      if (!streamingDiv) {
        streamingDiv = document.createElement('div');
        streamingDiv.className = 'msg';
        log.appendChild(streamingDiv);
      }
      streamingDiv.textContent += data.content;
      log.scrollTop = log.scrollHeight;
      return;
    }
    if (data.type === 'error') {
      if (streamingDiv) {
        streamingDiv.remove();
        streamingDiv = null;
      }
      if (reasoningDetails) {
        reasoningDetails.open = false;
        reasoningDetails = null;
        reasoningBody = null;
      }
      const div = document.createElement('div');
      div.className = 'msg error';
      div.textContent = data.content;
      log.appendChild(div);
      log.scrollTop = log.scrollHeight;
      setGenerating(false);
      return;
    }
    if (data.type === 'tool_call_pending') {
      const details = document.createElement('details');
      details.className = 'tool-call pending';
      details.open = true;
      details.dataset.toolCallId = data.id;
      const summary = document.createElement('summary');
      summary.textContent = `Tool call: ${data.name}`;
      details.appendChild(summary);
      const argsPreview = document.createElement('pre');
      argsPreview.textContent = data.args;
      details.appendChild(argsPreview);
      const btns = document.createElement('div');
      btns.className = 'tool-call-actions';
      const mkBtn = (label, msgType, always) => {
        const b = document.createElement('button');
        b.textContent = label;
        b.addEventListener('click', () => {
          ws.send(JSON.stringify({type: msgType, id: data.id, always}));
          details.className = 'tool-call pending-resolved';
          btns.remove();
          const note = document.createElement('div');
          note.className = 'tool-call-note';
          note.textContent = `(${label.toLowerCase()} — waiting for result)`;
          details.appendChild(note);
        });
        return b;
      };
      btns.appendChild(mkBtn('Approve', 'tool_call_approve', false));
      btns.appendChild(mkBtn('Approve always', 'tool_call_approve', true));
      btns.appendChild(mkBtn('Deny', 'tool_call_deny', false));
      btns.appendChild(mkBtn('Deny always', 'tool_call_deny', true));
      const killBtn = document.createElement('button');
      killBtn.textContent = 'Kill';
      killBtn.className = 'tool-call-kill';
      killBtn.addEventListener('click', () => {
        ws.send(JSON.stringify({type: 'tool_call_kill', id: data.id}));
      });
      btns.appendChild(killBtn);
      details.appendChild(btns);
      log.appendChild(details);
      log.scrollTop = log.scrollHeight;
      return;
    }
    if (data.type === 'tool_call_result') {
      const existing = log.querySelector(`[data-tool-call-id="${data.id}"]`);
      if (existing) existing.remove();
      const details = document.createElement('details');
      details.className = 'tool-call result ' + data.status;
      const summary = document.createElement('summary');
      summary.textContent = `Tool call (${data.status})`;
      details.appendChild(summary);
      const pre = document.createElement('pre');
      pre.textContent = data.result;
      details.appendChild(pre);
      log.appendChild(details);
      log.scrollTop = log.scrollHeight;
      return;
    }
    if (data.type === 'assistant_message') {
      if (streamingDiv) {
        streamingDiv.remove();
        streamingDiv = null;
      }
      if (reasoningDetails) {
        reasoningDetails.open = false; // collapse once the answer is done
        reasoningDetails = null;
        reasoningBody = null;
      }
      setGenerating(false);
    }
    if (data.type === 'title_updated') {
      const titleEl = document.getElementById('chat-title');
      if (titleEl) titleEl.textContent = data.title;
      return;
    }
    appendEvent(log, data);
  };
  ws.onclose = () => {
    setGenerating(false);
    const div = document.createElement('div');
    div.textContent = '(disconnected)';
    log.appendChild(div);
  };

  const form = document.getElementById('chat-form');
  if (form) {
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      if (!input.value.trim() || input.disabled) return;
      ws.send(JSON.stringify({type: 'user_message', content: input.value}));
      appendEvent(log, {type: 'user_message', content: input.value});
      input.value = '';
      setGenerating(true);
    });
  }

  if (stopBtn) {
    stopBtn.addEventListener('click', () => {
      ws.send(JSON.stringify({type: 'cancel_generation'}));
    });
  }

  const modelSelect = document.getElementById('model-select');
  if (modelSelect) {
    const previousValue = modelSelect.value;
    modelSelect.addEventListener('change', () => {
      const requested = modelSelect.value;
      modelSelect.disabled = true;
      fetch(`/chat/${conversationId}/model`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({model: requested}),
      })
        .then((r) => r.json())
        .then((data) => {
          if (!data.success) {
            modelSelect.disabled = false;
            modelSelect.value = previousValue;
            const div = document.createElement('div');
            div.className = 'msg error';
            div.textContent = `Failed to switch model: ${data.error || 'unknown error'}`;
            log.appendChild(div);
            log.scrollTop = log.scrollHeight;
            return;
          }
          // Accepted doesn't mean loaded — a too-big model can crash the
          // router seconds later, after this response already came back.
          // Poll until it's actually loaded or the router reports trouble.
          pollChatModelOutcome(requested, previousValue, modelSelect, log);
        })
        .catch((err) => {
          modelSelect.disabled = false;
          modelSelect.value = previousValue;
          const div = document.createElement('div');
          div.className = 'msg error';
          div.textContent = `Failed to switch model: ${err}`;
          log.appendChild(div);
          log.scrollTop = log.scrollHeight;
        });
    });
  }
}

// Models page: Load/Unload buttons are plain buttons (not form submits) so
// we can show inline success/error feedback without a page reload on
// failure (a failed load previously looked identical to a successful one).
//
// The router's /models/load response only means "request accepted" — with
// a model too big for VRAM, the router can accept the request and then
// crash a few seconds later while actually loading it, well after this
// fetch already resolved successfully. So a successful POST starts a poll
// loop (checking both the router's crash state and the model's own status)
// instead of immediately declaring victory. Polls indefinitely (no
// timeout/give-up): a load can legitimately take a long time, and the
// only two real outcomes are "it loaded" or "the router crashed/stopped",
// both of which this keeps watching for.
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
        const div = document.createElement('div');
        div.className = 'msg error';
        const reason = routerStatus.lastCrashReason || routerStatus.state;
        div.textContent = `Failed to switch model: router ${routerStatus.state} (${reason}) — see Router page`;
        log.appendChild(div);
        log.scrollTop = log.scrollHeight;
        return;
      }
      if (modelsStatus && modelsStatus.success) {
        const entry = modelsStatus.models.find((m) => m.id === model);
        if (entry && entry.status === 'loaded') {
          modelSelect.disabled = false;
          return;
        }
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
        if (isLoad && status === 'loaded') {
          location.reload();
          return;
        }
        if (!isLoad && (status === 'unloaded' || !entry)) {
          location.reload();
          return;
        }
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
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({model}),
    })
      .then((r) => r.json())
      .then((data) => {
        if (data.success) {
          // Request accepted — keep polling until the real outcome (loaded,
          // or the router crashed trying) is known.
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

function appendEvent(log, data) {
  const div = document.createElement('div');
  switch (data.type) {
    case 'user_message':
      div.className = 'msg user';
      div.textContent = data.content;
      break;
    case 'assistant_message':
      div.className = 'msg';
      div.textContent = data.content;
      break;
    case 'reasoning':
      div.className = 'reasoning';
      div.textContent = data.content;
      break;
    case 'tool_call':
      div.className = 'tool-call';
      div.textContent = `[tool] ${data.tool} ${data.status} — args: ${data.args}`;
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
