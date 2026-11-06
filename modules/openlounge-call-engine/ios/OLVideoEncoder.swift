// Video spec v2 (PLAN §14) iOS capture + engine glue. Encoder/decoder: OLVideoCodec.swift.
import AVFoundation
import VideoToolbox

/// Camera capture, opened only after CallKit didActivate.
public final class OLVideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  public private(set) var session: AVCaptureSession?
  private let q = DispatchQueue(label: "ol.video.capture", qos: .userInteractive)
  public private(set) var encoder: OLSimulcastEncoder?

  public func start(engine: PJSIPEngine = .shared, position: AVCaptureDevice.Position = .front, forceH264: Bool = false) throws {
    guard engine.audioRunning else { throw OLVideoError.notActivated } // didActivate gate
    let enc = try OLSimulcastEncoder(forceH264: forceH264); encoder = enc
    // Video spec v2 send path: each layer's Annex-B AU -> engine RTP/SRTP on the "video" PlainTransport (own SSRC per layer)
    enc.onAnnexB = { layer, au, key, ts in au.withUnsafeBytes { _ = ol_sfu_video_send(Int32(layer), $0.bindMemory(to: UInt8.self).baseAddress, Int32(au.count), ts, key ? 1 : 0) } }
    let s = AVCaptureSession(); s.sessionPreset = .hd1920x1080
    // Linphone cut: camera must not reconfigure the call AVAudioSession.
    s.automaticallyConfiguresApplicationAudioSession = false
    if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position), let input = try? AVCaptureDeviceInput(device: cam), s.canAddInput(input) { s.addInput(input) }
    let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true; out.setSampleBufferDelegate(self, queue: q)
    if s.canAddOutput(out) { s.addOutput(out) }
    session = s; q.async { s.startRunning() }
  }

  public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
    if ol_sfu_video_take_keyreq() != 0 { encoder?.forceKeyframe() } // SFU PLI/FIR -> IDR now
    encoder?.encode(px, pts: CMSampleBufferGetPresentationTimeStamp(sb))
  }

  /// Teardown on every call end.
  public func stop() { session?.stopRunning(); session = nil; encoder?.teardown(); encoder = nil }
}
