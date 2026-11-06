// Video spec v2 (Donny Nov 3 6:51 AM, PLAN §14) + iOS fan-out (Nov 5): VideoToolbox HARDWARE H.264 only (no software fallback, no AV1).
// 3 simulcast layers 180p/720p/1080p at
// 150/800/2400 kbps; lowest layer "ultrafast" (speed over quality), others "fast"; keyframe every 2 s.
// The capture session is opened only after CallKit didActivate (OLVideoEncoder.swift: OLVideoCapture).
// This file has no engine/pjproject dependency so the simulator matrix harness compiles the SAME encoder/decoder.
import AVFoundation
import VideoToolbox

public struct OLVideoLayer { public let width: Int32, height: Int32, bps: Int, ultrafast: Bool
  public init(width: Int32, height: Int32, bps: Int, ultrafast: Bool) { self.width = width; self.height = height; self.bps = bps; self.ultrafast = ultrafast } }

public enum OLVideoSpecV2 {
  public static let layers: [OLVideoLayer] = [
    .init(width: 320, height: 180, bps: 150_000, ultrafast: true),
    .init(width: 1280, height: 720, bps: 800_000, ultrafast: false),
    .init(width: 1920, height: 1080, bps: 2_400_000, ultrafast: false),
  ]
  public static let keyframeSeconds = 2
  // kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder (symbol is iOS 17.4+; string key honored earlier)
  static let requireHW = ["RequireHardwareAcceleratedVideoEncoder" as CFString: kCFBooleanTrue!] as CFDictionary
  /// Max frame rate per layer (fan-out pacing; mirrors Android OLCameraFanout per-layer cadence).
  public static func fps(_ l: OLVideoLayer) -> Int { l.ultrafast ? 15 : 30 }

}
public enum OLVideoError: Error { case hardwareEncoderUnavailable(layer: Int, status: OSStatus), notActivated, cameraUnavailable, captureConfig(String) }

/// Three hardware H.264 VTCompressionSessions, one per simulcast layer / SSRC. All three or none: throws (call ends video
/// cleanly) if any layer cannot open, or opens but is not hardware. Each layer is fed its OWN pre-scaled buffer by
/// OLCameraFanout (no 1080p->180p scaling inside the encoder). H.264 only: the AV1 path is removed.
public final class OLSimulcastEncoder {
  public let codec: CMVideoCodecType
  private var sessions: [VTCompressionSession] = []
  public var onEncoded: ((Int, CMSampleBuffer) -> Void)?
  /// Annex-B access unit per layer (SPS/PPS prepended on keyframes), 90 kHz timestamp: feeds ol_sfu_video_send.
  public var onAnnexB: ((_ layer: Int, _ au: Data, _ key: Bool, _ ts90k: UInt32) -> Void)?

