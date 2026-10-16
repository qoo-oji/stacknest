// SPDX-License-Identifier: MIT
import Foundation
import OSLog

/// G62（spec §7.1-3）: 一覧の更新の計測点。`log stream --level info --predicate 'subsystem == "app.shelfsmith.stacknest" AND category == "ListUpdate"'`
/// で拾う。Instruments では同じ subsystem・category の signpost を区間として見られる。
enum ListUpdateLog {
    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ListUpdate")
    static let signposter = OSSignposter(subsystem: "app.shelfsmith.stacknest", category: "ListUpdate")

    /// ログに鍵の中身（検索語・絞り込み）を出さないための短い要約（djb2 の 16 進）。同じ鍵なら同じ値。
    static func digest(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &<< 5) &+ h &+ UInt64(b) }
        return String(h, radix: 16)
    }

    /// 経過時間をミリ秒に。
    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
