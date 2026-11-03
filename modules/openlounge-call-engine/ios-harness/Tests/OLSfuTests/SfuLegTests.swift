import XCTest
import OLSfu
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
      ol_harness_stats(&rx, &lost, &tx, &lv); ol_harness_stop()
      json = "{\"rxPkt\":\(rx),\"rxLost\":\(lost),\"txPkt\":\(tx),\"avgLevel\":\(n > 0 ? Double(sum) / Double(n) : 0),\"maxLevel\":\(mx)}"
    }
    try json.write(toFile: out, atomically: true, encoding: .utf8)
    XCTAssertEqual(r, 0)
  }
}
