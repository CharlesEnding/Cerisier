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
  let streamingDiv = null;

  function setGenerating(isGenerating) {
    if (stopBtn) stopBtn.style.display = isGenerating ? '' : 'none';
  }

  ws.onmessage = (ev) => {
    const data = JSON.parse(ev.data);
    if (data.type === 'assistant_token') {
      if (!streamingDiv) {
        streamingDiv = document.createElement('div');
        streamingDiv.className = 'msg';
        log.appendChild(streamingDiv);
        setGenerating(true);
      }
      streamingDiv.textContent += data.content;
      log.scrollTop = log.scrollHeight;
      return;
    }
    if (data.type === 'assistant_message') {
      if (streamingDiv) {
        streamingDiv.remove();
        streamingDiv = null;
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
      const input = document.getElementById('chat-input');
      if (!input.value.trim()) return;
      ws.send(JSON.stringify({type: 'user_message', content: input.value}));
      appendEvent(log, {type: 'user_message', content: input.value});
      input.value = '';
    });
  }

  if (stopBtn) {
    stopBtn.addEventListener('click', () => {
      ws.send(JSON.stringify({type: 'cancel_generation'}));
    });
  }

  const modelSelect = document.getElementById('model-select');
  if (modelSelect) {
    modelSelect.addEventListener('change', () => {
      fetch(`/chat/${conversationId}/model`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({model: modelSelect.value}),
      });
    });
  }
}

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
