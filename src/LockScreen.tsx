// Privacy / app-lock overlay over the WebView (#0b0b0d, 🎙️ Open Lounge wordmark). Shown while locked and, when the
// lock is on, whenever the app is inactive/backgrounded so the app-switcher snapshot never shows the page.
import { Pressable, StyleSheet, Text, View } from 'react-native';

export function LockScreen({
  showActions,
  failed,
  onRetry,
  onOtherWay,
}: {
  showActions: boolean;
  failed: boolean;
  onRetry: () => void;
  onOtherWay: () => void;
}) {
  return (
    <View style={[StyleSheet.absoluteFill, s.c]} accessibilityViewIsModal>
      <Text style={s.word}>🎙️ Open Lounge</Text>
      <Text style={s.msg}>{failed ? 'Couldn’t verify it’s you. Try again or use your passcode.' : 'Open Lounge is locked'}</Text>
      {showActions && (
        <View style={s.actions}>
          <Pressable accessibilityRole="button" onPress={onRetry} style={s.btn}>
            <Text style={s.btnText}>Unlock</Text>
          </Pressable>
          <Pressable accessibilityRole="button" onPress={onOtherWay} style={s.link}>
            <Text style={s.linkText}>Use another way</Text>
          </Pressable>
        </View>
      )}
    </View>
  );
}

const s = StyleSheet.create({
  c: { backgroundColor: '#0b0b0d', alignItems: 'center', justifyContent: 'center', padding: 28 },
  word: { color: '#f4f4f5', fontSize: 30, fontWeight: '700', letterSpacing: -0.75 },
  msg: { color: '#a1a1a6', fontSize: 15, marginTop: 12, textAlign: 'center' },
  actions: { marginTop: 28, alignItems: 'center' },
  btn: { backgroundColor: '#F2B366', borderRadius: 22, paddingHorizontal: 28, paddingVertical: 12 },
  btnText: { color: '#1C1C1E', fontSize: 16, fontWeight: '600' },
  link: { marginTop: 10, padding: 10 },
  linkText: { color: '#F2B366', fontSize: 15 },
});
