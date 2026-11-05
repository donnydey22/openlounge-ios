// Page call message -> Telegram call state (TelegramMessenger/Telegram-iOS@279f89e
// submodules/TelegramCallsUI/Sources/PresentationCall.swift updateSessionState; CallControllerNode.swift status text).
// Pure (unit-tested). The page's engine on openlounge.app stays the only owner of call:*; nothing else is in the flow.
export type NativeCallState = 'waiting' | 'connecting' | 'active' | 'terminated';

export function stateFor(type: unknown): NativeCallState | null {
  switch (type) {
    case 'call:outgoing': return 'waiting';     // .waiting (WhatsApp wording "Calling…")
    case 'call:answering': return 'connecting'; // .connecting
    case 'call:connected': return 'active';     // engine .connected -> .active (updateSessionState)
    case 'call:ended': return 'terminated';     // .terminated -> controller dismissed
    default: return null;
  }
}

export function statusText(s: NativeCallState | null, sec: number): string {
  if (s === 'waiting') return 'Calling…';
  if (s === 'connecting') return 'Connecting…';
  if (s === 'active') return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
  return '';
}

/** Gate: native screen only for audio calls the page announced with a callId (video keeps the web screen + native tiles). */
export function takesOver(v: { type?: unknown; callId?: unknown; video?: unknown }): boolean {
  return (v.type === 'call:outgoing' || v.type === 'call:answering') && typeof v.callId === 'string' && v.callId.length > 0 && v.video !== true;
}

/** CallControllerButtonsNode.swift (.active, no video): [enableCamera][soundOutput][mute][end]; camera shown disabled. */
export const BUTTONS = ['camera', 'speaker', 'mute', 'end'] as const;
