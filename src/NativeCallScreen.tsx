import React, { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { BUTTONS, NativeCallState, statusText } from './nativeCallFlow';

// Native 1:1 audio call screen (outgoing / connecting / active / end), laid out like Telegram-iOS
// submodules/TelegramCallsUI/Sources/CallControllerNode.swift (name + status centred near the top, buttons row at the
// bottom per CallControllerButtonsNode.swift). Actions go back to the page's engine (openlounge:native-call).
export function NativeCallScreen(p: {
  name: string; state: NativeCallState; activeAt: number; muted: boolean; speaker: boolean; bottomInset: number;
  onMute: () => void; onSpeaker: () => void; onEnd: () => void;
}) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (p.state !== 'active') return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [p.state]);
  const sec = p.activeAt ? Math.max(0, Math.floor((now - p.activeAt) / 1000)) : 0;
  const label = { camera: 'Video', speaker: p.speaker ? 'Speaker\non' : 'Speaker', mute: p.muted ? 'Muted' : 'Mute', end: 'End' };
  const press = { camera: undefined, speaker: p.onSpeaker, mute: p.onMute, end: p.onEnd };
  return (
    <View style={s.root} accessibilityViewIsModal testID="native-call-screen">
      <View style={s.top}>
        <Text style={s.name} numberOfLines={1}>{p.name}</Text>
        <Text style={s.status} testID="native-call-status">{statusText(p.state, sec)}</Text>
      </View>
      <View style={[s.row, { marginBottom: 56 + p.bottomInset }]}>
        {BUTTONS.map((b) => (
          <Pressable key={b} testID={`native-call-${b}`} onPress={press[b]} disabled={!press[b]}
            style={[s.btn, b === 'end' && s.end, (b === 'speaker' && p.speaker) || (b === 'mute' && p.muted) ? s.on : null, !press[b] && s.off]}>
            <Text style={s.lbl}>{label[b]}</Text>
          </Pressable>
        ))}
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  root: { ...StyleSheet.absoluteFill, zIndex: 20, backgroundColor: '#1C2B3A', justifyContent: 'space-between' },
  top: { marginTop: 96, alignItems: 'center', paddingHorizontal: 24 },
  name: { color: '#fff', fontSize: 28, fontWeight: '600' },
  status: { color: 'rgba(255,255,255,0.8)', fontSize: 16, marginTop: 6 },
  row: { flexDirection: 'row', justifyContent: 'center' },
  btn: { width: 64, height: 64, borderRadius: 32, marginHorizontal: 10, backgroundColor: 'rgba(255,255,255,0.25)', alignItems: 'center', justifyContent: 'center' },
  on: { backgroundColor: 'rgba(255,255,255,0.6)' },
  off: { opacity: 0.4 },
  end: { backgroundColor: '#F4473A' },
  lbl: { color: '#fff', fontSize: 11, textAlign: 'center' },
});
