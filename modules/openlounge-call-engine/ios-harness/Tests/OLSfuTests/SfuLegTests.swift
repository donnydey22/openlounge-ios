import XCTest
import OLSfu
import OLVideo
import CoreVideo
import CoreMedia
import VideoToolbox
/// Params arrive as TEST_RUNNER_OL_* env (xcodebuild strips the prefix) from tests/pjsip-matrix/run-phone.mjs PHONE=ios.
final class SfuLegTests: XCTestCase {
  func testAudioLeg() throws {
    let e = ProcessInfo.processInfo.environment
    guard let ip = e["OL_IP"], let out = e["OL_OUT"] else { throw XCTSkip("not invoked by matrix runner") }
    XCTAssertEqual(ol_harness_init(), 0)
    let r = ol_harness_start(ip, Int32(e["OL_PORT"]!)!, e["OL_TX"]!, e["OL_RX"]!, UInt32(e["OL_SSRC"]!)!, Int32(e["OL_TXPT"]!)!, Int32(e["OL_RXPT"]!)!)
    var json = "{\"error\":\(r)}"
    if r == 0 {
      let secs = Int(e["OL_SECONDS"]!)!; var sum = 0, n = 0, mx: Int32 = 0; var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0, lv: Int32 = 0
      for i in 0..<(secs * 10) { Thread.sleep(forTimeInterval: 0.1); ol_harness_stats(&rx, &lost, &tx, &lv); if i > 20 { sum += Int(lv); n += 1; mx = max(mx, lv) } }
      ol_harness_stats(&rx, &lost, &tx, &lv)
      var rb0: Int32 = 0, rb1: Int32 = 0; var jd: UInt32 = 0, jl: UInt32 = 0, je: UInt32 = 0, ja: UInt32 = 0, rd: UInt32 = 0
      _ = ol_sfu_diag(&rb0, &rb1, &jd, &jl, &je, &ja, &rd); ol_harness_stop()
      let diag = "{\"rcvbuf0\":\(rb0),\"rcvbuf1\":\(rb1),\"jbDiscard\":\(jd),\"jbLost\":\(jl),\"jbEmpty\":\(je),\"jbAvgMs\":\(ja),\"rxDiscard\":\(rd)}"
      json = "{\"rxPkt\":\(rx),\"rxLost\":\(lost),\"txPkt\":\(tx),\"avgLevel\":\(n > 0 ? Double(sum) / Double(n) : 0),\"maxLevel\":\(mx),\"diag\":\(diag)}"
    }
    try json.write(toFile: out, atomically: true, encoding: .utf8)
    XCTAssertEqual(r, 0)
  }

