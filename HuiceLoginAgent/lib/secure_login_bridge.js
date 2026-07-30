'use strict';

const timeoutMs = 30000;
const commandTimeoutMs = 5000;
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', start);

function output(result, exitCode = 0) {
  process.stdout.write(JSON.stringify(result));
  process.exitCode = exitCode;
}

function start() {
  let request;
  try {
    const frame = input.trim().replace(/^\uFEFF/, '');
    const jsonText = frame.startsWith('B64:')
      ? Buffer.from(frame.slice(4), 'base64').toString('utf8')
      : frame;
    request = JSON.parse(jsonText.replace(/^\uFEFF/, ''));
    input = '';
  } catch (_) {
    return output({ ok: false, errorCode: 'SECURE_INPUT_BAD_JSON' }, 2);
  }
  if (request.mode !== 'login') {
    return output({ ok: false, errorCode: 'UNSUPPORTED_LOGIN_MODE' }, 2);
  }

  const socket = new WebSocket(request.webSocketUrl);
  const pending = new Map();
  let nextId = 1;
  let settled = false;
  const overallTimer = setTimeout(
    () => finish({ ok: false, errorCode: 'LOGIN_BRIDGE_TIMEOUT' }, 2),
    timeoutMs
  );

  function safeDetail(value) {
    return String(value || '')
      .replace(/(password|passwd|cookie|token|authorization|bearer)\s*[:=]\s*\S+/ig, '$1=[redacted]')
      .slice(0, 600);
  }

  function clearRequest() {
    request.password = '';
    request.tenantId = '';
    request.account = '';
  }

  function finish(result, exitCode = 0) {
    if (settled) return;
    settled = true;
    clearTimeout(overallTimer);
    for (const item of pending.values()) {
      clearTimeout(item.timer);
      item.reject(new Error('CDP connection closed'));
    }
    pending.clear();
    try { socket.close(); } catch (_) {}
    clearRequest();
    output(result, exitCode);
  }

  function send(method, params = {}) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(Object.assign(new Error(`CDP command timed out: ${method}`), {
          errorCode: 'CDP_COMMAND_TIMEOUT'
        }));
      }, commandTimeoutMs);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async function evaluate(expression, returnByValue = true) {
    const response = await send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue,
      userGesture: true,
      objectGroup: 'huice-login'
    });
    if (response.exceptionDetails) {
      const detail = response.exceptionDetails;
      const text = detail.exception && detail.exception.description
        ? detail.exception.description
        : detail.text;
      throw Object.assign(new Error(safeDetail(text)), {
        errorCode: 'LOGIN_PAGE_EXECUTION_FAILED'
      });
    }
    return response.result;
  }

  async function findObject(expression) {
    const result = await evaluate(expression, false);
    return result && result.objectId ? result.objectId : null;
  }

  async function callOn(objectId, functionDeclaration, args = [], returnByValue = true) {
    const response = await send('Runtime.callFunctionOn', {
      objectId,
      functionDeclaration,
      arguments: args.map(value => ({ value })),
      awaitPromise: true,
      returnByValue,
      userGesture: true
    });
    if (response.exceptionDetails) {
      const detail = response.exceptionDetails;
      const text = detail.exception && detail.exception.description
        ? detail.exception.description
        : detail.text;
      throw Object.assign(new Error(safeDetail(text)), {
        errorCode: 'LOGIN_PAGE_EXECUTION_FAILED'
      });
    }
    return response.result && response.result.value;
  }

  async function runHttpLogin() {
    const page = await evaluate(
      '({host:location.hostname,path:location.pathname,hash:location.hash})'
    );
    if (page.value.host === 'erp.huice.com') {
      return {
        status: 'session-already-ready',
        errorCode: null,
        authMaterialPresent: true,
        loginTransport: 'existing-session'
      };
    }
    if (page.value.host !== 'login.huice.com') {
      return {
        status: 'http-login-failed',
        errorCode: 'WRONG_LOGIN_HOST',
        pageHost: page.value.host,
        loginTransport: 'same-origin-http'
      };
    }
    if (!request.serviceAgreementConfirmed) {
      return {
        status: 'service-agreement-confirmation-required',
        errorCode: 'SERVICE_AGREEMENT_CONFIRMATION_REQUIRED',
        loginTransport: 'same-origin-http'
      };
    }

    const globalObjectId = await findObject('globalThis');
    if (!globalObjectId) {
      return {
        status: 'http-login-failed',
        errorCode: 'LOGIN_PAGE_CONTEXT_NOT_FOUND',
        loginTransport: 'same-origin-http'
      };
    }

    return callOn(
      globalObjectId,
      `async function(tenantId, account, password) {
        const safeCode = value => Number.isFinite(Number(value)) ? Number(value) : null;
        const classify = code => {
          switch (Number(code)) {
            case 0: return null;
            case 100002:
            case 100004: return 'IMAGE_VERIFICATION_REQUIRED';
            case 100012: return 'SECURITY_VERIFICATION_REQUIRED';
            case 100020: return 'PASSWORD_UPDATE_REQUIRED';
            case 100041: return 'ACCOUNT_AMBIGUOUS';
            case 100070: return 'MOBILE_INITIALIZATION_REQUIRED';
            case 200009:
            case 200016: return 'INVALID_CREDENTIALS';
            default: return 'HUICE_LOGIN_BUSINESS_ERROR';
          }
        };
        const post = async (path, body) => {
          const response = await fetch(path, {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json;charset=UTF-8' },
            body: JSON.stringify(body)
          });
          let payload = null;
          try { payload = await response.json(); } catch (_) {}
          return {
            httpStatus: response.status,
            ok: response.ok,
            payload
          };
        };
        const deviceKey = 'device_uuid';
        let deviceId = localStorage.getItem(deviceKey);
        if (!deviceId || deviceId.length <= 32) {
          deviceId = (crypto.randomUUID ? crypto.randomUUID() :
            'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
              const r = Math.random() * 16 | 0;
              return (c === 'x' ? r : (r & 3 | 8)).toString(16);
            }));
          localStorage.setItem(deviceKey, deviceId);
        }

        let risk;
        try {
          risk = await post(
            '/open/tm/unified-login/v5/login/getPlatformRiskKeysByTenant',
            { tenantId }
          );
        } catch (_) {
          return {
            status: 'http-login-failed',
            errorCode: 'LOGIN_RISK_NETWORK_FAILED',
            riskHttpStatus: null,
            loginHttpStatus: null,
            loginTransport: 'same-origin-http'
          };
        }
        const riskCode = safeCode(risk.payload && risk.payload.code);
        if (!risk.ok || riskCode !== 0) {
          return {
            status: 'http-login-failed',
            errorCode: classify(riskCode) || 'LOGIN_RISK_HTTP_FAILED',
            riskHttpStatus: risk.httpStatus,
            riskResponseCode: riskCode,
            loginHttpStatus: null,
            loginTransport: 'same-origin-http'
          };
        }

        const appKeys = risk.payload && risk.payload.data &&
          Array.isArray(risk.payload.data.appKeyList)
          ? risk.payload.data.appKeyList : [];
        const huiceRiskKey = appKeys.find(item => Number(item.platformId) === 1);
        if (huiceRiskKey && huiceRiskKey.appKey && !document.querySelector('#J_secure_sdk_v2')) {
          try {
            await new Promise((resolve, reject) => {
              const script = document.createElement('script');
              const timer = setTimeout(() => reject(new Error('risk-sdk-timeout')), 2500);
              script.id = 'J_secure_sdk_v2';
              script.type = 'text/javascript';
              script.dataset.appkey = String(huiceRiskKey.appKey);
              script.src = 'https://g.alicdn.com/sj/securesdk/0.0.3/securesdk_v2.js';
              script.onload = () => { clearTimeout(timer); resolve(); };
              script.onerror = () => { clearTimeout(timer); reject(new Error('risk-sdk-load-failed')); };
              document.body.appendChild(script);
            });
          } catch (_) {
            // The official page treats risk SDK loading as best effort.
          }
        }

        let login;
        try {
          login = await post('/open/tm/unified-login/v5/login/password', {
            mobileAccount: false,
            account,
            password,
            tenantId,
            deviceId,
            oauthBindKey: '',
            authKey: '',
            clientType: 'WEB',
            eid: globalThis.$$eid || '',
            vid: globalThis.$$vid || ''
          });
        } catch (_) {
          return {
            status: 'http-login-failed',
            errorCode: 'LOGIN_HTTP_NETWORK_FAILED',
            riskHttpStatus: risk.httpStatus,
            riskResponseCode: riskCode,
            loginHttpStatus: null,
            loginTransport: 'same-origin-http'
          };
        }
        const loginCode = safeCode(login.payload && login.payload.code);
        if (!login.ok || loginCode !== 0) {
          return {
            status: 'http-login-failed',
            errorCode: classify(loginCode) || 'LOGIN_HTTP_FAILED',
            riskHttpStatus: risk.httpStatus,
            riskResponseCode: riskCode,
            loginHttpStatus: login.httpStatus,
            loginResponseCode: loginCode,
            verificationRequired: [100002, 100004, 100012].includes(loginCode),
            loginTransport: 'same-origin-http'
          };
        }

        const tokenPair = document.cookie.split(';').map(item => item.trim())
          .find(item => item.startsWith('X-HC-TOKEN='));
        const token = tokenPair ? decodeURIComponent(tokenPair.slice('X-HC-TOKEN='.length)) : '';
        if (token) localStorage.setItem('loginJwt', token);
        location.hash = '#/product_map';
        return {
          status: 'http-login-succeeded',
          errorCode: null,
          riskHttpStatus: risk.httpStatus,
          riskResponseCode: riskCode,
          loginHttpStatus: login.httpStatus,
          loginResponseCode: loginCode,
          authMaterialPresent: Boolean(token),
          loginTransport: 'same-origin-http'
        };
      }`,
      [
        String(request.tenantId || ''),
        String(request.account || ''),
        String(request.password || '')
      ]
    );
  }

  socket.addEventListener('open', async () => {
    try {
      const value = await runHttpLogin();
      try { await send('Runtime.releaseObjectGroup', { objectGroup: 'huice-login' }); } catch (_) {}
      finish({ ok: true, value });
    } catch (error) {
      finish({
        ok: false,
        errorCode: error.errorCode || 'LOGIN_PAGE_EXECUTION_FAILED',
        detail: safeDetail(error.message)
      }, 2);
    }
  });

  socket.addEventListener('message', event => {
    let message;
    try {
      message = JSON.parse(String(event.data));
    } catch (_) {
      return finish({ ok: false, errorCode: 'CDP_BAD_JSON' }, 2);
    }
    if (typeof message.id !== 'number') return;
    const item = pending.get(message.id);
    if (!item) return;
    clearTimeout(item.timer);
    pending.delete(message.id);
    if (message.error) {
      item.reject(Object.assign(new Error(safeDetail(message.error.message)), {
        errorCode: 'CDP_RUNTIME_ERROR'
      }));
    } else {
      item.resolve(message.result || {});
    }
  });
  socket.addEventListener('error', () => finish({ ok: false, errorCode: 'CDP_CONNECT_FAILED' }, 2));
}
