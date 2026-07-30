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

  function keyMetadata(character) {
    const upper = character.toUpperCase();
    const isLetter = /^[A-Z]$/.test(upper);
    const isDigit = /^[0-9]$/.test(character);
    return {
      key: character,
      code: isLetter ? `Key${upper}` : (isDigit ? `Digit${character}` : ''),
      windowsVirtualKeyCode: isLetter
        ? upper.charCodeAt(0)
        : (isDigit ? character.charCodeAt(0) : 0)
    };
  }

  async function typeTextAsKeyEvents(value) {
    for (const character of Array.from(value)) {
      const key = keyMetadata(character);
      await send('Input.dispatchKeyEvent', {
        type: 'keyDown',
        key: key.key,
        code: key.code,
        text: character,
        unmodifiedText: character,
        windowsVirtualKeyCode: key.windowsVirtualKeyCode,
        nativeVirtualKeyCode: key.windowsVirtualKeyCode
      });
      await send('Input.dispatchKeyEvent', {
        type: 'keyUp',
        key: key.key,
        code: key.code,
        windowsVirtualKeyCode: key.windowsVirtualKeyCode,
        nativeVirtualKeyCode: key.windowsVirtualKeyCode
      });
      await sleep(25);
    }
  }

  async function fillField(expression, value) {
    let objectId = await findObject(expression);
    if (!objectId) {
      return { present: false, matches: false, actualLength: 0, expectedLength: value.length };
    }
    await callOn(objectId, 'function(){this.focus();this.select();return true;}');
    await send('Input.dispatchKeyEvent', {
      type: 'rawKeyDown',
      key: 'Backspace',
      code: 'Backspace',
      windowsVirtualKeyCode: 8,
      nativeVirtualKeyCode: 8
    });
    await send('Input.dispatchKeyEvent', {
      type: 'keyUp',
      key: 'Backspace',
      code: 'Backspace',
      windowsVirtualKeyCode: 8,
      nativeVirtualKeyCode: 8
    });
    // Input.insertText behaves like IME text insertion and can leave a Vue
    // component's model behind the visible DOM value. Real key events keep the
    // Element Plus input model and the displayed value on the same path.
    await typeTextAsKeyEvents(value);
    await callOn(objectId, 'function(){this.dispatchEvent(new Event("change",{bubbles:true}));this.blur();return true;}');
    await sleep(300);

    objectId = await findObject(expression);
    if (!objectId) {
      return { present: false, matches: false, actualLength: 0, expectedLength: value.length };
    }
    const verification = await callOn(
      objectId,
      'function(expected){const actual=String(this.value||"");return {present:true,matches:actual===expected,actualLength:actual.length,expectedLength:expected.length};}',
      [value]
    );
    return verification;
  }

  async function verifyField(expression, value) {
    const objectId = await findObject(expression);
    if (!objectId) {
      return { present: false, matches: false, actualLength: 0, expectedLength: value.length };
    }
    return callOn(
      objectId,
      'function(expected){const actual=String(this.value||"");return {present:true,matches:actual===expected,actualLength:actual.length,expectedLength:expected.length};}',
      [value]
    );
  }

  function summarizeSnapshot(snapshot) {
    return {
      fieldsMatched: {
        tenant: Boolean(snapshot.tenant.matches),
        account: Boolean(snapshot.account.matches),
        password: Boolean(snapshot.password.matches)
      },
      fieldLengths: {
        tenant: { actual: snapshot.tenant.actualLength, expected: snapshot.tenant.expectedLength },
        account: { actual: snapshot.account.actualLength, expected: snapshot.account.expectedLength },
        password: { actual: snapshot.password.actualLength, expected: snapshot.password.expectedLength }
      }
    };
  }

  function snapshotMatches(snapshot) {
    return Boolean(
      snapshot.tenant.present && snapshot.tenant.matches &&
      snapshot.account.present && snapshot.account.matches &&
      snapshot.password.present && snapshot.password.matches
    );
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

  // Retained only as an explicitly limited diagnostic fallback. The production
  // Login path calls runHttpLogin and never invokes this form automation.
  async function runLegacyFormLogin() {
    const page = await evaluate(
      '({host:location.hostname,path:location.pathname,hash:location.hash})'
    );
    if (page.value.host === 'erp.huice.com') {
      return { status: 'session-already-ready', errorCode: null, authMaterialPresent: true };
    }
    if (page.value.host !== 'login.huice.com') {
      return { status: 'login-failed', errorCode: 'WRONG_LOGIN_HOST' };
    }

    const visible = 'const visible=e=>!!(e&&!e.disabled&&e.getClientRects().length&&getComputedStyle(e).visibility!=="hidden");';
    const tenantExpression = `(()=>{${visible}return [...document.querySelectorAll('input[name="merchantId"],input[placeholder*="\\u5356\\u5bb6"],input[placeholder*="\\u4e3b\\u8d26\\u53f7"]')].find(visible)||null;})()`;
    const accountExpression = `(()=>{${visible}return [...document.querySelectorAll('input[placeholder*="\\u8d26\\u53f7\\u540d"],input[placeholder*="\\u624b\\u673a\\u53f7"]')].find(visible)||null;})()`;
    const passwordExpression = `(()=>{${visible}return [...document.querySelectorAll('input[name="password"],input[type="password"],input[placeholder*="\\u5bc6\\u7801"]')].find(visible)||null;})()`;

    const expected = {
      tenant: String(request.tenantId || ''),
      account: String(request.account || ''),
      password: String(request.password || '')
    };
    const readSnapshot = async () => ({
      tenant: await verifyField(tenantExpression, expected.tenant),
      account: await verifyField(accountExpression, expected.account),
      password: await verifyField(passwordExpression, expected.password)
    });
    const initial = {
      tenant: await fillField(tenantExpression, expected.tenant),
      account: await fillField(accountExpression, expected.account),
      password: await fillField(passwordExpression, expected.password)
    };
    await sleep(750);
    const stablePassOne = await readSnapshot();
    await sleep(750);
    const stablePassTwo = await readSnapshot();
    const tenant = stablePassTwo.tenant;
    const account = stablePassTwo.account;
    const password = stablePassTwo.password;
    const fieldsMatched = {
      tenant: Boolean(initial.tenant.matches && stablePassOne.tenant.matches && stablePassTwo.tenant.matches),
      account: Boolean(initial.account.matches && stablePassOne.account.matches && stablePassTwo.account.matches),
      password: Boolean(initial.password.matches && stablePassOne.password.matches && stablePassTwo.password.matches)
    };
    const fieldLengths = {
      tenant: { actual: tenant.actualLength, expected: tenant.expectedLength },
      account: { actual: account.actualLength, expected: account.expectedLength },
      password: { actual: password.actualLength, expected: password.expectedLength }
    };
    if (!tenant.present || !account.present || !password.present) {
      return {
        status: 'login-form-not-ready',
        errorCode: 'LOGIN_FORM_FIELDS_NOT_FOUND',
        fieldsPresent: {
          tenant: Boolean(tenant.present),
          account: Boolean(account.present),
          password: Boolean(password.present)
        },
        fieldsMatched,
        fieldLengths
      };
    }
    if (!fieldsMatched.tenant || !fieldsMatched.account || !fieldsMatched.password) {
      return {
        status: 'login-form-value-mismatch',
        errorCode: 'LOGIN_FORM_VALUE_MISMATCH',
        fieldsMatched,
        fieldLengths,
        stabilityPasses: 2,
        submitButtonClicked: false
      };
    }

    const agreementExpression = `(()=>{${visible}return [...document.querySelectorAll('input[type="checkbox"]')].find(e=>visible(e)&&(String((e.closest('label')||e.parentElement&&e.parentElement.parentElement||{}).innerText||'').includes('\\u534f\\u8bae')||String(document.body&&document.body.innerText||'').includes('\\u670d\\u52a1\\u534f\\u8bae')))||null;})()`;
    const agreementId = await findObject(agreementExpression);
    let agreementChecked = true;
    if (agreementId) {
      agreementChecked = Boolean(await callOn(agreementId, 'function(){return !!this.checked;}'));
      if (!agreementChecked && !request.serviceAgreementConfirmed) {
        return {
          status: 'service-agreement-confirmation-required',
          errorCode: 'SERVICE_AGREEMENT_CONFIRMATION_REQUIRED',
          fieldsMatched,
          fieldLengths,
          submitButtonClicked: false,
          agreementPresent: true,
          agreementChecked: false
        };
      }
      if (!agreementChecked) {
        agreementChecked = Boolean(await callOn(
          agreementId,
          'function(){this.click();return !!this.checked;}'
        ));
        await sleep(500);
      }
      if (!agreementChecked) {
        return {
          status: 'service-agreement-confirmation-failed',
          errorCode: 'SERVICE_AGREEMENT_CHECK_FAILED',
          fieldsMatched,
          fieldLengths,
          submitButtonClicked: false,
          agreementPresent: true,
          agreementChecked: false
        };
      }
      const afterAgreement = await readSnapshot();
      if (!snapshotMatches(afterAgreement)) {
        const safe = summarizeSnapshot(afterAgreement);
        return {
          status: 'login-form-value-mismatch',
          errorCode: 'LOGIN_FORM_VALUE_MISMATCH',
          mismatchStage: 'after-service-agreement',
          fieldsMatched: safe.fieldsMatched,
          fieldLengths: safe.fieldLengths,
          stabilityPasses: 3,
          submitButtonClicked: false,
          agreementPresent: true,
          agreementChecked: true
        };
      }
    }

    const buttonExpression = `(()=>{${visible}return [...document.querySelectorAll('button.login-submit-account,button.login-submit,button')].find(e=>visible(e)&&((e.classList.contains('login-submit-account')||e.classList.contains('login-submit'))||['\\u767b\\u5f55','\\u786e\\u5b9a','\\u786e\\u8ba4'].includes(String(e.innerText||'').replace(/\\s/g,''))))||null;})()`;
    const buttonId = await findObject(buttonExpression);
    if (!buttonId) {
      return {
        status: 'login-form-submit-failed',
        errorCode: 'LOGIN_SUBMIT_BUTTON_NOT_FOUND',
        fieldsMatched,
        fieldLengths,
        submitButtonClicked: false
      };
    }
    const buttonPosition = await callOn(
      buttonId,
      'function(){this.focus();const r=this.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2,visible:!!(r.width&&r.height)};}'
    );
    await sleep(500);
    const preSubmit = await readSnapshot();
    if (!snapshotMatches(preSubmit)) {
      const safe = summarizeSnapshot(preSubmit);
      return {
        status: 'login-form-value-mismatch',
        errorCode: 'LOGIN_FORM_VALUE_MISMATCH',
        mismatchStage: 'after-submit-focus',
        fieldsMatched: safe.fieldsMatched,
        fieldLengths: safe.fieldLengths,
        stabilityPasses: 3,
        submitButtonClicked: false
      };
    }
    if (!buttonPosition || !buttonPosition.visible) {
      return {
        status: 'login-form-submit-failed',
        errorCode: 'LOGIN_SUBMIT_BUTTON_NOT_VISIBLE',
        fieldsMatched,
        fieldLengths,
        submitButtonClicked: false
      };
    }
    await send('Input.dispatchMouseEvent', {
      type: 'mouseMoved',
      x: buttonPosition.x,
      y: buttonPosition.y
    });
    await send('Input.dispatchMouseEvent', {
      type: 'mousePressed',
      x: buttonPosition.x,
      y: buttonPosition.y,
      button: 'left',
      clickCount: 1
    });
    await send('Input.dispatchMouseEvent', {
      type: 'mouseReleased',
      x: buttonPosition.x,
      y: buttonPosition.y,
      button: 'left',
      clickCount: 1
    });
    await sleep(500);

    const afterSubmitPage = await evaluate(
      '({host:location.hostname,path:location.pathname,hash:location.hash})'
    );
    if (afterSubmitPage.value.host === 'login.huice.com') {
      const postSubmit = await readSnapshot();
      if (!snapshotMatches(postSubmit)) {
        const safe = summarizeSnapshot(postSubmit);
        return {
          status: 'login-form-value-mismatch',
          errorCode: 'LOGIN_FORM_VALUE_MISMATCH',
          mismatchStage: 'immediately-after-submit',
          pageHost: afterSubmitPage.value.host,
          fieldsMatched: safe.fieldsMatched,
          fieldLengths: safe.fieldLengths,
          stabilityPasses: 3,
          submitButtonClicked: true
        };
      }
    }

    const consentExpression = `(()=>{${visible}const dialogs=[...document.querySelectorAll('.el-dialog,.el-message-box')].filter(visible);return dialogs.flatMap(d=>[...d.querySelectorAll('button')]).find(e=>visible(e)&&String(e.innerText||'').replace(/\\s/g,'')==='\\u540c\\u610f')||null;})()`;
    const consentId = await findObject(consentExpression);
    if (consentId) {
      await callOn(consentId, 'function(){this.focus();this.click();return true;}');
    }
    return {
      status: 'login-form-submitted',
      errorCode: null,
      pageHost: page.value.host,
      pagePath: page.value.path,
      fieldsMatched,
      fieldLengths,
      stabilityPasses: 3,
      submitButtonClicked: true,
      consentButtonClicked: Boolean(consentId),
      agreementPresent: Boolean(agreementId),
      agreementChecked,
      submitMode: 'cdp-browser-input'
    };
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

function sleep(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}
