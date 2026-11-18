// Run: node --test tests/*.test.js
// Browsers without a service worker (Bluefy on the iPad) only load new scripts and styles when the
// ?v= in index.html changes, so it must always match APP_VERSION (and the Mac app's version).
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

test('index.html asset versions match APP_VERSION and Info.plist', () => {
  const appVersion = read('docs/app.js').match(/const APP_VERSION = '([^']+)'/)[1];
  const html = read('docs/index.html');
  const local = [...html.matchAll(/(?:src|href)="(?!https?:)([^"#]+\.(?:js|css)[^"]*)"/g)].map((m) => m[1]);
  assert.ok(local.length > 0, 'no local scripts or stylesheets found');
  for (const url of local) {
    assert.ok(url.endsWith(`?v=${appVersion}`), `${url} should end with ?v=${appVersion}`);
  }
  const plist = read('mac-helper/Info.plist').match(/CFBundleShortVersionString<\/key>\s*<string>([^<]+)</)[1];
  assert.strictEqual(plist, appVersion, 'Info.plist version should match APP_VERSION');
});
