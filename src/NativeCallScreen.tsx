import React, { useEffect, useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { BUTTONS, NativeCallState, initials, statusText } from './nativeCallFlow';

// Native 1:1 audio call screen (outgoing / connecting / active / end).
// Flow + placement: Telegram-iOS submodules/TelegramCallsUI/Sources/CallControllerNode.swift (name + status centred,
// buttons row at the bottom) and CallControllerButtonsNode.swift (.active row order: camera, soundOutput, mute, end).
// Look: Open Lounge's own web call screen (olpj src/components/calls/CallOverlay.tsx, calls.module.css, Avatar.tsx):
// #0b1220 stage, xl initials avatar, 28pt semibold name, 15pt white/80 status, RoundBtn 56pt white/15 (active = white
// with zinc-900 icon), red-500 End call, 12pt white/85 label under each button, lucide icons. Like the web, a native
// voice call has no Video button. Actions go back to the page's engine (openlounge:native-call).
const ICON = {
  speaker: require('../assets/call/volume2.png'), phone: require('../assets/call/ear.png'),
  mic: require('../assets/call/mic.png'), micOff: require('../assets/call/mic_off.png'), end: require('../assets/call/phone_off.png'),
};
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
  const btn = {
    speaker: { label: p.speaker ? 'Speaker' : 'Phone', icon: p.speaker ? ICON.speaker : ICON.phone, active: p.speaker, onPress: p.onSpeaker },
    mute: { label: p.muted ? 'Unmute' : 'Mute', icon: p.muted ? ICON.micOff : ICON.mic, active: p.muted, onPress: p.onMute },
    end: { label: 'End call', icon: ICON.end, active: false, onPress: p.onEnd },
  } as const;
  return (
    <View style={s.root} accessibilityViewIsModal testID="native-call-screen">
      <View style={s.shadeTop} /><View style={s.shadeBottom} />
      <View style={s.top}>
        <View style={s.avatar}><Text style={s.initials}>{initials(p.name)}</Text></View>
        <Text style={s.name} numberOfLines={1}>{p.name}</Text>
        <Text style={s.status} testID="native-call-status">{statusText(p.state, sec)}</Text>
      </View>
      <View style={[s.row, { marginBottom: 40 + p.bottomInset }]}>
        {BUTTONS.filter((b): b is keyof typeof btn => b in btn).map((b) => {
          const x = btn[b];
          return (
            <Pressable key={b} testID={`native-call-${b}`} onPress={x.onPress} accessibilityLabel={x.label} style={s.cell}>
              <View style={[s.btn, x.active && s.on, b === 'end' && s.end]}>
                <Image source={x.icon} style={[s.icon, x.active && { tintColor: '#18181b' }]} />
              </View>
              <Text style={s.lbl} numberOfLines={1}>{x.label}</Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  root: { ...StyleSheet.absoluteFill, zIndex: 20, backgroundColor: '#0b1220', justifyContent: 'center' },
  shadeTop: { position: 'absolute', top: 0, left: 0, right: 0, height: '40%', backgroundColor: 'rgba(0,0,0,0.15)' },
  shadeBottom: { position: 'absolute', bottom: 0, left: 0, right: 0, height: '35%', backgroundColor: 'rgba(0,0,0,0.3)' },
  top: { alignItems: 'center', paddingHorizontal: 24, marginBottom: 80 },
  avatar: { width: 112, height: 112, borderRadius: 56, backgroundColor: '#64748B', alignItems: 'center', justifyContent: 'center', marginBottom: 12 },
  initials: { color: '#fff', fontSize: 30, fontWeight: '500' },
  name: { color: '#fff', fontSize: 28, fontWeight: '600', letterSpacing: -0.3 },
  status: { color: 'rgba(255,255,255,0.8)', fontSize: 15, marginTop: 4, fontVariant: ['tabular-nums'] },
  row: { position: 'absolute', bottom: 0, left: 16, right: 16, flexDirection: 'row', justifyContent: 'space-evenly' },
  cell: { alignItems: 'center', width: 76 },
  btn: { width: 56, height: 56, borderRadius: 28, backgroundColor: 'rgba(255,255,255,0.15)', alignItems: 'center', justifyContent: 'center' },
  on: { backgroundColor: '#fff' },
  end: { backgroundColor: '#ef4444' },
  icon: { width: 24, height: 24 },
  lbl: { color: 'rgba(255,255,255,0.85)', fontSize: 12, fontWeight: '500', marginTop: 6 },
});
