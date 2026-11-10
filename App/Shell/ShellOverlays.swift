// Native covers over the page: launch wordmark, offline, App Lock, and the call screens.
import OLShellCore
import SwiftUI

enum ShellColor {
    static let dark = UIColor(red: 0x0b / 255, green: 0x0b / 255, blue: 0x0d / 255, alpha: 1)
    static let light = UIColor(red: 0xf4 / 255, green: 0xf3 / 255, blue: 0xee / 255, alpha: 1)
    static let launch = UIColor(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1)
    static let accent = Color(red: 0xF2 / 255, green: 0xB3 / 255, blue: 0x66 / 255)
}

struct LaunchCover: View {
    let light: Bool
    var body: some View {
        ZStack {
            Color(light ? ShellColor.light : ShellColor.launch).ignoresSafeArea()
            Text("Open Lounge")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundColor(light ? Color(white: 0.11) : .white)
        }
        .accessibilityHidden(true)
    }
}

struct OfflineCover: View {
    let light: Bool
    let retry: () -> Void
    var body: some View {
        let text = light ? Color(white: 0.11) : Color.white
        let muted = light ? Color(white: 0.42) : Color(white: 0.63)
        ZStack {
            Color(light ? ShellColor.light : ShellColor.dark).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Can’t reach Open Lounge right now").font(.system(size: 20, weight: .semibold)).foregroundColor(text)
                    .multilineTextAlignment(.center)
                Text("We’ll keep trying — check your connection.").font(.system(size: 15)).foregroundColor(muted)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ProgressView().tint(muted)
                    Text("Reconnecting…").font(.system(size: 13)).foregroundColor(muted)
                }
                .padding(.top, 8)
                Button(action: retry) {
                    Text("Try now").font(.system(size: 16, weight: .semibold)).foregroundColor(ShellColor.accent)
                }
                .padding(.top, 8)
            }
            .padding(32)
        }
    }
}

struct LockCover: View {
    let showActions: Bool
    let failed: Bool
    let unlock: () -> Void
    let otherWay: () -> Void
    var body: some View {
        ZStack {
            Color(ShellColor.dark).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("🎙️ Open Lounge").font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                Text(failed ? "Couldn’t verify it’s you. Try again or use your passcode." : "Open Lounge is locked")
                    .font(.system(size: 15)).foregroundColor(Color(white: 0.63)).multilineTextAlignment(.center)
                if showActions {
                    Button(action: unlock) {
                        Text("Unlock").font(.system(size: 16, weight: .semibold)).foregroundColor(Color(white: 0.11))
                            .padding(.horizontal, 32).padding(.vertical, 12)
                            .background(ShellColor.accent).clipShape(Capsule())
                    }
                    Button(action: otherWay) { Text("Use another way").font(.system(size: 15)).foregroundColor(ShellColor.accent) }
                }
            }
            .padding(32)
        }
    }
}

/// Call screens over everything (incoming is the first full-screen UI, also over App Lock).
struct CallLayer: View {
    @ObservedObject var call: CallController
    var body: some View {
        ZStack {
            if call.visible && call.minimized {
                MiniBar(call: call).transition(.move(edge: .top))
            } else if call.visible {
                CallScreen(call: call).transition(.opacity)
            }
            if call.incomingVisible { IncomingCallScreen(call: call).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: call.visible)
        .animation(.easeInOut(duration: 0.2), value: call.incomingVisible)
        .animation(.easeInOut(duration: 0.2), value: call.minimized)
    }
}
