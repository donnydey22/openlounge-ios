// App-side video for the PJSIP leg: camera -> VideoToolbox H.264 simulcast -> ol_sfu_video_send; received AUs
// (ol_sfu_video sink) -> OLVideoDecoder -> on-screen views. Camera only after CallKit didActivate (OLVideoCapture gate).
import AVFoundation
import CoreImage
import UIKit
import ExpoModulesCore

public final class OLCallVideo {
  public static let shared = OLCallVideo()
  let capture = OLVideoCapture()
  private var decoder: OLVideoDecoder?
  private let ci = CIContext(options: [.useSoftwareRenderer: false])
  public weak var remoteView: OLRemoteVideoView?
  public weak var localView: OLLocalVideoView?
  public private(set) var remoteFrames = 0
  var onRemoteFirstFrame: (() -> Void)?

  public func start(ip: String, port: Int, txKey: String, rxKey: String, ssrcs: [UInt32], pt: Int) -> Int {
    let dec = OLVideoDecoder(); decoder = dec; remoteFrames = 0
    dec.onFrame = { [weak self] px in
      guard let self, let cg = self.ci.createCGImage(CIImage(cvPixelBuffer: px), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))) else { return }
      self.remoteFrames += 1; let first = self.remoteFrames == 1
      DispatchQueue.main.async { self.remoteView?.layer.contents = cg; if first { self.onRemoteFirstFrame?() } }
    }
    ol_sfu_video_set_sink({ user, au, len, _, _ in
      guard let au, len > 0 else { return }
      OLCallVideo.shared.decoder?.decode(annexB: Data(bytes: au, count: Int(len)))
    }, nil)
    // empty ip = phone<->phone: the direct ICE link is the only path (no SFU socket)
    return ssrcs.withUnsafeBufferPointer { ip.isEmpty ? Int(ol_sfu_video_start_direct($0.baseAddress, Int32($0.count), Int32(pt))) : Int(ol_sfu_video_start(ip, Int32(port), txKey, rxKey, $0.baseAddress, Int32($0.count), Int32(pt))) }
  }

  public func camera(on: Bool, facing: String) throws {
    capture.stop()
    guard on else { DispatchQueue.main.async { self.localView?.detach() }; return }
    let front = facing != "environment"
    try capture.start(position: front ? .front : .back)
    // local preview = the SAME captured buffers the fan-out encodes (no preview layer on the capture session)
    capture.fanout?.onPreview = { [weak self] sb in self?.localView?.enqueue(sb) }
    DispatchQueue.main.async { self.localView?.attach(mirrored: front) }
  }

  public func stop() {
    capture.stop(); ol_sfu_video_set_sink(nil, nil); ol_sfu_video_stop(); decoder?.close(); decoder = nil
    DispatchQueue.main.async { self.remoteView?.layer.contents = nil; self.localView?.detach() }
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
    backgroundColor = .black; layer.contentsGravity = .resizeAspectFill; clipsToBounds = true
    OLCallVideo.shared.remoteView = self
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
