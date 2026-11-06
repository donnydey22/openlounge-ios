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

  public private(set) var position: AVCaptureDevice.Position = .front
  private var input: AVCaptureDeviceInput?, output: AVCaptureVideoDataOutput?

  /// Synchronous part (throws to the caller): didActivate gate, all-3 HW encoders, fan-out, camera device + input.
  /// AVCaptureSession configuration and startRunning run OFF the main thread on the capture queue.
  public func start(engine: PJSIPEngine = .shared, position: AVCaptureDevice.Position = .front) throws {
    guard engine.audioRunning else { throw OLVideoError.notActivated } // didActivate gate
    guard session == nil else { return try flip(to: position) }
    let enc = try makeEncoder() // all 3 hardware layers or nothing
    let fan: OLCameraFanout
    do { fan = try OLCameraFanout(targets: Self.fanoutTargets()) { [weak self] i, px, pts in self?.encoder?.encode(layer: i, px, pts: pts) } }
    catch { enc.teardown(); throw error }
    guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
          let inp = try? AVCaptureDeviceInput(device: cam) else { fan.release(); enc.teardown(); throw OLVideoError.cameraUnavailable }
    let s = AVCaptureSession()
    s.automaticallyConfiguresApplicationAudioSession = false // audio session is owned by the CallKit/PJSIP path only
    let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    setEncoder(enc); fanout = fan; session = s; input = inp; output = out; self.position = position
    let nc = NotificationCenter.default
    observers = [
      nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { [weak self, weak s] _ in self?.q.async { guard self?.session === s else { return }; s?.startRunning() } },
      nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: s, queue: nil) { [weak self] _ in self?.encoder?.forceKeyframe() },
      // VideoToolbox drops HW sessions while backgrounded; the next encode returns -12903 -> rebuild (also IDR on foreground).
      nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in self?.encoder?.forceKeyframe() },
    ]
    q.async { [weak self] in
      guard let self, self.session === s else { return } // never configures/starts after stop()
      s.beginConfiguration()
      s.sessionPreset = s.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720
      guard s.canAddInput(inp), s.canAddOutput(out) else { s.commitConfiguration(); NSLog("[OLVideo] capture config failed"); return }
      s.addInput(inp); out.setSampleBufferDelegate(self, queue: self.q); s.addOutput(out)
      self.orient(out, position)
      // background/PiP: keep the camera running while multitasking where the OS allows it (else iOS freezes capture)
      if s.isMultitaskingCameraAccessSupported { s.isMultitaskingCameraAccessEnabled = true }
      s.commitConfiguration()
      s.startRunning()
    }
  }

  private func orient(_ out: AVCaptureVideoDataOutput, _ position: AVCaptureDevice.Position) {
    guard let c = out.connection(with: .video) else { return }
    if c.isVideoOrientationSupported { c.videoOrientation = .portrait } // portrait-locked call screen (rotated buffers, no CVO needed)
    if c.isVideoMirroringSupported { c.isVideoMirrored = false } // send unmirrored; preview mirrors in the view
  }

  /// Front/back flip WITHOUT rebuilding encoders/fan-out/session: swap the input in one configuration, re-orient, IDR.
  public func flip(to position: AVCaptureDevice.Position) throws {
    guard let s = session, position != self.position else { return }
    guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
          let inp = try? AVCaptureDeviceInput(device: cam) else { throw OLVideoError.cameraUnavailable }
    self.position = position
    q.async { [weak self] in
      guard let self, self.session === s else { return }
      s.beginConfiguration()
      if let old = self.input { s.removeInput(old) }
      if s.canAddInput(inp) { s.addInput(inp); self.input = inp } else if let old = self.input, s.canAddInput(old) { s.addInput(old) }
      if let out = self.output { self.orient(out, position) }
      s.commitConfiguration()
      self.encoder?.forceKeyframe()
    }
  }

  public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    // SFU PLI/FIR per SSRC: bitmask of layers (SSRC index == layer index == SFU LADDERS index), throttled per layer.
    let req = ol_sfu_video_take_keyreq(); if req != 0 { encoder?.forceKeyframe(mask: req) }
    fanout?.push(sb)
  }

  /// Teardown on every call end. Order (Android parity): session -> camera input -> fan-out -> encoder. Never on q.
  public func stop() {
    observers.forEach(NotificationCenter.default.removeObserver); observers = []
    let s = session; session = nil // configure/start blocks queued on q see session !== s and bail
    if let s { q.sync {
      if s.isRunning { s.stopRunning() }
      s.beginConfiguration(); s.inputs.forEach(s.removeInput); s.outputs.forEach(s.removeOutput); s.commitConfiguration()
      output?.setSampleBufferDelegate(nil, queue: nil)
    } }
    input = nil; output = nil
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
