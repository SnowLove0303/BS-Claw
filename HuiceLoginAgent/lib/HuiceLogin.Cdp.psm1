Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HuiceLogin.Adapter.psm1') -Force
function Get-CdpJson([string]$Uri){try{(Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 $Uri).Content|ConvertFrom-Json}catch{$null}}
function Get-HuicePageTarget($Resource){
  $b="http://127.0.0.1:$($Resource.port)"
  $pages=Get-CdpJson "$b/json/list"
  $p=$null
  foreach($candidate in $pages){
    if([string]$candidate.type -eq 'page' -and ([Uri]$candidate.url).Host -eq 'erp.huice.com'){ $p=$candidate;break }
  }
  foreach($candidate in $pages){
    if($null -ne $p){break}
    if([string]$candidate.type -eq 'page' -and (Test-HuicePage $candidate)){ $p=$candidate;break }
  }
  if($null -eq $p){throw 'Huice page not found'}
  return $p
}
function New-HuicePageTarget($Resource,[string]$Url='https://login.huice.com/'){
  $b="http://127.0.0.1:$($Resource.port)"
  $encoded=[Uri]::EscapeDataString($Url)
  try {
    $created=(Invoke-WebRequest -UseBasicParsing -Method Put -TimeoutSec 10 "$b/json/new?$encoded").Content|ConvertFrom-Json
  }
  catch {
    $ex=[InvalidOperationException]::new('Unable to create Huice page through CDP')
    $ex.Data['errorCode']='HUICE_PAGE_CREATE_FAILED'
    throw $ex
  }
  if($null -eq $created -or [string]::IsNullOrWhiteSpace([string]$created.webSocketDebuggerUrl)){
    $ex=[InvalidOperationException]::new('CDP did not return a usable Huice page')
    $ex.Data['errorCode']='HUICE_PAGE_CREATE_FAILED'
    throw $ex
  }
  return $created
}
function Open-HuiceTarget($Resource){
  try{$p=Get-HuicePageTarget $Resource}catch{$p=New-HuicePageTarget $Resource}
  if($p.id){$b="http://127.0.0.1:$($Resource.port)";Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$b/json/activate/$($p.id)"|Out-Null}
  $p
}
function Open-HuiceLoginPage($Resource){
  $created=$false
  try{$page=Get-HuicePageTarget $Resource}catch{$page=New-HuicePageTarget $Resource;$created=$true}
  if(-not $created){$null=Invoke-CdpEvaluate ([string]$page.webSocketDebuggerUrl) "location.assign('https://login.huice.com/');true"}
  if($page.id){$b="http://127.0.0.1:$($Resource.port)";Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$b/json/activate/$($page.id)"|Out-Null}
}
function Open-HuiceErpProduct($Resource){
  $page=Get-HuicePageTarget $Resource
  $expression=@'
(()=>{
  if(location.hostname!=='login.huice.com'||!location.hash.startsWith('#/product_map'))return {clicked:false,status:'wrong-page'};
  const label=[...document.querySelectorAll('*')].find(e=>(e.innerText||e.textContent||'').trim()==='旺店通ERP3.0');
  if(!label)return {clicked:false,status:'erp-product-not-found'};
  const target=label.closest('.grid-content')||label;
  target.click();
  return {clicked:true,status:'erp-product-selected'};
})()
'@
  return Invoke-CdpEvaluate ([string]$page.webSocketDebuggerUrl) $expression
}
function Invoke-CdpEvaluate { param([string]$WebSocketUrl,[string]$Expression)
  $node='E:\MorenAnzhuangLujing\Huangjingdajian\Nodejs\node.exe'
  if(-not (Test-Path -LiteralPath $node -PathType Leaf)){throw 'F/E drive Node runtime unavailable'}
  $request=@{webSocketUrl=$WebSocketUrl;expression=$Expression}|ConvertTo-Json -Compress
  $request64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
  $output=& $node (Join-Path $PSScriptRoot 'cdp_evaluate.js') $request64 2>&1
  $text=($output -join [Environment]::NewLine).Trim()
  if([string]::IsNullOrWhiteSpace($text)){throw 'CDP bridge returned no result'}
  $result=$text|ConvertFrom-Json
  if($LASTEXITCODE -ne 0 -or -not [bool]$result.ok){
    $code=if($result.PSObject.Properties.Name -contains 'errorCode' -and -not [string]::IsNullOrWhiteSpace([string]$result.errorCode)){[string]$result.errorCode}else{'CDP_BRIDGE_FAILED'}
    $ex=[InvalidOperationException]::new($code)
    $ex.Data['errorCode']=$code
    throw $ex
  }
  return $result.value
}
function Invoke-HuiceAuthRefreshAndProbe($Page){
  $expr=@'
(async()=>{
  const classify=(http,json)=>{
    const code=Number(json&&json.error);
    const text=String((json&&(json.message||json.msg||json.errorMessage))||'').toLowerCase();
    if(http===401||code===401||text.includes('invalid token')||text.includes('token invalid')||text.includes('token失效'))return {status:'session-expired',errorCode:http===401||code===401?'HTTP_401':'INVALID_TOKEN'};
    if(http===403||code===403)return {status:'permission-denied',errorCode:'HTTP_403'};
    if(text.includes('权限不足')||text.includes('无权限')||text.includes('permission denied'))return {status:'permission-denied',errorCode:'PERMISSION_DENIED'};
    return {status:'business-error',errorCode:'BUSINESS_ERROR'};
  };
  if(location.hostname!=='erp.huice.com')return {status:'wrong-host',errorCode:'WRONG_HOST'};
  const current=localStorage.getItem('v-token')||localStorage.getItem('vToken')||'';
  const gray=localStorage.getItem('scm-gray-tag')||localStorage.getItem('scmGrayTag')||'prod-scm-gray-v1';
  const cookieSession=document.cookie.split(';').some(part=>part.trim().startsWith('X-HC-TOKEN='));
  if(!current&&!cookieSession)return {status:'session-expired',errorCode:'AUTH_MATERIAL_MISSING',authMaterialPresent:false,grayTagPresent:!!gray};
  let refreshResponse,refresh;
  try{
    const refreshHeaders={'content-type':'application/json','scm-gray-tag':gray};
    if(current)refreshHeaders['v-token']=current;
    refreshResponse=await fetch('/scmapi/api/admin/distribution/login/auth',{method:'POST',credentials:'include',headers:refreshHeaders,body:'{}'});
    try{refresh=await refreshResponse.json()}catch(_){return {status:'refresh-failed',errorCode:'REFRESH_BAD_JSON',refreshHttpStatus:refreshResponse.status,authMaterialPresent:!!(current||cookieSession),grayTagPresent:!!gray}}
  }catch(_){return {status:'refresh-failed',errorCode:'NETWORK_FAILURE',authMaterialPresent:!!(current||cookieSession),grayTagPresent:!!gray}}
  const renewed=refresh&&refresh.content&&refresh.content.token;
  if(!refreshResponse.ok||!refresh||refresh.error!==0||!renewed){
    const c=classify(refreshResponse.status,refresh);
    return {status:c.status,errorCode:c.errorCode,refreshHttpStatus:refreshResponse.status,authMaterialPresent:!!(current||cookieSession),grayTagPresent:!!gray};
  }
  localStorage.setItem('v-token',renewed);
  let probeResponse,probe;
  try{
    const formatDate=date=>`${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
    const today=new Date();
    const endDate=new Date(today.getFullYear(),today.getMonth(),today.getDate()-1);
    const startDate=new Date(today.getFullYear(),today.getMonth(),today.getDate()-7);
    const overviewPayload={role:2,startDate:formatDate(startDate),endDate:formatDate(endDate),nickNoList:[]};
    probeResponse=await fetch('/scmapi/api/admin/distributor/statistics/goods/overview',{method:'POST',credentials:'include',headers:{'content-type':'application/json','v-token':renewed,'scm-gray-tag':gray},body:JSON.stringify(overviewPayload)});
    try{probe=await probeResponse.json()}catch(_){return {status:'probe-failed',errorCode:'PROBE_BAD_JSON',refreshHttpStatus:refreshResponse.status,probeHttpStatus:probeResponse.status,authMaterialPresent:true,grayTagPresent:!!gray}}
  }catch(_){return {status:'probe-failed',errorCode:'NETWORK_FAILURE',refreshHttpStatus:refreshResponse.status,authMaterialPresent:true,grayTagPresent:!!gray}}
  if(!probeResponse.ok||!probe||probe.error!==0){
    const c=classify(probeResponse.status,probe);
    return {status:c.status,errorCode:c.errorCode,refreshHttpStatus:refreshResponse.status,probeHttpStatus:probeResponse.status,authMaterialPresent:true,grayTagPresent:!!gray};
  }
  const requiredFields=['activeGoodsCount','supplierGoodsCount','distributionGoodsCount','activeGoodsMom'];
  const required=probe.content!==null&&typeof probe.content==='object'&&!Array.isArray(probe.content)&&requiredFields.every(key=>Object.prototype.hasOwnProperty.call(probe.content,key));
  if(!required)return {status:'probe-failed',errorCode:'MISSING_REQUIRED_FIELDS',refreshHttpStatus:refreshResponse.status,probeHttpStatus:probeResponse.status,authMaterialPresent:true,grayTagPresent:!!gray,requiredProbeFieldsPresent:false};
  return {status:'logged-in-api-ready',errorCode:null,refreshHttpStatus:refreshResponse.status,probeHttpStatus:probeResponse.status,authMaterialPresent:true,grayTagPresent:!!gray,requiredProbeFieldsPresent:true};
})()
'@
  $raw=Invoke-CdpEvaluate ([string]$Page.webSocketDebuggerUrl) $expr;if($raw -is [string]){$raw|ConvertFrom-Json}else{$raw}
}
function Invoke-HuiceChallengeContinuation($Resource) {
  $page=Get-HuicePageTarget $Resource
  $expr=@'
(()=>{
  if(location.hostname!=='login.huice.com')return {clicked:false,status:'not-login-page'};
  const visible=e=>!!(e&&e.getClientRects().length&&!e.disabled);
  const codeInputs=[...document.querySelectorAll('#phone-verify-code,input[placeholder*="验证码"]')].filter(visible);
  const completed=codeInputs.some(e=>String(e.value||'').trim().length>=4);
  if(!completed)return {clicked:false,status:'verification-input-incomplete'};
  const dialogs=[...document.querySelectorAll('.el-dialog')].filter(visible);
  const scope=dialogs.length?dialogs[dialogs.length-1]:document;
  const button=[...scope.querySelectorAll('button')].find(e=>visible(e)&&['确定','确认','登录'].includes(String(e.innerText||'').replace(/\s/g,'')));
  if(!button)return {clicked:false,status:'continue-button-not-found'};
  button.click();
  return {clicked:true,status:'security-verification-submitted'};
})()
'@
  return Invoke-CdpEvaluate ([string]$page.webSocketDebuggerUrl) $expr
}
function Get-HuiceLoginPageOutcome($Resource) {
  $page=Get-HuicePageTarget $Resource
  $expr=@'
(()=>{
  if(location.hostname!=='login.huice.com')return {status:'page-transitioned',errorCode:null,pageHost:location.hostname,pagePath:location.pathname};
  const visible=e=>!!(e&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden');
  const text=[...document.querySelectorAll('.el-message,.el-message-box,.el-dialog,.login-error,[role="alert"]')]
    .filter(visible).map(e=>String(e.innerText||'').replace(/\s+/g,' ').trim()).join(' ');
  const body=String(document.body&&document.body.innerText||'');
  const combined=(text+' '+body).slice(0,12000);
  const challenge=(code,type)=>({status:'security-verification-required',errorCode:code,challengeType:type,pageHost:location.hostname,pagePath:location.pathname});
  if(/滑块|拖动.*验证|向右滑动/.test(combined))return challenge('SLIDER_VERIFICATION_REQUIRED','slider');
  if(/短信验证码|手机验证码/.test(combined))return challenge('SMS_VERIFICATION_REQUIRED','sms');
  if(/图形验证码|请输入验证码/.test(combined)&&document.querySelector('input[placeholder*="验证码"]'))return challenge('IMAGE_CAPTCHA_REQUIRED','image-captcha');
  if(/扫码|二维码/.test(combined)&&document.querySelector('canvas,img[src*="qr"],[class*="qrcode"]'))return challenge('QR_VERIFICATION_REQUIRED','qr');
  if(/账号或密码错误|用户名或密码|密码不正确|账号不存在|卖家账号.*错误/.test(text))return {status:'login-failed',errorCode:'INVALID_CREDENTIALS',pageHost:location.hostname,pagePath:location.pathname};
  if(/网络异常|请求失败|服务繁忙|稍后重试/.test(text))return {status:'login-failed',errorCode:'LOGIN_NETWORK_OR_SERVICE_ERROR',pageHost:location.hostname,pagePath:location.pathname};
  const fields=[...document.querySelectorAll('input')].filter(visible);
  return {status:'login-submission-pending',errorCode:null,pageHost:location.hostname,pagePath:location.pathname,visibleInputCount:fields.length};
})()
'@
  $raw=Invoke-CdpEvaluate ([string]$page.webSocketDebuggerUrl) $expr
  if($raw -is [string]){$raw|ConvertFrom-Json}else{$raw}
}
function Get-HuiceLiveEvidence($Resource){$base="http://127.0.0.1:$($Resource.port)";$v=Get-CdpJson "$base/json/version";if($null -eq $v){return [pscustomobject]@{status='port-unavailable';evidenceType='cdp-unavailable';summary='CDP unavailable';checkedAt=[DateTimeOffset]::Now.ToString('o')}};try{$p=Get-HuicePageTarget $Resource}catch{return [pscustomobject]@{status='login-required';evidenceType='live-cdp-no-page';summary='Huice page is not open';checkedAt=[DateTimeOffset]::Now.ToString('o');browserPid=$Resource.browserPid;port=$Resource.port;profile=$Resource.resolvedProfile}};$uri=[Uri]$p.url;$s=if($uri.Host -eq 'login.huice.com' -and $uri.Fragment.StartsWith('#/product_map')){'product-selection'}elseif(Test-HuiceLoginPage $p){'login-required'}else{'platform-page'};[pscustomobject]@{status=$s;evidenceType='live-cdp-page';summary='live page checked';pageUrl=$uri.GetLeftPart([UriPartial]::Path);pageTitle=([string]$p.title).Substring(0,[Math]::Min(160,([string]$p.title).Length));checkedAt=[DateTimeOffset]::Now.ToString('o');browserPid=$Resource.browserPid;port=$Resource.port;profile=$Resource.resolvedProfile}}
Export-ModuleMember -Function Get-CdpJson,Get-HuicePageTarget,New-HuicePageTarget,Open-HuiceTarget,Open-HuiceLoginPage,Open-HuiceErpProduct,Invoke-CdpEvaluate,Invoke-HuiceAuthRefreshAndProbe,Invoke-HuiceChallengeContinuation,Get-HuiceLoginPageOutcome,Get-HuiceLiveEvidence
