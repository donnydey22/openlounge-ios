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
    return ssrcs.withUnsafeBufferPointer { Int(ol_sfu_video_start(ip, Int32(port), txKey, rxKey, $0.baseAddress, Int32($0.count), Int32(pt))) }
  }

  public func camera(on: Bool, facing: String) throws {
    capture.stop()
    guard on else { DispatchQueue.main.async { self.localView?.attach(nil) }; return }
    try capture.start(position: facing == "environment" ? .back : .front, forceH264: true)
    let s = capture.session
    DispatchQueue.main.async { self.localView?.attach(s) }
  }

  public func stop() {
    capture.stop(); ol_sfu_video_set_sink(nil, nil); ol_sfu_video_stop(); decoder?.close(); decoder = nil
    DispatchQueue.main.async { self.remoteView?.layer.contents = nil; self.localView?.attach(nil) }
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

public final class OLLocalVideoView: ExpoView {
  private var preview: AVCaptureVideoPreviewLayer?
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black; clipsToBounds = true
    OLCallVideo.shared.localView = self
    attach(OLCallVideo.shared.capture.session)
  }
  func attach(_ s: AVCaptureSession?) {
    preview?.removeFromSuperlayer(); preview = nil
    guard let s else { return }
    let p = AVCaptureVideoPreviewLayer(session: s); p.videoGravity = .resizeAspectFill; p.frame = bounds
    layer.addSublayer(p); preview = p
  }
  public override func layoutSubviews() { super.layoutSubviews(); preview?.frame = bounds }
}
