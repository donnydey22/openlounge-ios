// FX-080 (iOS lane) 3-layer simulcast for the native camera producer. Same layers as the web lane
// (src/lib/calls/simulcast.ts in openlounge) with the native 850 kbps top cap. Enabled only when the page's connect
// command carries simulcast:true (rollout flag) — otherwise the proven single VP8 encoding is used unchanged.
export const NATIVE_SIMULCAST_LAYERS = [
  { rid: 'q', scaleResolutionDownBy: 4, maxBitrate: 150_000, maxFramerate: 15 },
  { rid: 'h', scaleResolutionDownBy: 2, maxBitrate: 400_000, maxFramerate: 24 },
  { rid: 'f', scaleResolutionDownBy: 1, maxBitrate: 850_000, maxFramerate: 30 },
] as const;
const MIN_FPS = 15; // FX-079 floor

export function nativeCameraEncodings(simulcast: boolean, topBps: number) {
  if (!simulcast) return [{ maxBitrate: topBps, maxFramerate: 30, scaleResolutionDownBy: 1, priority: 'high', networkPriority: 'high' }];
  return NATIVE_SIMULCAST_LAYERS.map((l, i) => ({ rid: l.rid, scaleResolutionDownBy: l.scaleResolutionDownBy, maxBitrate: i === 2 ? topBps : l.maxBitrate, maxFramerate: l.maxFramerate, scalabilityMode: 'L1T3', priority: i === 0 ? 'high' : 'low', networkPriority: i === 0 ? 'high' : 'low', active: true }));
}

type Enc = { active?: boolean; maxBitrate?: number; maxFramerate?: number; scaleResolutionDownBy?: number };
/** Ladder on a layered sender: low layer always on (>= 15 fps), upper layers on only while they fit the video budget. */
export function nativeSimulcastLadder(encodings: Enc[], step: { videoBps?: number; videoFps?: number }) {
  const budget = step.videoBps ?? Infinity;
  let used = 0;
  encodings.forEach((e, i) => {
    const l = NATIVE_SIMULCAST_LAYERS[Math.min(i, 2)];
    const fits = i === 0 || used + l.maxBitrate <= budget;
    e.active = fits;
    e.maxBitrate = i === 0 ? Math.max(60_000, Math.min(l.maxBitrate, budget)) : l.maxBitrate;
    e.maxFramerate = Math.max(MIN_FPS, Math.min(l.maxFramerate, step.videoFps ?? l.maxFramerate));
    e.scaleResolutionDownBy = l.scaleResolutionDownBy;
    if (fits) used += e.maxBitrate;
  });
  return encodings;
}
