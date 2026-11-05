// Durable per-call disk log: each line is appended and fsync'd BEFORE the step it records (audio session change,
// every CallKit callback, page/reload trigger, media setup step), so a process death leaves the last step on disk.
// The tail of the current + previous log is sent once per call over the call socket (call:diag ev "calllog").
// No audio, no keys, no tokens are written.
import Foundation

public final class OLCallDiskLog {
  public static let shared = OLCallDiskLog()
  private let q = DispatchQueue(label: "ol.calllog")
  private let dir: URL
  private var cur: URL
  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    dir = base.appendingPathComponent("calllogs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    cur = dir.appendingPathComponent("current.log")
    write("launch", "pid=\(ProcessInfo.processInfo.processIdentifier)", sync: true)
  }

  public func begin(_ callId: String) {
    q.sync {
      let fm = FileManager.default
      if let a = try? fm.attributesOfItem(atPath: cur.path), ((a[.size] as? NSNumber)?.intValue ?? 0) > 0 {
        try? fm.moveItem(at: cur, to: dir.appendingPathComponent("call-\(Int(Date().timeIntervalSince1970 * 1000)).log"))
      }
      let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("call-") }.sorted(by: >)
      for n in old.dropFirst(20) { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
    }
    mark("call-begin", "callId=\(callId)")
  }

  public func mark(_ ev: String, _ detail: String = "") { write(ev, detail, sync: true) }

  private func write(_ ev: String, _ detail: String, sync: Bool) {
    let line = "\(Int(Date().timeIntervalSince1970 * 1000)) up=\(Int(ProcessInfo.processInfo.systemUptime * 1000)) t=\(Thread.isMainThread ? "main" : "bg") \(ev) \(detail.replacingOccurrences(of: "\n", with: " ").prefix(500))\n"
    q.sync {
      let fm = FileManager.default
      if !fm.fileExists(atPath: cur.path) { fm.createFile(atPath: cur.path, contents: nil) }
      guard let h = try? FileHandle(forWritingTo: cur) else { return }
      defer { try? h.close() }
      _ = try? h.seekToEnd()
      try? h.write(contentsOf: Data(line.utf8))
      try? h.synchronize() // fsync
    }
  }

  /// Last `max` lines of the newest two logs.
  public func tail(_ max: Int = 200) -> [String] {
    q.sync {
      let fm = FileManager.default
      let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".log") }
      let urls = names.map { dir.appendingPathComponent($0) }.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
        ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
      var out: [String] = []
      for u in urls.suffix(2) { if let s = try? String(contentsOf: u, encoding: .utf8) { out += s.split(separator: "\n").map { "\(u.lastPathComponent): \($0)" } } }
      return Array(out.suffix(max))
    }
  }
}
