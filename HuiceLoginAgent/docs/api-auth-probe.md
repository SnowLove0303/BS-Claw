# Read-only API probe

The current probe follows the fixed `huice-goods-analysis/src/huice-client.js` contract and calls:

`POST /scmapi/api/admin/distributor/statistics/goods/overview`

with supplier role `2`, the verified default range from seven days ago through yesterday, and an empty `nickNoList`. It requires `error == 0` plus the verified overview fields. HTTP errors, business errors, missing authentication material and network failures are distinct safe outcomes.

Authentication first uses a current page `v-token` when present. For tenants that expose only the authenticated `X-HC-TOKEN` browser session, the same-origin refresh is allowed to continue via `credentials: include`; the returned credential is written to the ERP page's local storage before the probe. No token or cookie value leaves the page context.
