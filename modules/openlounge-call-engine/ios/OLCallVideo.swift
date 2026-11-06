// App-side video for the PJSIP leg: camera -> VideoToolbox H.264 simulcast -> ol_sfu_video_send; received AUs
// (ol_sfu_video sink) -> OLVideoDecoder -> on-screen views. Camera only after CallKit didActivate (OLVideoCapture gate).
import AVFoundation
import UIKit
import ExpoModulesCore

public final class OLCallVideo {
  public static let shared = OLCallVideo()
  let capture = OLVideoCapture()
  private var decoder: OLVideoDecoder?
  public weak var remoteView: OLRemoteVideoView?
  public weak var localView: OLLocalVideoView?
  public private(set) var remoteFrames = 0
  var onRemoteFirstFrame: (() -> Void)?

  public func start(ip: String, port: Int, txKey: String, rxKey: String, ssrcs: [UInt32], pt: Int) -> Int {
    let dec = OLVideoDecoder(); decoder = dec; remoteFrames = 0
    // GPU path: decoded CVPixelBuffer -> CMSampleBuffer -> AVSampleBufferDisplayLayer (no CIContext/CGImage CPU copy)
    dec.onFrame = { [weak self] px in
      guard let self, let sb = OLRemoteVideoView.sampleBuffer(px) else { return }
      self.remoteFrames += 1; let first = self.remoteFrames == 1
      self.remoteView?.enqueue(sb)
      if first { DispatchQueue.main.async { self.onRemoteFirstFrame?() } }
    }
    ol_sfu_video_set_sink({ user, au, len, _, _ in
      guard let au, len > 0 else { return }
      OLCallVideo.shared.decoder?.decode(annexB: Data(bytes: au, count: Int(len)))
    }, nil)
    // empty ip = phone<->phone: the direct ICE link is the only path (no SFU socket)
    return ssrcs.withUnsafeBufferPointer { ip.isEmpty ? Int(ol_sfu_video_start_direct($0.baseAddress, Int32($0.count), Int32(pt))) : Int(ol_sfu_video_start(ip, Int32(port), txKey, rxKey, $0.baseAddress, Int32($0.count), Int32(pt))) }
  }

  public func camera(on: Bool, facing: String) throws {
    let front = facing != "environment"
    guard on else { capture.stop(); DispatchQueue.main.async { self.localView?.detach() }; return }
    // camera already running: flip the input only (no encoder/fan-out/session rebuild)
    if capture.session != nil { try capture.flip(to: front ? .front : .back); DispatchQueue.main.async { self.localView?.attach(mirrored: front) }; return }
    try capture.start(position: front ? .front : .back)
    // local preview = the SAME captured buffers the fan-out encodes (no preview layer on the capture session)
    capture.fanout?.onPreview = { [weak self] sb in self?.localView?.enqueue(sb) }
    DispatchQueue.main.async { self.localView?.attach(mirrored: front) }
  }

  public func stop() {
    // sink off first (no AU reaches a closing decoder), camera/encoders, then the RTP leg, then the decoder
    ol_sfu_video_set_sink(nil, nil); capture.stop(); ol_sfu_video_stop()
    decoder?.onFrame = nil; decoder?.close(); decoder = nil; remoteFrames = 0; onRemoteFirstFrame = nil
    DispatchQueue.main.async { self.remoteView?.clear(); self.localView?.detach() }
  }

  public func stats() -> [Int] {
    var rp: UInt32 = 0, ra: UInt32 = 0, rk: UInt32 = 0, rg: UInt32 = 0, tp: UInt32 = 0, ta: UInt32 = 0, tk: UInt32 = 0
    _ = ol_sfu_video_stats(&rp, &ra, &rk, &rg, &tp, &ta, &tk)
    return [Int(rp), Int(ra), Int(rk), Int(rg), Int(tp), Int(ta), Int(tk), remoteFrames]
  }
}

public final class OLRemoteVideoView: ExpoView {
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black; clipsToBounds = true
    display.videoGravity = .resizeAspectFill; layer.addSublayer(display)
    OLCallVideo.shared.remoteView = self
  }
  private let display = AVSampleBufferDisplayLayer()
  /// Decoder thread -> display layer (thread-safe enqueue; drops while not ready).
  func enqueue(_ sb: CMSampleBuffer) {
    if display.status == .failed { display.flush() }
    if display.isReadyForMoreMediaData { display.enqueue(sb) }
  }
  func clear() { display.flushAndRemoveImage() }
  public override func layoutSubviews() { super.layoutSubviews(); display.frame = bounds }
  /// Wrap a decoded frame for immediate display (DisplayImmediately; no timebase).
  static func sampleBuffer(_ px: CVPixelBuffer) -> CMSampleBuffer? {
    var fd: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &fd) == noErr, let fd else { return nil }
    var t = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: fd, sampleTiming: &t, sampleBufferOut: &sb) == noErr, let sb else { return nil }
    if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {
      let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sb
  }
}

/// Local self-view drawn from the fan-out's captured sample buffers (same feed as the encoders, not a capture output).
public final class OLLocalVideoView: ExpoView {
  private let display = AVSampleBufferDisplayLayer()
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black; clipsToBounds = true
    display.videoGravity = .resizeAspectFill; layer.addSublayer(display)
    OLCallVideo.shared.localView = self
    if OLCallVideo.shared.capture.session != nil { attach(mirrored: true) }
  }
  /// Capture queue -> display layer (thread-safe enqueue; drops while the layer is not ready).
  func enqueue(_ sb: CMSampleBuffer) {
    if display.status == .failed { display.flush() }
    if display.isReadyForMoreMediaData { display.enqueue(sb) }
  }
  func attach(mirrored: Bool) { display.isHidden = false; display.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity) }
  func detach() { display.flushAndRemoveImage(); display.isHidden = true }
  public override func layoutSubviews() { super.layoutSubviews(); display.frame = bounds }
}
