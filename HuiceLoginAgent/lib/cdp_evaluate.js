'use strict';

const request = JSON.parse(Buffer.from(process.argv[2] || '', 'base64').toString('utf8'));
const timeoutMs = 20000;
let settled = false;
const socket = new WebSocket(request.webSocketUrl);
const timer = setTimeout(() => finish({ ok: false, errorCode: 'CDP_TIMEOUT' }, 2), timeoutMs);

function finish(result, exitCode = 0) {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  try { socket.close(); } catch (_) {}
  process.stdout.write(JSON.stringify(result));
  process.exitCode = exitCode;
}

socket.addEventListener('open', () => {
  socket.send(JSON.stringify({
    id: 1,
    method: 'Runtime.evaluate',
    params: {
      expression: request.expression,
      awaitPromise: true,
      returnByValue: true
    }
  }));
});

socket.addEventListener('message', event => {
  let message;
  try { message = JSON.parse(String(event.data)); }
  catch (_) { return finish({ ok: false, errorCode: 'CDP_BAD_JSON' }, 2); }
  if (message.id !== 1) return;
  if (message.error || (message.result && message.result.exceptionDetails)) {
    return finish({ ok: false, errorCode: 'CDP_EVALUATE_FAILED' }, 2);
  }
  finish({ ok: true, value: message.result && message.result.result && message.result.result.value });
});

socket.addEventListener('error', () => finish({ ok: false, errorCode: 'CDP_CONNECT_FAILED' }, 2));
