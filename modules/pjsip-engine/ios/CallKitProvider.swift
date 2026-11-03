// Speakerbox pattern. CallKit ring screen only. Nothing here touches setActive.
import CallKit
import AVFoundation

final class CallKitProvider: NSObject, CXProviderDelegate {
  static let shared = CallKitProvider()
  private let provider: CXProvider
  private static func makeConfig() -> CXProviderConfiguration {
    let c = CXProviderConfiguration()
    c.supportsVideo = true; c.maximumCallsPerCallGroup = 1; c.supportedHandleTypes = [.generic]
    return c
  }
  override init() { provider = CXProvider(configuration: Self.makeConfig()); super.init(); provider.setDelegate(self, queue: nil) }

  func reportIncoming(uuid: UUID, handle: String, video: Bool, completion: @escaping (Error?) -> Void) {
    provider.configuration = Self.makeConfig()          // setConfiguration before EVERY report
    let u = CXCallUpdate(); u.remoteHandle = CXHandle(type: .generic, value: handle); u.hasVideo = video
    provider.reportNewIncomingCall(with: uuid, update: u, completion: completion)
  }

  func providerDidReset(_ provider: CXProvider) { PJSIPEngine.shared.teardown() }
  func provider(_ p: CXProvider, perform a: CXAnswerCallAction) { /* send call.answer SDP via WS */ a.fulfill() }
  func provider(_ p: CXProvider, perform a: CXStartCallAction) { /* send call.invite SDP via WS */ a.fulfill() }
  func provider(_ p: CXProvider, perform a: CXEndCallAction) { PJSIPEngine.shared.teardown(); a.fulfill() }
  func provider(_ p: CXProvider, didActivate s: AVAudioSession) { PJSIPEngine.shared.audioSessionDidActivate(s) }
  func provider(_ p: CXProvider, didDeactivate s: AVAudioSession) { PJSIPEngine.shared.audioSessionDidDeactivate(); PJSIPEngine.shared.teardown() }
}
