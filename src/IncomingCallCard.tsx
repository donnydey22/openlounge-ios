// Fallback incoming-call card shown ABOVE the App Lock overlay when CallKit did not take the call
// (e.g. page got call:incoming over WS while locked and VoIP push is delayed).
import { Pressable, StyleSheet, Text, View } from 'react-native';

export function IncomingCallCard({
  name,
  video,
  onAccept,
  onDecline,
}: {
  name: string;
  video: boolean;
  onAccept: () => void;
  onDecline: () => void;
}) {
  return (
    <View style={s.wrap} pointerEvents="box-none" testID="incoming-call-card">
      <View style={s.card}>
        <Text style={s.kicker}>{video ? 'Open Lounge video call' : 'Open Lounge audio call'}</Text>
        <Text style={s.name} numberOfLines={2}>
          {name || 'Incoming call'}
        </Text>
        <View style={s.row}>
          <Pressable onPress={onDecline} style={[s.btn, s.decline]} accessibilityLabel="Decline">
            <Text style={s.btnText}>Decline</Text>
          </Pressable>
          <Pressable onPress={onAccept} style={[s.btn, s.accept]} accessibilityLabel="Accept">
            <Text style={s.btnText}>Accept</Text>
          </Pressable>
        </View>
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: {
    position: "absolute", top: 0, left: 0, right: 0, bottom: 0,
    justifyContent: 'flex-end',
    padding: 20,
    paddingBottom: 48,
    backgroundColor: 'rgba(0,0,0,0.45)',
    zIndex: 100,
  },
  card: {
    backgroundColor: '#1c1c1e',
    borderRadius: 24,
    padding: 22,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.08)',
  },
  kicker: { color: '#a1a1aa', fontSize: 13, fontWeight: '600', marginBottom: 6 },
  name: { color: '#fff', fontSize: 26, fontWeight: '700', marginBottom: 22 },
  row: { flexDirection: 'row', gap: 12 },
  btn: { flex: 1, borderRadius: 22, paddingVertical: 14, alignItems: 'center' },
  decline: { backgroundColor: '#3f3f46' },
  accept: { backgroundColor: '#22c55e' },
  btnText: { color: '#fff', fontSize: 16, fontWeight: '700' },
});
