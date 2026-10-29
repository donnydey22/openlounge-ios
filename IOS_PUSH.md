# iOS push, contacts & share — prepared, not built (0.2.5 / build 7)

## What's in place
- `@react-native-firebase/app` + `/messaging` (FCM token; server sends via FCM HTTP v1 with an APNs alert payload,
  `apns-collapse-id` per DM thread / room), `expo-notifications` (foreground presentation, clearing delivered
  notifications when a DM is read elsewhere), `expo-contacts`, `expo-localization`.
- `GoogleService-Info.plist` (project open-lounge-2aabd, bundle com.donnydey.openlounge) → `ios.googleServicesFile`.
- Entitlement `aps-environment: production`; `UIBackgroundModes: audio, remote-notification`;
  `expo-build-properties` `ios.useFrameworks: "static"` (required by react-native-firebase).
- `NSContactsUsageDescription` + privacy manifest entry (Contacts, linked, not tracking, app functionality).
- Bridge (`src/bridge.ts`, `App.tsx`): `OpenLoungeNative.getPlatform() → "ios"`, `getPushToken()`, `share(text,url)` (RN Share sheet),
  `requestContacts()` → `window.__olContacts(json)`, `openAppSettings()`, `requestNotificationPermission()` (prompt + token →
  `window.__olPushToken(token)`; token refresh re-delivered). Notification tap → `data.url` opened in the WebView.
- Already present: haptics bridge, `bounces={false}`, `allowsBackForwardNavigationGestures`, splash until web ready.

## Still needed before an EAS build
1. **APNs auth key** (.p8) from Apple Developer → Keys (Apple Push Notifications service), uploaded in Firebase Console →
   Project settings → Cloud Messaging → Apple app configuration (Key ID + Team ID). Without it FCM can't deliver to iOS.
2. Push Notifications capability on the App ID (EAS does this from the entitlement on the next build; regenerates profiles).
3. `eas build -p ios --profile preview` (not run). Then test on a real device (the iOS simulator can't receive APNs pushes from FCM reliably).
