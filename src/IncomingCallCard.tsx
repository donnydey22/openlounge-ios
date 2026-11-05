// Fallback incoming-call screen shown ABOVE the App Lock overlay when CallKit did not take the call
// (e.g. page got call:incoming over WS while locked and VoIP push is delayed).
// Look = Open Lounge's original web incoming screen (CallOverlay.tsx Incoming + calls.module.css): #0b1220 stage, xl
// squircle initials avatar, 28pt name, "Open Lounge audio call", red-500 Decline (PhoneOff) and emerald-500 Accept
// (Phone / Video) 72pt discs with 13pt labels. Same callbacks as before.
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { initials } from './nativeCallFlow';

const ICON = { end: require('../assets/call/phone_off.png'), phone: require('../assets/call/phone.png'), video: require('../assets/call/video.png') };

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
    <View style={s.wrap} testID="incoming-call-card">
      <View style={s.top}>
        <View style={s.avatar}><Text style={s.initials}>{initials(name || '?')}</Text></View>
        <Text style={s.name} numberOfLines={1}>{name || 'Incoming call'}</Text>
        <Text style={s.kicker}>{video ? 'Open Lounge video call' : 'Open Lounge audio call'}</Text>
      </View>
      <View style={s.row}>
        <Pressable onPress={onDecline} style={s.cell} accessibilityLabel="Decline">
          <View style={[s.btn, s.decline]}><Image source={ICON.end} style={s.icon} /></View>
          <Text style={s.lbl}>Decline</Text>
        </Pressable>
        <Pressable onPress={onAccept} style={s.cell} accessibilityLabel={video ? 'Accept video call' : 'Accept'}>
          <View style={[s.btn, s.accept]}><Image source={video ? ICON.video : ICON.phone} style={s.icon} /></View>
          <Text style={s.lbl}>Accept</Text>
        </Pressable>
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: '#0b1220', justifyContent: 'center', zIndex: 100 },
  top: { alignItems: 'center', paddingHorizontal: 24, marginBottom: 80 },
  avatar: { width: 112, height: 112, borderRadius: 47, borderCurve: 'continuous', overflow: 'hidden', backgroundColor: '#64748B', alignItems: 'center', justifyContent: 'center', marginBottom: 12 },
  initials: { color: '#fff', fontSize: 30, fontWeight: '500' },
  name: { color: '#fff', fontSize: 28, fontWeight: '600', letterSpacing: -0.3 },
  kicker: { color: 'rgba(255,255,255,0.8)', fontSize: 15, marginTop: 4 },
  row: { position: 'absolute', bottom: 48, left: 24, right: 24, flexDirection: 'row', justifyContent: 'space-around' },
  cell: { alignItems: 'center', gap: 8 },
  btn: { width: 72, height: 72, borderRadius: 36, alignItems: 'center', justifyContent: 'center', shadowColor: '#000', shadowOpacity: 0.4, shadowRadius: 10, shadowOffset: { width: 0, height: 4 } },
  decline: { backgroundColor: '#ef4444' },
  accept: { backgroundColor: '#10b981' },
  icon: { width: 32, height: 32 },
  lbl: { color: 'rgba(255,255,255,0.85)', fontSize: 13, fontWeight: '500' },
});
