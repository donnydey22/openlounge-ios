import CallKit
import Foundation
import PushKit

// This local telecom core is derived from the ownership model and CallSession
// shape in expo-callkit-telecom v1.0.1 (MIT, Michael Fairley). Open Lounge
// keeps it local so the app cannot register a second CXProvider or PKPushRegistry.

/// The canonical native record for one Open Lounge CallKit call.
final class OLCallSession {
  let callId: String
  let uuid: UUID
  let incoming: Bool
  var video: Bool
  /// True only for an explicitly server-granted outgoing iPhone native-video call.
  let nativeMedia: Bool
  var answered = false
  var answeredInPage = false
  var connected = false
  var ended = false
  var expiresAt: Date?
  var declineToken: String?
  var callerName = "Open Lounge"
  var expiryTimer: Timer?
  var pollTimer: Timer?

  /// Incoming-report state is held on the canonical CallKit UUID, not per push.
  var reporting = false
  var reported = false
  var reportAttempts = 0
  var reportWatchdog: DispatchWorkItem?
  var reportCompletions: [() -> Void] = []
  var fallbackShown = false
  let signalingAt = Date()

  init(callId: String, uuid: UUID, incoming: Bool, video: Bool, nativeMedia: Bool = false) {
    self.callId = callId
    self.uuid = uuid
    self.incoming = incoming
    self.video = video
    self.nativeMedia = nativeMedia
  }

  func redactedSnapshot() -> String {
    let age = Int(Date().timeIntervalSince(signalingAt) * 1000)
    return "idLen=\(callId.count) incoming=\(incoming ? 1 : 0) answered=\(answered ? 1 : 0) connected=\(connected ? 1 : 0) ended=\(ended ? 1 : 0) report=\(reported ? 1 : 0)/\(reporting ? 1 : 0) ageMs=\(age)"
  }
}

typealias OLCall = OLCallSession

/// The only runtime owner of CallKit and PushKit registration for Open Lounge.
final class OLTelecomRegistration {
  static let shared = OLTelecomRegistration()

  private(set) var provider: CXProvider?
  private(set) var registry: PKPushRegistry?

  private init() {}

  @discardableResult
  func start(providerDelegate: CXProviderDelegate, pushDelegate: PKPushRegistryDelegate) -> CXProvider {
    if let provider { return provider }

    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = true
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = false
    // Bundled as a pod resource and resolved by CallKit from the app bundle.
    configuration.ringtoneSound = "openlounge-incoming.caf"

    let newProvider = CXProvider(configuration: configuration)
    newProvider.setDelegate(providerDelegate, queue: nil)

    let newRegistry = PKPushRegistry(queue: .main)
    newRegistry.delegate = pushDelegate
    newRegistry.desiredPushTypes = [.voIP]

    provider = newProvider
    registry = newRegistry
    NSLog("[OLCalls] telecom core owns one CXProvider + PKPushRegistry")
    return newProvider
  }
}
