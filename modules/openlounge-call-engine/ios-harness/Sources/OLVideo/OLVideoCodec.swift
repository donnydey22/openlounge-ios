// Video spec v2 (Donny Nov 3 6:51 AM, PLAN §14). iOS: VideoToolbox HARDWARE encoder only (no software fallback),
// AV1 when the device has a hardware AV1 encoder (A17+), else H.264. 3 simulcast layers 180p/720p/1080p at
// 150/800/2400 kbps; lowest layer "ultrafast" (speed over quality), others "fast"; keyframe every 2 s.
// The capture session is opened only after CallKit didActivate (OLVideoEncoder.swift: OLVideoCapture).
// This file has no engine/pjproject dependency so the simulator matrix harness compiles the SAME encoder/decoder.
import AVFoundation
import VideoToolbox

public struct OLVideoLayer { public let width: Int32, height: Int32, bps: Int, ultrafast: Bool }

public enum OLVideoSpecV2 {
  public static let layers: [OLVideoLayer] = [
    .init(width: 320, height: 180, bps: 150_000, ultrafast: true),
    .init(width: 1280, height: 720, bps: 800_000, ultrafast: false),
    .init(width: 1920, height: 1080, bps: 2_400_000, ultrafast: false),
  ]
  public static let keyframeSeconds = 2
  // kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder (symbol is iOS 17.4+; string key honored earlier)
  static let requireHW = ["RequireHardwareAcceleratedVideoEncoder" as CFString: kCFBooleanTrue!] as CFDictionary
  /// AV1 only if VideoToolbox can open a hardware AV1 encoder on this device; never a software encoder.
  public static func hardwareAV1Available() -> Bool {
    var s: VTCompressionSession?
    let spec = OLVideoSpecV2.requireHW
    let ok = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_AV1, encoderSpecification: spec,
                                        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr
    if let s { VTCompressionSessionInvalidate(s) }
    return ok
  }
}

public enum OLVideoError: Error { case hardwareEncoderUnavailable(layer: Int, status: OSStatus), notActivated }

/// Three hardware VTCompressionSessions, one per simulcast layer. Throws (call fails video) if any cannot be hardware.
public final class OLSimulcastEncoder {
  public let codec: CMVideoCodecType
  private var sessions: [VTCompressionSession] = []
  public var onEncoded: ((Int, CMSampleBuffer) -> Void)?
  /// Annex-B access unit per layer (SPS/PPS prepended on keyframes), 90 kHz timestamp: feeds ol_sfu_video_send.
  public var onAnnexB: ((_ layer: Int, _ au: Data, _ key: Bool, _ ts90k: UInt32) -> Void)?

  public init() throws {
    codec = OLVideoSpecV2.hardwareAV1Available() ? kCMVideoCodecType_AV1 : kCMVideoCodecType_H264
    let spec = OLVideoSpecV2.requireHW
    for (i, l) in OLVideoSpecV2.layers.enumerated() {
      var s: VTCompressionSession?
      let st = VTCompressionSessionCreate(allocator: nil, width: l.width, height: l.height, codecType: codec, encoderSpecification: spec,
                                          imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
      guard st == noErr, let s else { teardown(); throw OLVideoError.hardwareEncoderUnavailable(layer: i, status: st) }
      func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
      set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
      set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
      set(kVTCompressionPropertyKey_AverageBitRate, l.bps as CFNumber)
      set(kVTCompressionPropertyKey_DataRateLimits, [l.bps / 8, 1] as CFArray)
      set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, OLVideoSpecV2.keyframeSeconds as CFNumber)
      set(kVTCompressionPropertyKey_ExpectedFrameRate, (l.ultrafast ? 15 : 30) as CFNumber)
      // ultrafast = prioritize speed over quality; fast = realtime without the speed override
      set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, (l.ultrafast ? kCFBooleanTrue : kCFBooleanFalse)!)
      if codec == kCMVideoCodecType_H264 { set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel) }
      VTCompressionSessionPrepareToEncodeFrames(s)
      sessions.append(s)
    }
  }

  public func forceKeyframe() { forceKey = true }
  private var forceKey = false
  public func encode(_ pixels: CVPixelBuffer, pts: CMTime) {
    let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil; forceKey = false
    for (i, s) in sessions.enumerated() {
      VTCompressionSessionEncodeFrame(s, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] st, _, sb in
        guard st == noErr, let sb, let self else { return }
        self.onEncoded?(i, sb)
        if let cb = self.onAnnexB, let (au, key) = OLAnnexB.from(sb) {
          let pts = CMSampleBufferGetPresentationTimeStamp(sb); cb(i, au, key, UInt32(truncatingIfNeeded: Int64(pts.seconds * 90_000)))
        }
      }
    }
  }

  public func teardown() { for s in sessions { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(s) }; sessions = [] }
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
    while o + 4 <= total { let l = Int(raw.load(fromByteOffset: o, as: UInt32.self).bigEndian); o += 4; if l <= 0 || o + l > total { break }
      out.append(contentsOf: sc); out.append(raw.advanced(by: o).assumingMemoryBound(to: UInt8.self), count: l); o += l }
    return out.isEmpty ? nil : (out, key)
  }
}

/// Hardware H.264 decode of Annex-B access units (VTDecompressionSession). Counts frames, decode errors and non-black frames.
public final class OLVideoDecoder {
  private var fd: CMVideoFormatDescription?; private var session: VTDecompressionSession?; private var sps: Data?, pps: Data?
  private let lock = NSLock()
  public private(set) var decoded = 0, errors = 0, nonBlack = 0, firstAt: Date?, width = 0, height = 0
  public init() {}
  static func nals(_ d: Data) -> [Data] { var out: [Data] = []; let b = [UInt8](d); var starts: [(Int, Int)] = []; var i = 0
    while i + 3 <= b.count { if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append((i, 3)); i += 3 } else if i + 4 <= b.count, b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4 } else { i += 1 } }
    for (k, s) in starts.enumerated() { let a = s.0 + s.1, e = k + 1 < starts.count ? starts[k + 1].0 : b.count; if e > a { out.append(Data(b[a..<e])) } }
    return out }
  public func decode(annexB: Data) {
    var units: [Data] = []
    for n in Self.nals(annexB) { switch n[n.startIndex] & 0x1f { case 7: sps = n; case 8: pps = n; default: units.append(n) } }
    if let sps, let pps, session == nil || needsReset(sps, pps) { makeSession(sps, pps) }
    guard let session, let fd, !units.isEmpty else { return }
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