  /// `layers` override is for CI only (the simulator encodes in software; 3 layers up to 1080p starve the runner).
  public init(layers override: [OLVideoLayer]? = nil) throws {
    codec = kCMVideoCodecType_H264
    let spec = OLVideoSpecV2.requireHW
    for (i, l) in (override ?? OLVideoSpecV2.layers).enumerated() {
      var s: VTCompressionSession?
      let st = VTCompressionSessionCreate(allocator: nil, width: l.width, height: l.height, codecType: codec, encoderSpecification: spec,
                                          imageBufferAttributes: [kCVPixelBufferWidthKey: Int(l.width), kCVPixelBufferHeightKey: Int(l.height), kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
                                          compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
      guard st == noErr, let s else { teardown(); throw OLVideoError.hardwareEncoderUnavailable(layer: i, status: st) }
      func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
      set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
      set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
      set(kVTCompressionPropertyKey_AverageBitRate, l.bps as CFNumber)
      set(kVTCompressionPropertyKey_DataRateLimits, [l.bps * 3 / 16, 1] as CFArray) // 1.5x avg over 1 s so 2 s IDRs are not starved
      set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, OLVideoSpecV2.keyframeSeconds as CFNumber)
      set(kVTCompressionPropertyKey_ExpectedFrameRate, OLVideoSpecV2.fps(l) as CFNumber)
      set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (OLVideoSpecV2.keyframeSeconds * OLVideoSpecV2.fps(l)) as CFNumber)
      // ultrafast = prioritize speed over quality; fast = realtime without the speed override
      set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, (l.ultrafast ? kCFBooleanTrue : kCFBooleanFalse)!)
      if codec == kCMVideoCodecType_H264 { set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel) }
      var hw: CFBoolean?
      let hq = VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw)
      guard hq == noErr, hw == kCFBooleanTrue else { VTCompressionSessionInvalidate(s); teardown(); throw OLVideoError.hardwareEncoderUnavailable(layer: i, status: hq == noErr ? -1 : hq) }
      guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else { VTCompressionSessionInvalidate(s); teardown(); throw OLVideoError.hardwareEncoderUnavailable(layer: i, status: -2) }
      sessions.append(s)
    }
  }

  public var layerCount: Int { sessions.count }
  /// Local IDR on every layer (capture interruption ended, encoder rebuild). Not throttled.
  public func forceKeyframe() { forceKeyframe(mask: UInt32.max, throttle: false) }
  /// SFU PLI/FIR per SSRC: bit i of `mask` = layer i = SSRC index i (ol_sfu_video.c on_rtcp). Only the requested
  /// layers emit an IDR; each layer honors at most one SFU request per `keyReqMinMs` (mediasoup repeats PLIs on loss
  /// and per consumer; an unthrottled 1080p IDR storm starves the uplink).
  public static let keyReqMinMs: UInt64 = 500
  public func forceKeyframe(mask: UInt32, throttle: Bool = true) {
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock(); defer { lock.unlock() }
    if forceKey.count != sessions.count { forceKey = Array(repeating: false, count: sessions.count); lastKeyReq = Array(repeating: 0, count: sessions.count) }
    for i in 0..<sessions.count where mask & (1 << UInt32(i)) != 0 {
      if throttle, lastKeyReq[i] != 0, now &- lastKeyReq[i] < Self.keyReqMinMs * 1_000_000 { continue }
      lastKeyReq[i] = now; forceKey[i] = true
    }
  }
  private var forceKey: [Bool] = [], lastKeyReq: [UInt64] = []
  /// VideoToolbox invalidated a session (kVTInvalidSessionErr -12903, e.g. after background/foreground). Fired once;
  /// OLVideoCapture rebuilds all three layers (all or fail) and forces an IDR.
  public var onInvalidated: (() -> Void)?
  private var invalidatedFired = false
  private func invalidated() { lock.lock(); let fire = !invalidatedFired; invalidatedFired = true; lock.unlock(); if fire { onInvalidated?() } }
  private let lock = NSLock()
  /// One layer's pre-scaled frame (fan-out target i). Called on the fan-out queue.
  public func encode(layer i: Int, _ pixels: CVPixelBuffer, pts: CMTime) {
    guard i < sessions.count else { return }
    lock.lock(); let key = i < forceKey.count && forceKey[i]; if key { forceKey[i] = false }; lock.unlock()
    let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
    do { let s = sessions[i]
      let est = VTCompressionSessionEncodeFrame(s, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] st, _, sb in
        if st == kVTInvalidSessionErr { self?.invalidated(); return }
        guard st == noErr, let sb, let self else { return }
        self.onEncoded?(i, sb)
        if let cb = self.onAnnexB, let (au, key) = OLAnnexB.from(sb) {
          let pts = CMSampleBufferGetPresentationTimeStamp(sb); cb(i, au, key, UInt32(truncatingIfNeeded: Int64(pts.seconds * 90_000)))
        }
      }
      if est == kVTInvalidSessionErr { invalidated() } else if est != noErr, key { lock.lock(); if i < forceKey.count { forceKey[i] = true }; lock.unlock() } // retry IDR next frame
    }
  }

  public func teardown() { onAnnexB = nil; onEncoded = nil; onInvalidated = nil; for s in sessions { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(s) }; sessions = [] }
  deinit { teardown() }
}


/// AVCC/HVCC-length-prefixed CMSampleBuffer (H.264) -> Annex-B; SPS/PPS from the format description on keyframes.
public enum OLAnnexB {
  static let sc: [UInt8] = [0, 0, 0, 1]
  public static func from(_ sb: CMSampleBuffer) -> (Data, Bool)? {
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
    var key = true
    if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = att.first,
       let notSync = a[kCMSampleAttachmentKey_NotSync] as? Bool { key = !notSync }
    var out = Data()
    if key, let fd = CMSampleBufferGetFormatDescription(sb), CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_H264 {
      var n = 0; CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
      for i in 0..<n { var p: UnsafePointer<UInt8>?; var l = 0
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &l, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
          out.append(contentsOf: sc); out.append(p, count: l) } }
    }
    var total = 0; var ptr: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr) == noErr, let ptr else { return nil }
    let raw = UnsafeRawPointer(ptr); var o = 0
    while o + 4 <= total { let l = Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).bigEndian); o += 4; if l <= 0 || o + l > total { break }
      out.append(contentsOf: sc); out.append(raw.advanced(by: o).assumingMemoryBound(to: UInt8.self), count: l); o += l }
    return out.isEmpty ? nil : (out, key)
  }
}

