// Call video on the ONE media path (RingRTC session model): camera → RTCCameraVideoCapturer → RTCVideoTrack on the
// same RTCPeerConnection as audio (OLRtcCall). Remote video = the PC's video receiver track. Replaces the PJSIP
// SIP-era SFU video / VideoToolbox fan-out path (deleted). BSD WebRTC M152; no RingRTC binary.
import ExpoModulesCore
import UIKit
#if canImport(WebRTC)
import WebRTC
#endif

public final class OLRtcVideo {
  public static let shared = OLRtcVideo()
  /// (callId, localOn, remoteOn) → OLCallManager emits {type:"video"} to the JS call screen
  public var onVideo: ((String, Bool, Bool) -> Void)?
  weak var localView: OLLocalVideoView? { didSet { attachLocal() } }
  weak var remoteView: OLRemoteVideoView? { didSet { attachRemote() } }
  private(set) var localOn = false, remoteOn = false
  var callId: String?
  #if canImport(WebRTC)
  private var source: RTCVideoSource?
  private var capturer: RTCCameraVideoCapturer?
  public private(set) var localTrack: RTCVideoTrack?
  private var remoteTrack: RTCVideoTrack?

  /// Created once per call before the PC offers/answers so the video m-line exists from the first negotiation.
  func makeTrack(_ factory: RTCPeerConnectionFactory) -> RTCVideoTrack {
    if let t = localTrack { return t }
    let s = factory.videoSource()
    source = s; capturer = RTCCameraVideoCapturer(delegate: s)
    let t = factory.videoTrack(with: s, trackId: "ol-video0")
    t.isEnabled = false
    localTrack = t
    attachLocal()
    return t
  }

  func setRemote(_ t: RTCVideoTrack?) {
    if let old = remoteTrack, let v = remoteView?.renderer { old.remove(v) }
    remoteTrack = t
    remoteOn = t != nil
    attachRemote(); emit()
  }

  private func attachLocal() { if let t = localTrack, let v = localView?.renderer { t.add(v) } }
  private func attachRemote() { if let t = remoteTrack, let v = remoteView?.renderer { t.add(v) } }
  #endif

  /// Camera on/off (the only camera owner during calls). Throws when no camera / not linked.
  public func camera(on: Bool, facing: String) throws {
    #if canImport(WebRTC)
    guard let cap = capturer, let track = localTrack else { throw NSError(domain: "OLRtcVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "no call video track"]) }
    if !on { cap.stopCapture(); track.isEnabled = false; localOn = false; emit(); return }
    let pos: AVCaptureDevice.Position = facing == "environment" ? .back : .front
    guard let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == pos }) ?? RTCCameraVideoCapturer.captureDevices().first else {
      throw NSError(domain: "OLRtcVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "no camera"])
    }
    // 720p-class format closest to 1280x720, ≤30 fps (WebRTC adapts resolution/bitrate under congestion itself)
    let fmt = RTCCameraVideoCapturer.supportedFormats(for: dev).min { a, b in
      let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
      return abs(Int(da.width) - 1280) + abs(Int(da.height) - 720) < abs(Int(db.width) - 1280) + abs(Int(db.height) - 720)
    }
    guard let fmt else { throw NSError(domain: "OLRtcVideo", code: 3, userInfo: [NSLocalizedDescriptionKey: "no camera format"]) }
    let fps = Int(min(30, fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
    cap.startCapture(with: dev, format: fmt, fps: fps)
    track.isEnabled = true; localOn = true
    localView?.mirrored = pos == .front
    emit()
    #else
    throw NSError(domain: "OLRtcVideo", code: 9, userInfo: [NSLocalizedDescriptionKey: "webrtc_not_linked"])
    #endif
  }

  func end() {
    #if canImport(WebRTC)
    capturer?.stopCapture(); capturer = nil; source = nil
    if let v = localView?.renderer { localTrack?.remove(v) }
    if let v = remoteView?.renderer { remoteTrack?.remove(v) }
    localTrack = nil; remoteTrack = nil
    #endif
    let was = localOn || remoteOn
    localOn = false; remoteOn = false
    if was { emit() }
    callId = nil
  }

  private func emit() { if let id = callId { onVideo?(id, localOn, remoteOn) } }
}

/// Remote video (Expo view placed by the JS call screen).
public final class OLRemoteVideoView: ExpoView {
  #if canImport(WebRTC)
  let renderer = RTCMTLVideoView()
  #else
  let renderer: UIView? = nil
  #endif
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black; clipsToBounds = true
    #if canImport(WebRTC)
    renderer.videoContentMode = .scaleAspectFill; addSubview(renderer)
    #endif
    OLRtcVideo.shared.remoteView = self
  }
  public override func layoutSubviews() {
    super.layoutSubviews()
    #if canImport(WebRTC)
    renderer.frame = bounds
    #endif
  }
}

/// Local self-view of the call's capture track.
public final class OLLocalVideoView: ExpoView {
  #if canImport(WebRTC)
  let renderer = RTCMTLVideoView()
  #else
  let renderer: UIView? = nil
  #endif
  var mirrored = true { didSet { applyMirror() } }
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black; clipsToBounds = true
    #if canImport(WebRTC)
    renderer.videoContentMode = .scaleAspectFill; addSubview(renderer)
    #endif
    applyMirror()
    OLRtcVideo.shared.localView = self
  }
  private func applyMirror() {
    #if canImport(WebRTC)
    renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    #endif
  }
  public override func layoutSubviews() {
    super.layoutSubviews()
    #if canImport(WebRTC)
    renderer.frame = bounds
    #endif
  }
}
