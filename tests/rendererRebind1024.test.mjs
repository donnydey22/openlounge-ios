// FX-077 must-pass: whenever Keiko's video is replaced (new producer/consumer), the native renderer re-binds.
import test from 'node:test'; import assert from 'node:assert/strict'; import fs from 'node:fs';
const app = fs.readFileSync(new URL('../App.tsx', import.meta.url), 'utf8');
const nm = fs.readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
test('remote RTCView is keyed on its stream URL (remounts on replacement)', () => {
  assert.match(app, /<RTCView key=\{`big-\$\{nativeBigLayout\.kind\}-\$\{streamFor\(nativeBigLayout\.kind\)!\.toURL\(\)\}`\} streamURL=\{streamFor\(nativeBigLayout\.kind\)!\.toURL\(\)\}/);
});
test('replacement builds a new stream, closes the old consumer, and emits state', () => {
  const i = nm.indexOf('this.remoteVideo = new MediaStream([c.track]);');
  assert.ok(i > 0);
  const before = nm.slice(nm.indexOf("if (c.kind === 'video' && this.nativeVideo)"), i);
  assert.match(before, /prior\.close\(\); this\.consumers\.delete\(id\);/);
  assert.match(nm.slice(i, i + 600), /'remote-video-replaced'/);
  assert.match(nm, /this\.emitVideoState\(\);\n\s*\/\/ The WebView cannot inspect/);
});
