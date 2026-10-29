// Threads-style "Open Lounge" wordmark entrance over the WebView (mirrors web header .ol-word: bold, tracking-tight).
// Enter: opacity 0→1 (240ms), springy scale 0.6→1, then a native-driven heartbeat pulse (own node) until exit; letter-spacing +0.02em→-0.025em, Easing.bezier(0.2,0,0,1).
// Held until `ready` (WebView onLoadEnd / web ready / offline) or LAUNCH_CAP_MS from mount.
// Exit 220ms: opacity 1→0, scale 1→1.06, Easing.bezier(0.4,0,1,1). Reduce Motion: 150ms opacity fade only.
import { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Animated, Easing, StyleSheet } from 'react-native';

export const LAUNCH_ENTER_MS = 240;
export const LAUNCH_EXIT_MS = 220;
export const LAUNCH_CAP_MS = 1500;
const SIZE = 34;
const TRACK_FROM = 0.02 * SIZE;
const TRACK_TO = -0.025 * SIZE;

export function LaunchOverlay({ ready, theme, onShown }: { ready: boolean; theme: 'light' | 'dark'; onShown?: () => void }) {
  const [gone, setGone] = useState(false);
  const [capped, setCapped] = useState(false);
  const [reduced, setReduced] = useState<boolean | null>(null);
  const entered = useRef(false);
  const fade = useRef(new Animated.Value(0)).current; // overlay+word opacity driver (native)
  const scale = useRef(new Animated.Value(0.6)).current;
  const track = useRef(new Animated.Value(TRACK_FROM)).current; // JS driver (letterSpacing)
  const pulse = useRef(new Animated.Value(1)).current; // native driver, its own Animated.View (never mixed)
  const loop = useRef<Animated.CompositeAnimation | null>(null);
  const [, force] = useState(0);

  useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled().then(setReduced, () => setReduced(false));
    const t = setTimeout(() => setCapped(true), LAUNCH_CAP_MS);
    return () => clearTimeout(t);
  }, []);

  useEffect(() => {
    if (reduced === null) return;
    onShown?.(); // overlay paints the same bg as the native splash → hide splash with no visible seam
    if (reduced) {
      fade.setValue(1); scale.setValue(1); pulse.setValue(1); track.setValue(TRACK_TO);
      entered.current = true; force((n) => n + 1);
      return;
    }
    const ease = Easing.bezier(0.2, 0, 0, 1);
    Animated.parallel([
      Animated.timing(fade, { toValue: 1, duration: LAUNCH_ENTER_MS, easing: ease, useNativeDriver: true }),
      Animated.spring(scale, { toValue: 1, friction: 5, tension: 120, useNativeDriver: true }),
    ]).start(() => { entered.current = true; force((n) => n + 1); });
    // strong steady heartbeat while the overlay is held
    const beat = (to: number, ms: number) => Animated.timing(pulse, { toValue: to, duration: ms, easing: Easing.inOut(Easing.quad), useNativeDriver: true });
    loop.current = Animated.loop(Animated.sequence([beat(1.14, 180), beat(1.02, 140), beat(1.1, 160), beat(1, 320), Animated.delay(200)]));
    loop.current.start();
    Animated.timing(track, { toValue: TRACK_TO, duration: LAUNCH_ENTER_MS, easing: ease, useNativeDriver: false }).start();
  }, [reduced]);

  const shouldExit = (ready || capped) && entered.current && !gone;
  useEffect(() => {
    if (!shouldExit) return;
    loop.current?.stop();
    const ease = Easing.bezier(0.4, 0, 1, 1);
    const d = reduced ? 150 : LAUNCH_EXIT_MS;
    Animated.parallel([
      Animated.timing(fade, { toValue: 0, duration: d, easing: ease, useNativeDriver: true }),
      ...(reduced ? [] : [Animated.timing(scale, { toValue: 1.06, duration: d, easing: ease, useNativeDriver: true })]),
    ]).start(() => setGone(true));
  }, [shouldExit]);

  if (gone) return null;
  const bg = theme === 'light' ? '#f4f3ee' : '#0b0b0d';
  const fg = theme === 'light' ? '#18181b' : '#f4f4f5';
  // Background stays opaque during enter (matches splash); fades with the word on exit.
  const bgOpacity = entered.current ? fade : 1;
  return (
    <Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill, styles.c, { backgroundColor: bg, opacity: bgOpacity }]}>
      {/* Native-driven opacity/scale live on this wrapper; the JS-driven letterSpacing stays on the inner Text so the
          two drivers never share an animated node (mixing them throws RCTFatal in Release). */}
      <Animated.View style={{ opacity: fade, transform: [{ scale }] }}>
        <Animated.View style={{ transform: [{ scale: pulse }] }}>
          <Animated.Text accessible={false} style={{ color: fg, fontSize: SIZE, fontWeight: '700', letterSpacing: track }}>
            Open Lounge
          </Animated.Text>
        </Animated.View>
      </Animated.View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({ c: { alignItems: 'center', justifyContent: 'center' } });
