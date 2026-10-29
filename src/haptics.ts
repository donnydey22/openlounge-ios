import * as Haptics from 'expo-haptics';

import type { HapticKind } from './bridge';

let lastAt = 0;

/** Light, throttled haptics for key actions (page calls OpenLoungeNative.haptic(kind)). */
export function playHaptic(kind: HapticKind): void {
  try {
    playHapticUnsafe(kind);
  } catch {}
}

function playHapticUnsafe(kind: HapticKind): void {
  const now = Date.now();
  if (now - lastAt < 60) return;
  lastAt = now;
  const I = Haptics.ImpactFeedbackStyle;
  const N = Haptics.NotificationFeedbackType;
  let p: Promise<void>;
  switch (kind) {
    case 'raiseHand':
      p = Haptics.impactAsync(I.Light);
      break;
    case 'joinStage':
      p = Haptics.notificationAsync(N.Success);
      break;
    case 'sendDm':
      p = Haptics.impactAsync(I.Soft);
      break;
    case 'light':
    case 'medium':
    case 'heavy':
    case 'soft':
    case 'rigid':
      p = Haptics.impactAsync(kind as Haptics.ImpactFeedbackStyle);
      break;
    case 'selection':
      p = Haptics.selectionAsync();
      break;
    case 'success':
    case 'warning':
    case 'error':
      p = Haptics.notificationAsync(kind as Haptics.NotificationFeedbackType);
      break;
    default:
      return;
  }
  p.catch(() => {});
}
