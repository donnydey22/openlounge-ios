// FX-076 (was FX-065; renumbered to avoid the web registry id) must-pass: the build in the UA / call logs is the real CFBundleVersion, not app.json's static buildNumber.
import test from 'node:test'; import assert from 'node:assert/strict'; import fs from 'node:fs';
test('APP_BUILD prefers expo-application nativeBuildVersion', () => {
  const s = fs.readFileSync(new URL('../src/config.ts', import.meta.url), 'utf8');
  assert.match(s, /import \* as Application from 'expo-application'/);
  assert.match(s, /APP_BUILD =\s*\n\s*Application\.nativeBuildVersion \?\?/);
  const pkg = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.ok(pkg.dependencies['expo-application'], 'expo-application must be a direct (autolinked) dependency');
});
