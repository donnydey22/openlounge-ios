// Mirrors ChatSwap's CallMediaProfile.kt (read-only reference; ChatSwap is never edited or pushed here).
// Same order every call: audio track -> optional video track -> transport -> join -> produce.
/** ChatSwap audio: echo cancellation, AGC, noise suppression (+ high-pass / typing detection on Stream's m125 build). */
export const CHATSWAP_AUDIO = {
  echoCancellation: true,
  autoGainControl: true,
  noiseSuppression: true,
  googHighpassFilter: true,
  googTypingNoiseDetection: true,
} as const;
/** ChatSwap RTCConfiguration: unified plan, max-bundle, rtcp-mux required, all candidates, continual gathering, TCP on.
 *  ICE server order comes from the page/signaling (UDP first, then TCP, then TLS 443; short-lived TURN logins). */
export const CHATSWAP_RTC = {
  sdpSemantics: 'unified-plan',
  bundlePolicy: 'max-bundle',
  rtcpMuxPolicy: 'require',
  continualGatheringPolicy: 'gather_continually',
  tcpCandidatePolicy: 'enabled',
  candidateNetworkPolicy: 'all',
} as const;
/** ChatSwap capture profile. */
export const CHATSWAP_VIDEO = { width: 640, height: 480, fps: 24 } as const;
export const MAX_ICE_RESTARTS = 2;
