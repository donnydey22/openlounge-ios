// Expo native module "OpenLoungeOlcall": the bridge between the EXISTING OL
// React Native call screen (pj-openlounge-ios, modules/openlounge-calls) and
// OLCallSession. JS side: ios/OpenLoungeCalls/js/olcall.ts.
//
// One call at a time (OL is 1:1). Events carry UI state only (no keys, no blobs).
import ExpoModulesCore
import UIKit

public final class OpenLoungeOlcallModule: Module {
    private var session: OLCallSession?
    fileprivate static weak var current: OpenLoungeOlcallModule?
    fileprivate var remoteView: UIView?
    fileprivate var localView: UIView?
    fileprivate var views = NSHashTable<OlcallVideoView>.weakObjects()

    public func definition() -> ModuleDefinition {
        Name("OpenLoungeOlcall")
        Events("onCallState")

        OnCreate { OpenLoungeOlcallModule.current = self }

        AsyncFunction("start") { (url: String, token: String, video: Bool, peerId: String, peerName: String, avatarUrl: String?) in
            guard self.session == nil else { throw OlcallError("a call is already active") }
            guard let u = URL(string: url), u.scheme == "wss" || u.scheme == "ws" else { throw OlcallError("bad server url") }
            let s = try OLCallSession(serverURL: u, joinToken: token,
                                      peer: .init(userId: peerId, displayName: peerName, avatarUrl: avatarUrl), video: video)
            s.onUiState = { [weak self] st in
                guard let self else { return }
                self.sendEvent("onCallState", st.asDictionary(peer: s.peer))
                if st.phase == .ended {
                    self.session = nil
                    self.remoteView = nil
                    self.localView = nil
                    self.refreshViews()
                }
            }
            s.onRemoteVideoView = { [weak self] v in self?.remoteView = v; self?.refreshViews() }
            s.onLocalVideoView = { [weak self] v in self?.localView = v; self?.refreshViews() }
            self.session = s
            s.start()
        }.runOnQueue(.main)

        Function("setMuted") { (muted: Bool) in self.session?.setMuted(muted) }
        Function("setCameraEnabled") { (on: Bool) in self.session?.setCameraEnabled(on) }
        Function("switchCamera") { self.session?.switchCamera() }
        Function("setSpeaker") { (on: Bool) in self.session?.setSpeaker(on) }
        Function("hangup") { self.session?.hangup() }

        View(OlcallVideoView.self) {
            Prop("source") { (view: OlcallVideoView, source: String) in
                view.source = source
                self.views.add(view)
                self.refreshViews()
            }
        }
    }

    fileprivate func refreshViews() {
        DispatchQueue.main.async {
            for v in self.views.allObjects {
                v.show(v.source == "local" ? self.localView : self.remoteView)
            }
        }
    }
}

/// <OlcallVideoView source="remote"|"local" /> — placed by the existing call
/// screen inside its own frame (e.g. the squircle tile for the local preview),
/// so layout, corner radius and avatar fallback stay the screen's own.
public final class OlcallVideoView: ExpoView {
    var source = "remote"
    private weak var hosted: UIView?

    func show(_ v: UIView?) {
        if hosted === v { return }
        hosted?.removeFromSuperview()
        hosted = v
        guard let v else { return }
        v.frame = bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(v)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}

struct OlcallError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
