// Launch safety: only call FirebaseApp.configure() when GoogleService-Info.plist is actually bundled and Firebase
// isn't configured yet. A missing plist makes FirebaseApp.configure() raise an NSException at launch (instant crash).
const { withAppDelegate } = require('expo/config-plugins');
const SAFE =
  'if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil && FirebaseApp.app() == nil { FirebaseApp.configure() } // withSafeFirebaseConfigure';
module.exports = (config) =>
  withAppDelegate(config, (c) => {
    let src = c.modResults.contents;
    if (c.modResults.language !== 'swift' || src.includes('withSafeFirebaseConfigure')) return c;
    src = src.replace(/^(\s*)FirebaseApp\.configure\(\)\s*$/m, (_m, ws) => ws + SAFE);
    c.modResults.contents = src;
    return c;
  });