/// Hardware H.264 decode of Annex-B access units (VTDecompressionSession). Counts frames, decode errors and non-black frames.
public final class OLVideoDecoder {
  private var fd: CMVideoFormatDescription?; private var session: VTDecompressionSession?; private var sps: Data?, pps: Data?
  private let lock = NSLock()
  public private(set) var decoded = 0, errors = 0, nonBlack = 0, firstAt: Date?, width = 0, height = 0
  /// Decoded frame for on-screen rendering (decoder thread).
  public var onFrame: ((CVPixelBuffer) -> Void)?
  public init() {}
  static func nals(_ d: Data) -> [Data] { var out: [Data] = []; let b = [UInt8](d); var starts: [(Int, Int)] = []; var i = 0
    while i + 3 <= b.count { if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append((i, 3)); i += 3 } else if i + 4 <= b.count, b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4 } else { i += 1 } }
    for (k, s) in starts.enumerated() { let a = s.0 + s.1, e = k + 1 < starts.count ? starts[k + 1].0 : b.count; if e > a { out.append(Data(b[a..<e])) } }
    return out }
  public func decode(annexB: Data) {
    var units: [Data] = []
    for n in Self.nals(annexB) where !n.isEmpty { switch n[n.startIndex] & 0x1f { case 7: sps = n; case 8: pps = n; default: units.append(n) } }
    if let sps, let pps, session == nil || needsReset(sps, pps) { makeSession(sps, pps) }
    guard let session, let fd, !units.isEmpty, !annexB.isEmpty else { return }
    var avcc = Data(); for u in units { var l = UInt32(u.count).bigEndian; avcc.append(Data(bytes: &l, count: 4)); avcc.append(u) }
    var bb: CMBlockBuffer?; let len = avcc.count
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &bb) == noErr, let bb else { errors += 1; return }
    _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: len) }
    var sb: CMSampleBuffer?; var sz = len
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sz, sampleBufferOut: &sb) == noErr, let sb else { errors += 1; return }
    let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [weak self] st, _, img, _, _ in
      guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
      guard st == noErr, let img else { self.errors += 1; return }
      self.decoded += 1; if self.firstAt == nil { self.firstAt = Date() }
      self.width = CVPixelBufferGetWidth(img); self.height = CVPixelBufferGetHeight(img)
      if self.decoded % 10 == 1, Self.meanLuma(img) > 16 { self.nonBlack += 1 }
      self.onFrame?(img)
    }
    if st != noErr { lock.lock(); errors += 1; lock.unlock() }
  }
  private var lastSps: Data?, lastPps: Data?
  private func needsReset(_ s: Data, _ p: Data) -> Bool { s != lastSps || p != lastPps }
  private func makeSession(_ s: Data, _ p: Data) {
    if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }; session = nil; lastSps = s; lastPps = p
    var f: CMVideoFormatDescription?
    let st: OSStatus = s.withUnsafeBytes { sp in p.withUnsafeBytes { pp in
      let ptrs = [sp.bindMemory(to: UInt8.self).baseAddress!, pp.bindMemory(to: UInt8.self).baseAddress!]; let sizes = [s.count, p.count]
      return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &f) } }
    guard st == noErr, let f else { errors += 1; return }; fd = f
    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary
    var out: VTDecompressionSession?
    if VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: nil, imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &out) == noErr { session = out } else { errors += 1 }
  }
  static func meanLuma(_ img: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(img, .readOnly); defer { CVPixelBufferUnlockBaseAddress(img, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(img, 0) else { return 0 }
    let w = CVPixelBufferGetWidthOfPlane(img, 0), h = CVPixelBufferGetHeightOfPlane(img, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(img, 0)
    var sum = 0, n = 0; let p = base.assumingMemoryBound(to: UInt8.self)
    for y in stride(from: 0, to: h, by: 8) { for x in stride(from: 0, to: w, by: 8) { sum += Int(p[y * bpr + x]); n += 1 } }
    return n > 0 ? Double(sum) / Double(n) : 0
  }
  public func close() { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }; session = nil }
  public var stats: (decoded: Int, errors: Int, nonBlack: Int, firstAt: Date?) { lock.lock(); defer { lock.unlock() }; return (decoded, errors, nonBlack, firstAt) }
}
