// Sole AVAudioSession owner for Open Lounge calling (Linphone-spec behavior; no GPL paste).
// Exactly one object may setCategory / overrideOutputAudioPort / setPreferred*.
// Holder stack: a live `.call` holder cannot be displaced by rooms / voice notes / ambient UI.
import AVFoundation

public enum OLAudioHolderKind: Equatable {
  case call
  case room
  case voiceNote
  case ambient
}

public struct OLAudioHolderToken: Hashable {
  fileprivate let id: UInt64
}

public final class OLAudioSessionOwner {
  public static let shared = OLAudioSessionOwner()

  private struct Entry {
    let token: OLAudioHolderToken
    let kind: OLAudioHolderKind
  }

  private var stack: [Entry] = []
  private var nextId: UInt64 = 1
  private var callToken: OLAudioHolderToken?

  /// Push a holder. A non-call holder is refused while a call holder is active.
  @discardableResult
  public func push(_ kind: OLAudioHolderKind) -> OLAudioHolderToken? {
    assert(Thread.isMainThread)
    if kind != .call, stack.contains(where: { $0.kind == .call }) {
      NSLog("[OLAudio] refuse push %@ while call held", String(describing: kind))
      return nil
    }
    let tok = OLAudioHolderToken(id: nextId); nextId += 1
    stack.append(Entry(token: tok, kind: kind))
    if kind == .call { callToken = tok }
    return tok
  }

  public func pop(_ token: OLAudioHolderToken?) {
    assert(Thread.isMainThread)
    guard let token else { return }
    stack.removeAll { $0.token == token }
    if callToken == token { callToken = nil }
  }

  public var hasCallHolder: Bool { stack.contains { $0.kind == .call } }

  /// Configure call session BEFORE CallKit activation. Never setActive here.
  public func configureForCall(speakerWanted: Bool) {
    assert(Thread.isMainThread)
    let s = AVAudioSession.sharedInstance()
    // Linphone call mode: playAndRecord + voiceChat + HFP only (no mixWithOthers / A2DP / defaultToSpeaker / videoChat).
    let opts: AVAudioSession.CategoryOptions = [.allowBluetooth]
    do {
      if s.category != .playAndRecord || s.mode != .voiceChat || s.categoryOptions != opts {
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
      }
    } catch {
      NSLog("[OLAudio] setCategory failed: %@", error.localizedDescription)
    }
    if s.preferredSampleRate != 48_000 { try? s.setPreferredSampleRate(48_000) }
    if abs(s.preferredIOBufferDuration - 0.01) > 0.0005 { try? s.setPreferredIOBufferDuration(0.01) }
    // Route override only after activation — pre-activate override fails; applyRoute is called from didActivate.
    _ = speakerWanted
  }

  /// Apply speaker/earpiece AFTER didActivate (and on device route changes).
  public func applyRoute(speakerWanted: Bool, headsetAttached: Bool) {
    assert(Thread.isMainThread)
    let s = AVAudioSession.sharedInstance()
    let wantSpeaker = speakerWanted && !headsetAttached
    let onSpeaker = s.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    guard wantSpeaker != onSpeaker else { return }
    do {
      try s.overrideOutputAudioPort(wantSpeaker ? .speaker : .none)
    } catch {
      NSLog("[OLAudio] route override failed: %@", error.localizedDescription)
    }
  }

  /// Linphone exception path only: mediaServicesWereReset while CallKit still holds the call.
  public func forceReactivateIfInactive() {
    assert(Thread.isMainThread)
    guard hasCallHolder else { return }
    let s = AVAudioSession.sharedInstance()
    // Prefer not to setActive; only if session reports inactive under a live call holder.
    if !s.isOtherAudioPlaying {
      do { try s.setActive(true, options: []) }
      catch { NSLog("[OLAudio] forceReactivate failed: %@", error.localizedDescription) }
    }
  }
}
