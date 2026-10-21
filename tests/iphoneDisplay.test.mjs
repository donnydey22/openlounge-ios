// Unit/source checks only. These inputs are not Simulator measurements or per-model acceptance evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const app = readFileSync('App.tsx', 'utf8');
const helper = app.slice(app.indexOf('export function nativePipFrame('), app.indexOf('const finiteUnitRect'));
const js = ts.transpileModule(`const NATIVE_PIP_MARGIN = 12; const NATIVE_PIP_ASPECT = 3 / 4; ${helper}`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;
const context = { exports: {} };
vm.runInNewContext(js, context);
const frameFor = (...args) => JSON.parse(JSON.stringify(context.exports.nativePipFrame(...args)));

test('root-origin geometry uses the supplied safe top even when the WebView could report y=0', () => {
  const f = frameFor({ x: 0, y: 0, width: 375, height: 667 }, { top: 20, right: 0, bottom: 0, left: 0 }, true);
  assert.deepEqual(f, { left: 221, top: 32, width: 142, height: 189 });
});

test('synthetic resize/inset cases preserve exact safe-top and right margins without model guesses', () => {
  for (const input of [
    { width: 390, height: 844, top: 47, right: 0, bottom: 34, left: 0 },
    { width: 440, height: 956, top: 73, right: 0, bottom: 31, left: 0 },
    { width: 874, height: 402, top: 0, right: 51, bottom: 21, left: 51 },
  ]) {
    const f = frameFor({ x: 0, y: 0, width: input.width, height: input.height }, input, true);
    assert.equal(f.top, input.top + 12);
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

test('Donny fit policy renders both native video views with contain, never cover or stretch', () => {
  const fits = [...app.matchAll(/objectFit="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(fits, ['contain', 'contain']);
  assert.match(app, /big: \{ kind: big\.kind, fit: 'contain', rect: big\.rect \}/);
  assert.doesNotMatch(app, /if \(!big \|\| \(pip && pip\.fit !== 'cover'\)\)/);
});

test('uncropped native frames paint no separate dark rectangle or shadow', () => {
  assert.match(app, /nativeTile: \{ position: 'absolute', zIndex: 0, backgroundColor: 'transparent' \}/);
  const pipStyle = app.slice(app.indexOf('  nativePipFrame:'), app.indexOf('  nativeFill:'));
  assert.match(pipStyle, /backgroundColor: 'transparent'/);
  assert.doesNotMatch(pipStyle, /shadowColor|shadowOffset|shadowOpacity|shadowRadius/);
});
