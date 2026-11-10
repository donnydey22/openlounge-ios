// OLVideoView — the stable container the call screen shows for one video track (remote or local preview).
//
//   * Upright: tgcalls' VideoMetalView draws the raw camera buffer and reports the frame rotation through
//     setOnOrientationUpdated; this container applies that rotation (Telegram's call UI does the same).
//     The local preview's buffers arrive landscape with rotation 90 in portrait, which is why it showed sideways.
//   * Frame counter: rendered frames are counted on the main thread (display link reading the view's
//     last-frame timestamp), for the 5 s video stats and the frozen-frame watchdog (OLVideoWatchdog).
//   * Re-attach: `setContent` swaps in a fresh engine view without the UI seeing a new view.
import ObjectiveC
import OLCallCore
import TgVoipWebrtc
import UIKit

public final class OLVideoView: UIView {
    public private(set) var orientation = 0
    /// The engine draws this view mirrored (front camera preview; tgcalls sets it per frame). For the UI to read.
    public private(set) var isMirrored = false
    /// main thread: frames rendered since the last `takeFrames()`
    private var frames = 0
    private var lastNs: Int64 = 0
    private var content: UIView?
    private var link: CADisplayLink?
    private var tsOffset: Int?
    /// main thread: (orientation 0...3, aspect)
    public var onOrientation: ((Int) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    /// Main thread.
    public func setContent(_ v: UIView) {
        content?.removeFromSuperview()
        content = v
        tsOffset = Self.timestampOffset(v)
        lastNs = 0
        addSubview(v)
        if let vv = v as? OngoingCallThreadLocalContextWebrtcVideoView {
            apply(Int(vv.orientation.rawValue))
            vv.setOnOrientationUpdated { [weak self, weak v] o, _ in
                DispatchQueue.main.async {
                    guard let self, let v, v === self.content else { return }
                    self.apply(Int(o.rawValue))
                }
            }
            vv.setOnIsMirroredUpdated { [weak self, weak v] m in
                DispatchQueue.main.async {
                    guard let self, let v, v === self.content else { return }
                    self.isMirrored = m
                }
            }
        }
        setNeedsLayout()
        startLink()
    }

    /// Main thread: frames rendered since the previous call.
    public func takeFrames() -> Int { defer { frames = 0 }; return frames }

    private func apply(_ o: Int) {
        guard o != orientation else { return }
        orientation = o
        setNeedsLayout()
        onOrientation?(o)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let v = content else { return }
        let (w, h) = OLVideoRotation.contentSize(container: Double(bounds.width), Double(bounds.height), orientation: orientation)
        v.transform = .identity
        v.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        v.center = CGPoint(x: bounds.midX, y: bounds.midY)
        v.transform = CGAffineTransform(rotationAngle: CGFloat(OLVideoRotation.angle(orientation)))
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { link?.invalidate(); link = nil } else { startLink() }
    }

    deinit { link?.invalidate() }

    private func startLink() {
        guard link == nil, window != nil, tsOffset != nil else { return }
        let l = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.step))
        l.preferredFramesPerSecond = 30
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate func step() {
        guard let v = content, let off = tsOffset else { return }
        let ns = Unmanaged.passUnretained(v).toOpaque().advanced(by: off).load(as: Int64.self)
        if ns != lastNs { lastNs = ns; frames += 1 }
    }

    /// Byte offset of VideoMetalView's `_lastFrameTimeNs` (int64, written on the main thread per rendered
    /// frame). nil if the ivar is not there (another renderer class): then frames are simply not counted.
    static func timestampOffset(_ v: UIView) -> Int? {
        var cls: AnyClass? = type(of: v)
        while let c = cls {
            if let iv = class_getInstanceVariable(c, "_lastFrameTimeNs"),
               let enc = ivar_getTypeEncoding(iv), String(cString: enc) == "q" || String(cString: enc) == "Q" {
                return ivar_getOffset(iv)
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }
}

/// Breaks the CADisplayLink -> target retain cycle.
private final class LinkTarget: NSObject {
    weak var view: OLVideoView?
    init(_ v: OLVideoView) { view = v }
    @objc func step() { view?.step() }
}
