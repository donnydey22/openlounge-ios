// Video spec v2 (PLAN §14) iOS capture + engine glue, fan-out shape (Nov 5). Encoder/decoder: OLVideoCodec.swift;
// scaling + preview fan-out: OLCameraFanout.swift. Independent of the AVAudioSession path: the capture session never
// touches the app audio session and has no audio input.
import AVFoundation
import UIKit
import VideoToolbox

/// ONE AVCaptureSession, ONE AVCaptureVideoDataOutput (the only capture consumer). Opened only after CallKit didActivate.
public final class OLVideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  public private(set) var session: AVCaptureSession?
  private let q = DispatchQueue(label: "ol.video.capture", qos: .userInteractive)
  private let encLock = NSLock(); private var _encoder: OLSimulcastEncoder?
  /// Current 3-layer encoder (swapped on a -12903 rebuild; read from the fan-out queue).
  public var encoder: OLSimulcastEncoder? { encLock.lock(); defer { encLock.unlock() }; return _encoder }
  private func setEncoder(_ e: OLSimulcastEncoder?) { encLock.lock(); _encoder = e; encLock.unlock() }
  public private(set) var fanout: OLCameraFanout?
  private var observers: [NSObjectProtocol] = []

  /// Portrait-locked call screen: the capture connection is rotated to portrait, so every layer is portrait too
  /// (180x320, 720x1280, 1080x1920) -- encoder size == fan-out target size == rotated buffer aspect (no stretch).
  public static let portraitLayers: [OLVideoLayer] = OLVideoSpecV2.layers.map { .init(width: $0.height, height: $0.width, bps: $0.bps, ultrafast: $0.ultrafast) }
  /// Fan-out targets in layer/SSRC order (180p@15, 720p@30, 1080p@30).
  public static func fanoutTargets() -> [OLCameraFanout.Target] { portraitLayers.map { .init(width: $0.width, height: $0.height, fps: OLVideoSpecV2.fps($0)) } }

  public func start(engine: PJSIPEngine = .shared, position: AVCaptureDevice.Position = .front) throws {
    guard engine.audioRunning else { throw OLVideoError.notActivated } // didActivate gate
    // all 3 hardware layers or nothing
    let enc = try makeEncoder()
    let fan: OLCameraFanout
    do { fan = try OLCameraFanout(targets: Self.fanoutTargets()) { [weak self] i, px, pts in self?.encoder?.encode(layer: i, px, pts: pts) } }
    catch { enc.teardown(); throw error }

    let s = AVCaptureSession()
    s.automaticallyConfiguresApplicationAudioSession = false // audio session is owned by the CallKit/PJSIP path only
    s.beginConfiguration()
    s.sessionPreset = .hd1920x1080
    guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
          let input = try? AVCaptureDeviceInput(device: cam), s.canAddInput(input) else { s.commitConfiguration(); fan.release(); enc.teardown(); throw OLVideoError.cameraUnavailable }
    s.addInput(input)
    let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    out.setSampleBufferDelegate(self, queue: q)
    guard s.canAddOutput(out) else { s.commitConfiguration(); fan.release(); enc.teardown(); throw OLVideoError.captureConfig("output") }
    s.addOutput(out)
    if let c = out.connection(with: .video) {
      if c.isVideoOrientationSupported { c.videoOrientation = .portrait } // portrait-locked call screen
      if position == .front, c.isVideoMirroringSupported { c.isVideoMirrored = false } // send unmirrored; preview mirrors in the view
    }
    if s.isMultitaskingCameraAccessSupported { s.isMultitaskingCameraAccessEnabled = true }
    s.commitConfiguration()
    setEncoder(enc); fanout = fan; session = s
    let nc = NotificationCenter.default
    observers = [
      nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { [weak self, weak s] _ in self?.q.async { s?.startRunning() } },
      nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: s, queue: nil) { [weak self] _ in self?.encoder?.forceKeyframe() },
      // VideoToolbox drops HW sessions while backgrounded; the next encode returns -12903 -> rebuild (also probe on foreground).
      nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in self?.encoder?.forceKeyframe() },
    ]
    q.async { [weak self] in guard self?.session === s else { return }; s.startRunning() } // never starts after stop()
  }

  public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    // SFU PLI/FIR per SSRC: bitmask of layers (SSRC index == layer index == SFU LADDERS index), throttled per layer.
    let req = ol_sfu_video_take_keyreq(); if req != 0 { encoder?.forceKeyframe(mask: req) }
    fanout?.push(sb)
  }

  /// Teardown on every call end. Order (Android parity): session -> fan-out -> encoder.
  public func stop() {
    observers.forEach(NotificationCenter.default.removeObserver); observers = []
    if let s = session { q.sync { s.stopRunning() } }; session = nil
    fanout?.release(); fanout = nil
    let e = encoder; setEncoder(nil); e?.teardown()
  }

  /// All three hardware layers or nothing; Annex-B -> ol_sfu_video_send on the layer's own SSRC.
  private func makeEncoder() throws -> OLSimulcastEncoder {
    let enc = try OLSimulcastEncoder(layers: Self.portraitLayers)
    guard enc.layerCount == 3 else { enc.teardown(); throw OLVideoError.hardwareEncoderUnavailable(layer: enc.layerCount, status: -3) }
    // Video spec v2 send path: each layer's Annex-B AU -> engine RTP/SRTP on the "video" PlainTransport (own SSRC per layer)
    enc.onAnnexB = { layer, au, key, ts in au.withUnsafeBytes { _ = ol_sfu_video_send(Int32(layer), $0.bindMemory(to: UInt8.self).baseAddress, Int32(au.count), ts, key ? 1 : 0) } }
    enc.onInvalidated = { [weak self] in self?.q.async { self?.rebuildEncoder() } }
    return enc
  }

  /// -12903 (kVTInvalidSessionErr): replace all three sessions (all or fail), then IDR on every layer.
  private func rebuildEncoder() {
    guard session != nil else { return } // call ended
    let old = encoder
    do { let n = try makeEncoder(); n.forceKeyframe(); setEncoder(n); old?.teardown(); NSLog("[OLVideo] encoder rebuilt after -12903") }
    catch { setEncoder(nil); old?.teardown(); NSLog("[OLVideo] encoder rebuild failed: %@ (send video off)", "\(error)") }
  }
}
