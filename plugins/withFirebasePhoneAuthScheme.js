// Firebase iOS phone auth reCAPTCHA fallback: the SDK returns from SFSafariViewController via a URL scheme.
// GoogleService-Info.plist has no REVERSED_CLIENT_ID (no OAuth client), so Firebase uses the encoded app ID:
// GOOGLE_APP_ID "1:166652417209:ios:8c637d5cdac453bc9c3768" → "app-1-166652417209-ios-8c637d5cdac453bc9c3768".
// If a REVERSED_CLIENT_ID is ever added to the plist, it is registered too.
const fs = require('fs');
const path = require('path');
const { withInfoPlist } = require('expo/config-plugins');

function readKey(plist, key) {
  const m = plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`));
  return m ? m[1].trim() : null;
}

module.exports = (config) =>
  withInfoPlist(config, (c) => {
    const file = path.resolve(c.modRequest.projectRoot, config.ios?.googleServicesFile ?? './GoogleService-Info.plist');
    const plist = fs.readFileSync(file, 'utf8');
    const schemes = [];
    const appId = readKey(plist, 'GOOGLE_APP_ID');
    if (appId) schemes.push('app-' + appId.replace(/:/g, '-'));
    const reversed = readKey(plist, 'REVERSED_CLIENT_ID');
    if (reversed) schemes.push(reversed);
    const types = (c.modResults.CFBundleURLTypes = c.modResults.CFBundleURLTypes ?? []);
    for (const s of schemes) {
      if (!types.some((t) => (t.CFBundleURLSchemes ?? []).includes(s))) types.push({ CFBundleURLSchemes: [s] });
    }
    return c;
  });
