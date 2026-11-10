// Open Lounge (iOS). Nothing is requested at launch: no microphone, no camera, no audio session.
import OLCallCore
import SwiftUI

@main
struct OpenLoungeApp: App {
    @StateObject private var call = CallController(control: CallControlNotConfigured(), permissions: SystemPermissions())

    var body: some Scene {
        WindowGroup {
            RootView(call: call)
        }
    }
}

struct RootView: View {
    @ObservedObject var call: CallController
    @State private var peerId = ""

    var body: some View {
        ZStack {
            OLColor.stage.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Open Lounge")
                    .font(.system(size: OLMetric.nameSize, weight: .semibold))
                    .foregroundColor(.white)
                TextField("Member id", text: $peerId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, OLMetric.horizontalPadding)
                HStack(spacing: OLMetric.cardButtonGap) {
                    RoundButton(label: "Audio", enabled: !peerId.isEmpty) {
                        call.startCall(peerId: peerId, name: peerId, photo: nil, video: false)
                    }
                    RoundButton(label: "Video", enabled: !peerId.isEmpty) {
                        call.startCall(peerId: peerId, name: peerId, photo: nil, video: true)
                    }
                }
            }
            switch call.phase {
            case .idle: EmptyView()
            case .incoming: IncomingCallScreen(call: call)
            case .waiting, .connecting, .active, .ended: CallScreen(call: call)
            }
        }
        .preferredColorScheme(.dark)
    }
}
