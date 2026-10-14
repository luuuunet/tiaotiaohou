const status = document.querySelector('#status');
const detail = document.querySelector('#detail');
const port = document.querySelector('#port');
const toggle = document.querySelector('#toggle');

function paint(state) {
  status.textContent = state.running ? '浏览器已连接' : '未连接';
  detail.textContent = state.detail || '';
  port.value = String(state.port || 8080);
  toggle.textContent = state.running ? '断开' : '开始连接';
  toggle.classList.toggle('on', Boolean(state.running));
}

async function ask(message) {
  return chrome.runtime.sendMessage(message);
}

toggle.addEventListener('click', async () => {
  toggle.disabled = true;
  toggle.classList.add('busy');
  try {
    const state = await ask(toggle.classList.contains('on')
      ? { type: 'disconnect' }
      : { type: 'connect', port: port.value });
    paint(state);
  } finally {
    toggle.disabled = false;
    toggle.classList.remove('busy');
  }
});

ask({ type: 'state' }).then(paint);
