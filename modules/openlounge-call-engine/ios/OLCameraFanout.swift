// Open Lounge call video, iOS fan-out (parity with Android OLCameraFanout.kt): ONE AVCaptureVideoDataOutput frame ->
// hardware VTPixelTransferSession scale per layer -> that layer's hardware H.264 VTCompressionSession, plus the native
// local preview drawn from the SAME captured buffer (no AVCaptureVideoPreviewLayer, no second capture consumer).
// Written against documented AVFoundation / VideoToolbox / CoreMedia APIs only; no third-party code.
import AVFoundation
import CoreMedia
import VideoToolbox

/// Encoder target i receives a pixel buffer at exactly layer i's size. Every target gets the SAME source PTS.
/// Bounded: the capture output discards late frames and each pool has a small allocation threshold, so a slow frame is
/// dropped, never queued.
public final class OLCameraFanout {
  public struct Target { public let width: Int32, height: Int32, fps: Int }
  private let targets: [Target]
  private var scalers: [VTPixelTransferSession] = []
  private var pools: [CVPixelBufferPool] = []
  private var lastPts: [CMTime]
  private let sink: (_ layer: Int, _ px: CVPixelBuffer, _ pts: CMTime) -> Void
  private let lock = NSLock()
  private var released = false
  /// Local preview, drawn from the captured buffer itself (independent of encoders; nil = detached).
  public var onPreview: ((CMSampleBuffer) -> Void)? {
    get { lock.lock(); defer { lock.unlock() }; return _preview } set { lock.lock(); _preview = newValue; lock.unlock() } }
  private var _preview: ((CMSampleBuffer) -> Void)?
  public private(set) var frames = 0, drops = 0

  public init(targets: [Target], sink: @escaping (Int, CVPixelBuffer, CMTime) -> Void) throws {
    self.targets = targets; self.sink = sink; lastPts = Array(repeating: .invalid, count: targets.count)
    for (i, t) in targets.enumerated() {
      var s: VTPixelTransferSession?
      guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else { release(); throw OLVideoError.captureConfig("scaler \(i)") }
      VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim) // same aspect (16:9) for every layer
      VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
      scalers.append(s)
      let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: Int(t.width), kCVPixelBufferHeightKey: Int(t.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
      var p: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attrs as CFDictionary, &p) == kCVReturnSuccess, let p else { release(); throw OLVideoError.captureConfig("pool \(i)") }
      pools.append(p)
    }
  }

  /// Capture queue. Per-layer cadence (15/30 fps), same PTS to all layers, then preview.
  public func push(_ sb: CMSampleBuffer) {
    lock.lock(); if released { lock.unlock(); return }; let preview = _preview; lock.unlock()
    guard let src = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    frames += 1
    for (i, t) in targets.enumerated() {
      if lastPts[i].isValid, (pts - lastPts[i]).seconds < 1.0 / Double(t.fps) - 0.002 { continue } // per-layer cadence
      var out: CVPixelBuffer?
      let aux = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
      guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pools[i], aux, &out) == kCVReturnSuccess, let out else { drops += 1; continue } // encoder backed up: drop
      guard VTPixelTransferSessionTransferImage(scalers[i], from: src, to: out) == noErr else { drops += 1; continue }
      lastPts[i] = pts
      sink(i, out, pts)
    }
    preview?(sb)
  }

  /// Idempotent. Call AFTER the capture session stops and BEFORE the encoder is torn down (same order as Android).
  public func release() {
    lock.lock(); released = true; _preview = nil; lock.unlock()
    for s in scalers { VTPixelTransferSessionInvalidate(s) }; scalers = []; pools = []
  }
  deinit { release() }
}
