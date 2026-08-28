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
          modelSelect.disabled = false;
          if (!data.success) {
            modelSelect.value = previousValue;
            const div = document.createElement('div');
            div.className = 'msg error';
            div.textContent = `Failed to switch model: ${data.error || 'unknown error'}`;
            log.appendChild(div);
            log.scrollTop = log.scrollHeight;
          }
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
        btn.disabled = false;
        if (data.success) {
          location.reload();
        } else if (msgSpan) {
          msgSpan.textContent = `error: ${data.error || 'unknown error'}`;
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