  /// Video spec v2 cell leg: audio (tone) + video on its own transport. Sends a synthetic moving 1280x720 420v source
  /// through the PRODUCT encoder (OLSimulcastEncoder: HW-only VideoToolbox, 3 layers) and HW-decodes what the SFU forwards.
  func testVideoLeg() throws {
    let e = ProcessInfo.processInfo.environment
    guard let ip = e["OL_IP"], let out = e["OL_OUT"], let vip = e["OL_VIP"] else { throw XCTSkip("not invoked by matrix runner") }
    XCTAssertEqual(ol_harness_init(), 0)
    let r = ol_harness_start(ip, Int32(e["OL_PORT"]!)!, e["OL_TX"]!, e["OL_RX"]!, UInt32(e["OL_SSRC"]!)!, Int32(e["OL_TXPT"]!)!, Int32(e["OL_RXPT"]!)!)
    let ssrcs = e["OL_VSSRCS"]!.split(separator: ",").map { UInt32($0)! }
    let dec = OLVideoDecoder()
    let sink: ol_video_sink_cb = { user, au, len, _, _ in
      guard let user, let au else { return }
      Unmanaged<OLVideoDecoder>.fromOpaque(user).takeUnretainedValue().decode(annexB: Data(bytes: au, count: Int(len))) }
    ol_sfu_video_set_sink(sink, Unmanaged.passUnretained(dec).toOpaque())
    let vr = ssrcs.withUnsafeBufferPointer { ol_sfu_video_start(vip, Int32(e["OL_VPORT"]!)!, e["OL_VTX"]!, e["OL_VRX"]!, $0.baseAddress, Int32($0.count), Int32(e["OL_VPT"]!)!) }
    var videoError = "null", codec = "none"; var enc: OLSimulcastEncoder?
    do { let x = try OLSimulcastEncoder(); enc = x; codec = x.codec == kCMVideoCodecType_AV1 ? "AV1" : "H264" } catch { videoError = "\"\(error)\"" }
    enc?.onAnnexB = { layer, au, key, ts in au.withUnsafeBytes { _ = ol_sfu_video_send(Int32(layer), $0.bindMemory(to: UInt8.self).baseAddress, Int32(au.count), ts, key ? 1 : 0) } }
    var json = "{\"error\":\(r),\"videoError\":\(vr != 0 ? "\(vr)" : videoError)}"
    if r == 0 && vr == 0 {
      let secs = Int(e["OL_SECONDS"]!)!; var sum = 0, n = 0, mx: Int32 = 0; var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0, lv: Int32 = 0
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 720, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
      let t0 = Date(); var frame = 0
      while Date().timeIntervalSince(t0) < Double(secs) {
        if let pool, let enc { var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
          if let pb { CVPixelBufferLockBaseAddress(pb, []); let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), yb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<720 { memset(y + row * yb, Int32(40 + (row + frame * 4) % 180), 1280) }
            let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!; memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * 360)
            CVPixelBufferUnlockBaseAddress(pb, []); if ol_sfu_video_take_keyreq() != 0 { enc.forceKeyframe() }; enc.encode(pb, pts: CMTime(value: CMTimeValue(frame), timescale: 30)) } }
        frame += 1
        if frame % 3 == 0 { ol_harness_stats(&rx, &lost, &tx, &lv); if Date().timeIntervalSince(t0) > 2 { sum += Int(lv); n += 1; mx = max(mx, lv) } }
        let next = t0.addingTimeInterval(Double(frame) / 30); let d = next.timeIntervalSinceNow; if d > 0 { Thread.sleep(forTimeInterval: d) }
      }
      enc?.teardown()
      ol_harness_stats(&rx, &lost, &tx, &lv)
      var vrp: UInt32 = 0, va: UInt32 = 0, vk: UInt32 = 0, vg: UInt32 = 0, vtp: UInt32 = 0; var ta: [UInt32] = [0, 0, 0], tk: [UInt32] = [0, 0, 0]
      ol_sfu_video_stats(&vrp, &va, &vk, &vg, &vtp, &ta, &tk)
      ol_sfu_video_stop(); ol_sfu_video_set_sink(nil, nil); let ds = dec.stats; dec.close(); ol_harness_stop()
      let decFps = ds.firstAt.map { Double(ds.decoded) / max(0.5, Date().timeIntervalSince($0)) } ?? 0
      json = "{\"rxPkt\":\(rx),\"rxLost\":\(lost),\"txPkt\":\(tx),\"avgLevel\":\(n > 0 ? Double(sum) / Double(n) : 0),\"maxLevel\":\(mx),\"codec\":\"\(codec)\",\"videoError\":\(videoError),\"vRxPkt\":\(vrp),\"rxAu\":\(va),\"rxKey\":\(vk),\"rxGap\":\(vg),\"vTxPkt\":\(vtp),\"txAu\":\(ta),\"txKey\":\(tk),\"decoded\":\(ds.decoded),\"decFps\":\(decFps),\"decErr\":\(ds.errors),\"nonBlack\":\(ds.nonBlack),\"srcFrames\":\(frame)}"
    } else { ol_sfu_video_stop(); ol_harness_stop() }
    try json.write(toFile: out, atomically: true, encoding: .utf8)
    XCTAssertEqual(r, 0); XCTAssertEqual(vr, 0)
  }
}
