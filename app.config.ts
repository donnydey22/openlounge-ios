import type { ConfigContext, ExpoConfig } from 'expo/config';

// app.json is the source of truth; this only adds opt-in pieces that change Apple-side capabilities.
//
// Universal links (https://openlounge.app/... opens the app): adds the Associated Domains entitlement, so the next
// EAS build enables that capability on the com.donnydey.openlounge App ID and regenerates its provisioning
// profiles. Turn on only once https://openlounge.app/.well-known/apple-app-site-association is live
// (see IOS_PARITY.md), by setting OPENLOUNGE_UNIVERSAL_LINKS=1 in the eas.json build profile "env".
// The custom scheme openlounge:// (used by the Google/Apple sign-in callback) needs no entitlement and is always on.
export default ({ config }: ConfigContext): ExpoConfig => {
  const universalLinks = process.env.OPENLOUNGE_UNIVERSAL_LINKS === '1';
  // Staging/test builds only (eas.json profile "staging"): point the WebView AND the native CallKit/decline API at a
  // staging origin. Production builds never set it and keep https://openlounge.app.
  const startUrl = process.env.OL_START_URL && /^https:\/\/[a-z0-9.-]+$/.test(process.env.OL_START_URL) ? process.env.OL_START_URL : null;
  return {
    ...config,
    ...(startUrl ? { extra: { ...config.extra, startUrl } } : {}),
    name: config.name ?? 'Open Lounge',
    slug: config.slug ?? 'openlounge',
    ios: {
      ...config.ios,
      ...(startUrl ? { infoPlist: { ...config.ios?.infoPlist, OLBaseURL: startUrl } } : {}),
      ...(universalLinks ? { associatedDomains: ['applinks:openlounge.app', 'applinks:www.openlounge.app'] } : {}),
    },
  };
};
