// Unit/source checks only. These inputs are not Simulator measurements or per-model acceptance evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const app = readFileSync('App.tsx', 'utf8');
const helper = app.slice(app.indexOf('export function nativePipFrame('), app.indexOf('const finiteUnitRect'));
const js = ts.transpileModule(`const NATIVE_PIP_MARGIN = 12; const NATIVE_PIP_TOP_CLEARANCE = 56; const NATIVE_PIP_ASPECT = 3 / 4; ${helper}`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;
const context = { exports: {} };
vm.runInNewContext(js, context);
const frameFor = (...args) => JSON.parse(JSON.stringify(context.exports.nativePipFrame(...args)));

test('root-origin geometry uses the supplied safe top even when the WebView could report y=0', () => {
  const f = frameFor({ x: 0, y: 0, width: 375, height: 667 }, { top: 20, right: 0, bottom: 0, left: 0 }, true);
  assert.deepEqual(f, { left: 221, top: 76, width: 142, height: 189 });
});

test('synthetic resize/inset cases preserve exact safe-top and right margins without model guesses', () => {
  for (const input of [
    { width: 390, height: 844, top: 47, right: 0, bottom: 34, left: 0 },
    { width: 440, height: 956, top: 73, right: 0, bottom: 31, left: 0 },
    { width: 874, height: 402, top: 0, right: 51, bottom: 21, left: 51 },
  ]) {
    const f = frameFor({ x: 0, y: 0, width: input.width, height: input.height }, input, true);
    assert.equal(f.top, input.top + 56);
    assert.equal(input.width - input.right - f.left - f.width, 12);
    assert.ok(f.top + f.height <= input.height - input.bottom - 12);
  }
});

test('granted full remote stage maps to the measured root rather than the padded WebView', () => {
  assert.match(app, /const fullStageRemote = nativeBigLayout\?\.kind === 'remote'/);
  assert.match(app, /nativeBigLayout\.rect\.x === 0.*nativeBigLayout\.rect\.y === 0.*nativeBigLayout\.rect\.width === 1.*nativeBigLayout\.rect\.height === 1/);
  assert.match(app, /\{ left: 0, top: 0, width: windowFrame\.width, height: windowFrame\.height \}/);
  assert.match(app, /setWindowFrame\(\{ x: 0, y: 0, width, height \}\)/);
  assert.match(app, /visibleNativeVideo \? mapTile\(nativeBigLayout\?\.rect \?\? null\)/);
});

test('existing native layer is a sibling before the unchanged padded web container', () => {
  const render = app.slice(app.indexOf('  return (', app.indexOf('  const streamFor =')), app.indexOf('export default function App'));
  assert.ok(render.indexOf('style={styles.nativeVideoLayer}') >= 0);
  assert.ok(render.indexOf('style={styles.nativeVideoLayer}') < render.indexOf('paddingTop: EDGE_TO_EDGE_TOP'));
  assert.match(render, /pointerEvents="none"/);
  assert.match(render, /visibleNativeVideo && styles\.nativeWebOverlay/);
  assert.match(app, /nativeWebOverlay: \{ zIndex: 1 \}/);
  assert.match(render, /paddingTop: EDGE_TO_EDGE_TOP \? 0 : insets\.top/);
});

test('big native video fills edge to edge (cover) with landscape-source contain fallback; PiP unchanged', () => {
  const fits = [...app.matchAll(/objectFit="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(fits, ['contain']);
  assert.match(app, /objectFit=\{bigFit\(nativeBigLayout\.kind\)\}/);
  assert.match(app, /s\.width > s\.height \* 1\.1 \? 'contain' : 'cover'/);
  assert.match(app, /big: \{ kind: big\.kind, fit: 'contain', rect: big\.rect \}/);
  assert.doesNotMatch(app, /if \(!big \|\| \(pip && pip\.fit !== 'cover'\)\)/);
});

test('uncropped native frames paint no separate dark rectangle or shadow', () => {
  assert.match(app, /nativeTile: \{ position: 'absolute', zIndex: 0, backgroundColor: 'transparent' \}/);
  const pipStyle = app.slice(app.indexOf('  nativePipFrame:'), app.indexOf('  nativeFill:'));
  assert.match(pipStyle, /backgroundColor: 'transparent'/);
  assert.doesNotMatch(pipStyle, /shadowColor|shadowOffset|shadowOpacity|shadowRadius/);
});
test('iOS wrapper removes the web self-view shadow only in native-video mode (no ghost rectangle)',async()=>{const {readFileSync}=await import('node:fs');const b=readFileSync(new URL('../src/bridge.ts',import.meta.url),'utf8');assert.match(b,/\[class\*="__nativeVideoScreen"\] \[class\*="__pip"\]\{box-shadow:none!important\}/);});
test('self-view clears the safe top by max(48, 56 pt top bar)',()=>{const a=readFileSync(new URL('../App.tsx',import.meta.url),'utf8');assert.match(a,/const NATIVE_PIP_TOP_CLEARANCE = Math\.max\(48, 56\)/);assert.match(a,/top: topBound \+ NATIVE_PIP_TOP_CLEARANCE/);});
test('hangup: self-view tile is hidden on the ended screen so no shape is drawn behind it',async()=>{const {readFileSync}=await import('node:fs');const b=readFileSync(new URL('../src/bridge.ts',import.meta.url),'utf8');assert.match(b,/\[data-testid="call-screen"\]\[data-ui="ended"\] \[class\*="__pip"\]\{visibility:hidden!important;box-shadow:none!important\}/);});
test('Speaker/Phone truth: native reports the actual output route after every override and the wrapper forwards it',async()=>{const {readFileSync}=await import('node:fs');const sw=readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift',import.meta.url),'utf8');const calls=readFileSync(new URL('../src/calls.ts',import.meta.url),'utf8');assert.match(sw,/overrideOutputAudioPort\(wantSpeaker \? \.speaker : \.none\) \}[\s\S]{0,160}reportActualRoute\(reason: "override"\)/);assert.match(sw,/"speaker": out\?\.portType == \.builtInSpeaker, "kind": kind/);assert.match(sw,/emit\(routePayload\(reason: 0, source: reason\)\)/);assert.match(calls,/a\.type === 'audioRoute'\) return \{ type: 'audioRoute', \.\.\.sanitizeAudioRoute\(a\) \}/);assert.match(calls,/speaker: a\.speaker === true/);assert.match(app,/JSON\.stringify\(sanitizeAudioRoute\(a/);});

test('route picker (Oct 23): native lists outputs + kind, honours an explicit pick until a device change, wrapper passes route/deviceId',async()=>{const {readFileSync}=await import('node:fs');const sw=readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift',import.meta.url),'utf8');const bridge=readFileSync(new URL('../src/bridge.ts',import.meta.url),'utf8');
assert.match(sw,/self\.userRoute = nil\n\s+if self\.savedAudio != nil/);
assert.match(sw,/case "speaker":[\s\S]{0,200}overrideOutputAudioPort\(\.speaker\)/);
assert.match(sw,/case "earpiece":[\s\S]{0,160}setPreferredInput\(builtIn\)/);
assert.match(sw,/if let pick = userRoute \{ applyUserRoute\(pick\); return \}/);
assert.match(sw,/"routes": routes/);
assert.match(bridge,/route: m\.route/);assert.match(bridge,/deviceId: m\.deviceId/);});
