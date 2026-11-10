// Hosts an engine video view (UIKit) inside SwiftUI.
import SwiftUI
import UIKit

struct VideoSurface: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        host.clipsToBounds = true
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
    }
}
