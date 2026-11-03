// Video spec v2 (Donny Nov 3 6:51 AM, PLAN §14). iOS: VideoToolbox HARDWARE encoder only (no software fallback),
// AV1 when the device has a hardware AV1 encoder (A17+), else H.264. 3 simulcast layers 180p/720p/1080p at
// 150/800/2400 kbps; lowest layer "ultrafast" (speed over quality), others "fast"; keyframe every 2 s.
// The capture session is opened only after CallKit didActivate (PJSIPEngine.audioRunning).
import AVFoundation
import VideoToolbox

public struct OLVideoLayer { public let width: Int32, height: Int32, bps: Int, ultrafast: Bool }

public enum OLVideoSpecV2 {
  public static let layers: [OLVideoLayer] = [
    .init(width: 320, height: 180, bps: 150_000, ultrafast: true),
    .init(width: 1280, height: 720, bps: 800_000, ultrafast: false),
    .init(width: 1920, height: 1080, bps: 2_400_000, ultrafast: false),
  ]
  public static let keyframeSeconds = 2
  /// AV1 only if VideoToolbox can open a hardware AV1 encoder on this device; never a software encoder.
  public static func hardwareAV1Available() -> Bool {
    var s: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
    let ok = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_AV1, encoderSpecification: spec,
                                        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr
    if let s { VTCompressionSessionInvalidate(s) }
    return ok
  }
}

public enum OLVideoError: Error { case hardwareEncoderUnavailable(layer: Int, status: OSStatus), notActivated }

/// Three hardware VTCompressionSessions, one per simulcast layer. Throws (call fails video) if any cannot be hardware.
public final class OLSimulcastEncoder {
  public let codec: CMVideoCodecType
  private var sessions: [VTCompressionSession] = []
  public var onEncoded: ((Int, CMSampleBuffer) -> Void)?

  public init() throws {
    codec = OLVideoSpecV2.hardwareAV1Available() ? kCMVideoCodecType_AV1 : kCMVideoCodecType_H264
    let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
    for (i, l) in OLVideoSpecV2.layers.enumerated() {
      var s: VTCompressionSession?
      let st = VTCompressionSessionCreate(allocator: nil, width: l.width, height: l.height, codecType: codec, encoderSpecification: spec,
                                          imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
      guard st == noErr, let s else { teardown(); throw OLVideoError.hardwareEncoderUnavailable(layer: i, status: st) }
      func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
      set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
      set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
      set(kVTCompressionPropertyKey_AverageBitRate, l.bps as CFNumber)
      set(kVTCompressionPropertyKey_DataRateLimits, [l.bps / 8, 1] as CFArray)
      set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, OLVideoSpecV2.keyframeSeconds as CFNumber)
      set(kVTCompressionPropertyKey_ExpectedFrameRate, (l.ultrafast ? 15 : 30) as CFNumber)
      // ultrafast = prioritize speed over quality; fast = realtime without the speed override
      set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, (l.ultrafast ? kCFBooleanTrue : kCFBooleanFalse)!)
      if codec == kCMVideoCodecType_H264 { set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel) }
      VTCompressionSessionPrepareToEncodeFrames(s)
      sessions.append(s)
    }
  }

  public func encode(_ pixels: CVPixelBuffer, pts: CMTime) {
    for (i, s) in sessions.enumerated() {
      VTCompressionSessionEncodeFrame(s, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] st, _, sb in
        if st == noErr, let sb { self?.onEncoded?(i, sb) }
      }
    }
  }

  public func teardown() { for s in sessions { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(s) }; sessions = [] }
  deinit { teardown() }
}

/// Camera capture, opened only after CallKit didActivate.
public final class OLVideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private var session: AVCaptureSession?
  private let q = DispatchQueue(label: "ol.video.capture", qos: .userInteractive)
  public private(set) var encoder: OLSimulcastEncoder?

  public func start(engine: PJSIPEngine = .shared) throws {
    guard engine.audioRunning else { throw OLVideoError.notActivated } // didActivate gate
    let enc = try OLSimulcastEncoder(); encoder = enc
    let s = AVCaptureSession(); s.sessionPreset = .hd1920x1080
    if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), let input = try? AVCaptureDeviceInput(device: cam), s.canAddInput(input) { s.addInput(input) }
    let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true; out.setSampleBufferDelegate(self, queue: q)
    if s.canAddOutput(out) { s.addOutput(out) }
    session = s; q.async { s.startRunning() }
  }

  public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
    encoder?.encode(px, pts: CMSampleBufferGetPresentationTimeStamp(sb))
  }

  /// Teardown on every call end.
  public func stop() { session?.stopRunning(); session = nil; encoder?.teardown(); encoder = nil }
}
