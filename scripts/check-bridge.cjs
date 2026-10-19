// Offline unit checks for the URL policy, deep-link mapping and bridge message parsing (no device needed).
//   node scripts/check-bridge.cjs
const path = require('path');
const fs = require('fs');
const Module = require('module');
const assert = require('assert');
const ts = require('typescript');

const root = path.resolve(__dirname, '..');
// Stub expo-constants (native module) with the app.json values the code reads.
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (req, ...rest) {
  if (req === 'expo-constants') return 'expo-constants-stub';
  return origResolve.call(this, req, ...rest);
};
require.cache['expo-constants-stub'] = {
  id: 'expo-constants-stub', filename: 'expo-constants-stub', loaded: true,
  exports: { default: { expoConfig: { version: '0.2.3', extra: { startUrl: 'https://openlounge.app' } } } },
};
require.extensions['.ts'] = (m, filename) => {
  const out = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
  }).outputText;
  m._compile(out, filename);
};

const { isAppUrl } = require(path.join(root, 'src/config.ts'));
const L = require(path.join(root, 'src/links.ts'));
const B = require(path.join(root, 'src/bridge.ts'));
const { isSafeAppPath } = require(path.join(root, 'src/url.ts'));

let failed = 0;
const t = (a, b, m) => {
  try { assert.deepStrictEqual(a, b); } catch { failed++; console.log('FAIL', m, JSON.stringify(a), '!=', JSON.stringify(b)); }
};
t(isAppUrl('https://openlounge.app/'), true, 'app');
t(isAppUrl('https://openlounge.app'), true, 'app no slash');
t(isAppUrl('https://evil.example?@openlounge.app/'), false, 'RN URL shim userinfo trick');
t(isAppUrl('https://openlounge.app.evil.com/'), false, 'suffix');
t(isAppUrl('https://openlounge.app@evil.com/'), false, 'userinfo');
t(isAppUrl('https://openlounge.app\\@evil.com/'), false, 'backslash');
t(isAppUrl('http://openlounge.app/'), false, 'http');
t(isAppUrl('https://openlounge.app:8443/'), false, 'port');
t(isAppUrl('https://WWW.OpenLounge.app/room/1'), true, 'case');
t(isAppUrl('https://openlounge-production.up.railway.app/x'), true, 'railway');
t(L.resolveIncomingLink('openlounge://auth?code=abc_123-x.y~z'), { url: 'https://openlounge.app/auth/complete?code=abc_123-x.y~z', kind: 'auth', code: 'abc_123-x.y~z' }, 'scheme auth');
t(L.resolveIncomingLink('openlounge://auth/exchange?code=abc', 'https://openlounge-production.up.railway.app/x'), { url: 'https://openlounge-production.up.railway.app/auth/complete?code=abc', kind: 'auth', code: 'abc' }, 'origin follows page');
t(L.resolveIncomingLink('openlounge://auth?error=cancelled'), { url: 'https://openlounge.app/auth/complete?error=cancelled', kind: 'auth', code: undefined }, 'error');
t(L.resolveIncomingLink('openlounge://auth?error=<script>'), { url: 'https://openlounge.app/auth/complete?error=failed', kind: 'auth', code: undefined }, 'bad error');
t(L.resolveIncomingLink('openlounge://auth?code=a%22b'), null, 'bad code');
t(L.resolveIncomingLink('https://openlounge.app/auth/exchange?code=XYZ'), { url: 'https://openlounge.app/auth/complete?code=XYZ', kind: 'auth', code: 'XYZ' }, 'https exchange');
t(L.resolveIncomingLink('openlounge://room/abc?x=1'), { url: 'https://openlounge.app/room/abc?x=1', kind: 'page' }, 'room');
t(L.resolveIncomingLink('openlounge:///room/abc'), { url: 'https://openlounge.app/room/abc', kind: 'page' }, 'triple slash');
t(L.resolveIncomingLink('openlounge://room/../../x'), { url: 'https://openlounge.app/', kind: 'page' }, 'traversal');
t(L.resolveIncomingLink('https://evil.com/auth/exchange?code=x'), null, 'foreign https');
t(L.isNativeAuthStart('https://openlounge.app/auth/google/start?app=1&cc=abc'), true, 'google start');
t(L.isNativeAuthStart('https://openlounge.app/auth/apple/start?cc=abc&app=1&intent=x'), true, 'apple link start');
t(L.isNativeAuthStart('https://openlounge.app/auth/google/start'), false, 'web start');
t(L.isNativeAuthStart('https://accounts.google.com/auth/google/start?app=1'), false, 'idp host');
t(isSafeAppPath('//evil.com'), false, 'protocol-relative');
t(B.parseBridgeMessage('{"__ol":1,"method":"haptic","value":"raiseHand"}'), { __ol: 1, method: 'haptic', value: 'raiseHand' }, 'haptic');
t(B.parseBridgeMessage('{"__ol":1,"method":"haptic","value":"boom"}'), null, 'unknown haptic');
t(B.parseBridgeMessage('{"__ol":1,"method":"ready"}'), { __ol: 1, method: 'ready' }, 'ready');
t(B.parseBridgeMessage('{"__ol":1,"method":"setSession"}'), null, 'setSession without id');
t(B.parseBridgeMessage('{"__ol":1,"id":"a","method":"bioSetEnabled","value":true}'), { __ol: 1, id: 'a', method: 'bioSetEnabled', value: true }, 'bio set');
t(B.parseBridgeMessage('{"__ol":1,"id":"a","method":"bioSetEnabled","value":"yes"}'), null, 'bio set non-bool');
t(B.parseBridgeMessage('{"__ol":1,"id":"a","method":"bioGetEnabled"}'), { __ol: 1, id: 'a', method: 'bioGetEnabled' }, 'bio get');
t(B.parseBridgeMessage('{"__ol":1,"method":"requestContacts"}'), { __ol: 1, method: 'requestContacts' }, 'requestContacts (not swallowed by setBadge)');
t(B.parseBridgeMessage('{"__ol":1,"method":"openAppSettings"}'), { __ol: 1, method: 'openAppSettings' }, 'openAppSettings');
t(B.parseBridgeMessage('{"__ol":1,"method":"setBadge","value":3.7}'), { __ol: 1, method: 'setBadge', value: 3 }, 'setBadge');
t(B.parseBridgeMessage('{"__ol":1,"method":"setBadge","value":-1}'), null, 'setBadge negative');
t(B.parseBridgeMessage('{"type":"call:outgoing","callId":"c_1","name":"Ann","video":true}'), { __ol: 1, method: 'call', value: { type: 'call:outgoing', callId: 'c_1', name: 'Ann', video: true } }, 'call outgoing');
t(B.parseBridgeMessage('{"type":"call:connected","callId":"c_1"}'), { __ol: 1, method: 'call', value: { type: 'call:connected', callId: 'c_1' } }, 'call connected');
t(B.parseBridgeMessage('{"type":"call:ended"}'), { __ol: 1, method: 'call', value: { type: 'call:ended', callId: '' } }, 'call ended no id');
t(B.parseBridgeMessage('{"type":"call:ended","callId":"../x"}'), null, 'call ended bad id');
t(B.parseBridgeMessage('{"type":"call:muted","muted":true}'), { __ol: 1, method: 'call', value: { type: 'call:muted', muted: true } }, 'call muted');
t(B.parseBridgeMessage('{"type":"call:audioRoute","speaker":false}'), { __ol: 1, method: 'call', value: { type: 'call:audioRoute', speaker: false } }, 'audio route');
t(B.parseBridgeMessage('{"type":"call:audioRoute","speaker":"no"}'), null, 'audio route non-bool');
t(B.parseBridgeMessage('{"type":"call:explode"}'), null, 'unknown call type');
t(B.parseBridgeMessage('{"__ol":1,"type":"call:ended"}'), null, 'enveloped call msg ignored');
{
  const js = B.injectedBeforeContentLoaded('ios', '0.3.1', true);
  t(/__olNativeCalls = 1/.test(js) && /if \(true\)/.test(js) && /'calls'\]/.test(js), true, 'native calls flag on');
  const off = B.injectedBeforeContentLoaded('ios', '0.3.1');
  t(/if \(false\)/.test(off) && !/'calls'\]/.test(off), true, 'native calls flag off by default');
}
{
  const { shouldLock } = require(path.join(root, 'src/lockPolicy.ts'));
  t(shouldLock(false, 0, 1e6), false, 'lock off');
  t(shouldLock(true, 0, 5), true, 'cold start locks');
  t(shouldLock(true, 1000, 61000), false, '60s exactly no lock');
  t(shouldLock(true, 1000, 61001), true, '>60s locks');
}
for (const js of [B.injectedBeforeContentLoaded('ios', '0.2.3'), B.injectedBeforeContentLoaded('ios', '0.3.1', true), B.audioResumeScript('x'), B.keyboardScript(true, 300, 250), B.nativeEventScript('a', { b: 1 })]) {
  new Function(js); // syntax check
}
console.log(failed ? `${failed} FAILED` : 'bridge/link checks: all OK');
process.exit(failed ? 1 : 0);
// ring: CallKit audio activation must re-arm the page ring (AudioContext + <audio> loop)
{
  const fs = require('fs');
  t(/__olRingResume/.test(B.audioResumeScript('callkit-activate')), true, 'audio resume re-arms the page ring');
  t(/emit\(\["type": "audio"/.test(fs.readFileSync(path.join(root, 'modules/openlounge-calls/ios/OLCallManager.swift'), 'utf8')), true, 'CallKit didActivate tells JS');
  t(/a\.type === 'audio'[\s\S]{0,120}audioResumeScript/.test(fs.readFileSync(path.join(root, 'App.tsx'), 'utf8')), true, 'App injects resume on CallKit audio');
}
