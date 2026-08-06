from __future__ import annotations

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request
from typing import Any


def _send_ws(sock: socket.socket, payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    header = bytearray([0x81])
    size = len(data)
    if size < 126:
        header.append(0x80 | size)
    elif size < 65536:
        header.extend(bytes([0x80 | 126]) + struct.pack("!H", size))
    else:
        header.extend(bytes([0x80 | 127]) + struct.pack("!Q", size))
    mask = os.urandom(4)
    header.extend(mask)
    sock.sendall(header + bytes(byte ^ mask[index % 4] for index, byte in enumerate(data)))


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("CDP websocket closed.")
        data.extend(chunk)
    return bytes(data)


def _recv_ws(sock: socket.socket) -> dict[str, Any]:
    while True:
        b1, b2 = _recv_exact(sock, 2)
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        size = b2 & 0x7F
        if size == 126:
            size = struct.unpack("!H", _recv_exact(sock, 2))[0]
        elif size == 127:
            size = struct.unpack("!Q", _recv_exact(sock, 8))[0]
        mask = _recv_exact(sock, 4) if masked else b""
        payload = bytearray(_recv_exact(sock, size))
        if masked:
            payload = bytearray(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 8:
            raise RuntimeError("CDP websocket closed by remote.")
        if opcode == 9:
            continue
        if opcode in (1, 2):
            return json.loads(bytes(payload).decode("utf-8", "replace"))


def _connect_ws(websocket_url: str) -> socket.socket:
    parsed = urllib.parse.urlparse(websocket_url)
    if parsed.scheme != "ws" or parsed.hostname not in {"127.0.0.1", "localhost"}:
        raise RuntimeError("Only local CDP websocket URLs are allowed.")
    sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {parsed.hostname}:{parsed.port or 80}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode("ascii")
    sock.sendall(request)
    response = sock.recv(4096)
    status = response.split(b"\r\n", 1)[0]
    if b" 101 " not in status:
        raise RuntimeError("CDP websocket handshake failed.")
    return sock


def _load_huice_target(port: int, preferred_host: str = "") -> dict[str, Any]:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=8) as response:
        targets = json.loads(response.read().decode("utf-8", "replace"))
    if preferred_host:
        for target in targets:
            if target.get("type") == "page" and preferred_host in str(target.get("url") or ""):
                return target
    for target in targets:
        url = str(target.get("url") or "")
        if target.get("type") == "page" and ("erp.huice.com" in url or "fx.huiscm.cn" in url):
            return target
    raise RuntimeError("Huice ERP page target was not found.")


def _js_literal(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _evaluate(websocket_url: str, expression: str, timeout_seconds: int) -> Any:
    sock = _connect_ws(websocket_url)
    try:
        sock.settimeout(max(5, timeout_seconds))
        _send_ws(
            sock,
            {
                "id": 1,
                "method": "Runtime.evaluate",
                "params": {
                    "expression": expression,
                    "awaitPromise": True,
                    "returnByValue": True,
                },
            },
        )
        while True:
            message = _recv_ws(sock)
            if message.get("id") != 1:
                continue
            result = message.get("result", {}).get("result", {})
            if result.get("subtype") == "error":
                raise RuntimeError(str(result.get("description") or "CDP evaluation failed."))
            return result.get("value")
    finally:
        sock.close()


def _navigate(websocket_url: str, url: str, timeout_seconds: int) -> None:
    sock = _connect_ws(websocket_url)
    try:
        sock.settimeout(max(5, min(timeout_seconds, 30)))
        _send_ws(sock, {"id": 1, "method": "Page.enable", "params": {}})
        _send_ws(sock, {"id": 2, "method": "Page.navigate", "params": {"url": url}})
        deadline = time.monotonic() + max(5, min(timeout_seconds, 30))
        while time.monotonic() < deadline:
            message = _recv_ws(sock)
            if message.get("id") == 2:
                break
        time.sleep(3)
    finally:
        sock.close()


def _build_expression(request: dict[str, Any]) -> str:
    method = str(request.get("method") or "POST").upper()
    path = str(request.get("path") or "")
    body = request.get("body")
    max_pages = int(request.get("maxPages") or 1)
    page_size = int(request.get("pageSize") or (body or {}).get("pageSize") or 20)
    return f"""
(async () => {{
  const request = {{
    method: {_js_literal(method)},
    path: {_js_literal(path)},
    body: {_js_literal(body if body is not None else {{}})},
    maxPages: {_js_literal(max_pages)},
    pageSize: {_js_literal(page_size)}
  }};
  const isOpenApi = request.path.startsWith('/openapi/');
  const classify = (http, json) => {{
    const text = String((json && (json.message || json.msg || json.errorMessage)) || '').toLowerCase();
    const code = json && (json.error ?? json.code ?? json.status);
    if (http === 401 || code === 401 || text.includes('登录已过期') || text.includes('token')) return 'SESSION_EXPIRED';
    if (http === 403 || code === 403 || text.includes('权限不足') || text.includes('无权限')) return 'PERMISSION_DENIED';
    if (text.includes('参数')) return 'BUSINESS_PARAMETER_ERROR';
    return 'BUSINESS_ERROR';
  }};
  const summarizeItem = (item) => {{
    if (!item || typeof item !== 'object') return item;
    const keys = [
      'goodsId','goodsName','outerGoodsSn','categoryName','brandName','operator',
      'supplierCompanyName','supCompanyAlias','supplierShopId','supplierSid',
      'supplierNickNo','supplierGoodsId','supplierSysId','cooperationStatus',
      'sourceGoodsId','providerGoodsId','sourcePlatformId','createTime','updateTime','uploadTime',
      'hotGoodsUploadDate','imgUrl','tail','joinList','distributorGoodsId','salesVolume',
      'salesVolumeFifteen','nearlySevenSalesVolume','estimatedEarn','estimateProfit',
      'estimatedProfit','suggestedPrice','suggestPrice','retailPrice','distributorPrice',
      'distributionPrice','disPrice','choiceComplatedPlatformIds','completePlatformIds',
      'goodsTags','priceControl'
    ];
    const out = {{}};
    for (const key of keys) {{
      if (Object.prototype.hasOwnProperty.call(item, key)) out[key] = item[key];
    }}
    if (request.path.includes('/distributor/supplier/goods/list')) {{
      if (out.supplierGoodsId === undefined && item.goodsId !== undefined) out.supplierGoodsId = item.goodsId;
      if (out.supplierShopId === undefined && request.body && request.body.supplierShopId !== undefined) out.supplierShopId = request.body.supplierShopId;
    }}
    if (request.path.includes('/distributor/goods/list') && out.distributorGoodsId === undefined && item.goodsId !== undefined) {{
      out.distributorGoodsId = item.goodsId;
      if (out.supplierGoodsId === undefined) out.supplierGoodsId = item.supplierGoodsId ?? item.sourceGoodsId ?? item.providerGoodsId;
      if (out.supplierShopId === undefined) out.supplierShopId = item.supplierShopId ?? item.supplierSysShopId ?? item.shopId;
    }}
    if (request.path.includes('/hotGoods/recommend')) {{
      if (out.supplierGoodsId === undefined) out.supplierGoodsId = item.goodsId ?? item.supplierGoodsId ?? item.sourceGoodsId;
      if (out.supplierShopId === undefined) out.supplierShopId = item.supplierShopId ?? item.shopId ?? item.supplierId;
    }}
    const skus = Array.isArray(item.skus) ? item.skus : (Array.isArray(item.itemList) ? item.itemList : []);
    const itemIds = [];
    for (const sku of skus) {{
      if (typeof sku === 'number') itemIds.push(sku);
      else if (sku && typeof sku === 'object') {{
        const value = sku.itemId ?? sku.id ?? sku.specId ?? sku.skuId;
        if (Number.isFinite(Number(value))) itemIds.push(Number(value));
      }}
    }}
    out.itemList = Array.from(new Set(itemIds));
    out.skuCount = out.itemList.length;
    out.__fieldKeys = Object.keys(item).slice(0, 40);
    return out;
  }};
  const extractItems = (json) => {{
    const roots = [json, json && json.content, json && json.data];
    for (const root of roots) {{
      if (!root || typeof root !== 'object') continue;
      for (const key of ['dataList', 'items', 'list', 'records']) {{
        if (Array.isArray(root[key])) return {{ key, items: root[key] }};
      }}
    }}
    return {{ key: null, items: [] }};
  }};
  if (isOpenApi && location.hostname !== 'fx.huiscm.cn') {{
    return {{ ok: false, code: 'WRONG_HOST', message: 'Current page is not Huice hot goods host.', httpStatus: null }};
  }}
  if (!isOpenApi && location.hostname !== 'erp.huice.com') {{
    return {{ ok: false, code: 'WRONG_HOST', message: 'Current page is not Huice ERP.', httpStatus: null }};
  }}
  const gray = isOpenApi ? 'prod' : (localStorage.getItem('scm-gray-tag') || localStorage.getItem('scmGrayTag') || 'prod-scm-gray-v1');
  const current = localStorage.getItem('v-token') || localStorage.getItem('vToken') || '';
  if (!isOpenApi) {{
    const refreshHeaders = {{ 'content-type': 'application/json', 'scm-gray-tag': gray }};
    if (current) refreshHeaders['v-token'] = current;
    const refreshResponse = await fetch('/scmapi/api/admin/distribution/login/auth', {{
      method: 'POST', credentials: 'include', headers: refreshHeaders, body: '{{}}'
    }});
    let refresh = null;
    try {{ refresh = await refreshResponse.json(); }} catch (_) {{}}
    const renewed = refresh && refresh.content && refresh.content.token;
    if (!refreshResponse.ok || !refresh || refresh.error !== 0 || !renewed) {{
      return {{
        ok: false, code: classify(refreshResponse.status, refresh), phase: 'AUTH_REFRESH',
        httpStatus: refreshResponse.status, message: refresh && (refresh.message || refresh.msg || refresh.errorMessage),
        responseKeys: refresh ? Object.keys(refresh).filter(key => key !== 'token') : []
      }};
    }}
    localStorage.setItem('v-token', renewed);
  }}
  const token = localStorage.getItem('v-token') || localStorage.getItem('vToken') || '';
  const headers = {{ 'content-type': 'application/json', 'accept': 'application/json, text/plain, */*', 'scm-gray-tag': gray }};
  if (!isOpenApi && token) headers['v-token'] = token;
  const allItems = [];
  const pages = [];
  let lastJson = null;
  for (let page = 1; page <= Math.max(1, request.maxPages); page++) {{
    const pageBody = Object.assign({{}}, request.body || {{}});
    if (request.method === 'POST') {{
      pageBody.pageNum = page;
      pageBody.pageNo = page;
      pageBody.currentPage = page;
      pageBody.pageSize = pageBody.pageSize || request.pageSize || 20;
      pageBody.pageRows = pageBody.pageRows || request.pageSize || 20;
    }}
    const init = {{ method: request.method, credentials: 'include', headers }};
    if (request.method === 'POST') init.body = JSON.stringify(pageBody);
    const response = await fetch(request.path, init);
    const text = await response.text();
    let json = null;
    try {{ json = JSON.parse(text); }} catch (_) {{}}
    lastJson = json;
    const extracted = extractItems(json);
    const items = extracted.items || [];
    pages.push({{
      page, httpStatus: response.status, ok: response.ok, contentType: response.headers.get('content-type'),
      bodyType: json === null ? 'non-json' : (Array.isArray(json) ? 'array' : 'object'),
      responseKeys: json && typeof json === 'object' ? Object.keys(json).slice(0, 30) : [],
      contentKeys: json && json.content && typeof json.content === 'object' ? Object.keys(json.content).filter(key => key !== 'token').slice(0, 40) : [],
      arrayKey: extracted.key, itemCount: items.length,
      error: json && (json.error ?? json.code ?? json.status),
      message: json && (json.message || json.msg || json.errorMessage),
      textLength: text.length
    }});
    if (!response.ok || json === null) {{
      return {{ ok: false, code: 'HTTP_OR_JSON_FAILED', phase: 'HTTP_FETCH', path: request.path, pages, itemCount: allItems.length }};
    }}
    const businessError = json && (json.error ?? json.code);
    if (businessError !== undefined && businessError !== null && Number(businessError) !== 0) {{
      return {{ ok: false, code: classify(response.status, json), phase: 'BUSINESS_RESPONSE', path: request.path, pages, itemCount: allItems.length }};
    }}
    for (const item of items) allItems.push(summarizeItem(item));
    if (items.length === 0 || request.maxPages <= 1) break;
  }}
  return {{
    ok: true, status: 'HTTP_OK', phase: 'HTTP_CONNECTOR', path: request.path,
    method: request.method, pageCount: pages.length, itemCount: allItems.length, pages,
    items: allItems,
    responseSummary: {{
      responseKeys: lastJson && typeof lastJson === 'object' ? Object.keys(lastJson).slice(0, 30) : [],
      contentKeys: lastJson && lastJson.content && typeof lastJson.content === 'object' ? Object.keys(lastJson.content).filter(key => key !== 'token').slice(0, 40) : []
    }}
  }};
}})()
"""


def main() -> int:
    try:
        stdin_bytes = sys.stdin.buffer.read()
        stdin_text = stdin_bytes.decode("utf-8-sig", "replace") if stdin_bytes else "{}"
        envelope = json.loads(stdin_text or "{}")
        port = int(envelope["port"])
        request = envelope.get("request") or {}
        path = str(request.get("path") or "")
        desired_host = "fx.huiscm.cn" if path.startswith("/openapi/") else "erp.huice.com"
        target = _load_huice_target(port, desired_host)
        if desired_host not in str(target.get("url") or ""):
            destination = "https://fx.huiscm.cn/#/resource/findResource/hotSellPage" if desired_host == "fx.huiscm.cn" else "https://erp.huice.com/"
            _navigate(target["webSocketDebuggerUrl"], destination, int(envelope.get("timeoutSeconds") or 180))
            target = _load_huice_target(port, desired_host)
        value = _evaluate(target["webSocketDebuggerUrl"], _build_expression(request), int(envelope.get("timeoutSeconds") or 180))
        print(json.dumps({"ok": True, "value": value}, ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as exc:  # noqa: BLE001 - command boundary returns sanitized error
        print(json.dumps({"ok": False, "errorCode": type(exc).__name__, "message": str(exc)[:500]}, ensure_ascii=False, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
