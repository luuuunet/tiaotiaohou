const status = document.querySelector('#status');
const detail = document.querySelector('#detail');
const port = document.querySelector('#port');
const toggle = document.querySelector('#toggle');
let running = false;

function paint(state) {
  running = Boolean(state?.running);
  status.textContent = running ? '浏览器已连接' : '未连接';
  detail.textContent = state?.detail || '';
  if (document.activeElement !== port) {
    port.value = String(state?.port || 8080);
  }
  toggle.textContent = running ? '断开' : '开始连接';
  toggle.classList.toggle('on', running);
}

async function ask(message) {
  return chrome.runtime.sendMessage(message);
}

toggle.addEventListener('click', async () => {
  toggle.disabled = true;
  toggle.classList.add('busy');
  try {
    const state = await ask(running
      ? { type: 'disconnect' }
      : { type: 'connect', port: port.value });
    paint(state);
  } catch {
    detail.textContent = '扩展没有回应，请关掉这个窗口再打开';
  } finally {
    toggle.disabled = false;
    toggle.classList.remove('busy');
  }
});

ask({ type: 'state' }).then(paint);
