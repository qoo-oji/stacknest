// SPDX-License-Identifier: MIT
import Foundation

/// リモートキャッシュの上限/TTL（app-global・UserDefaults）。無制限=0 / TTL 無効=0。
enum RemoteCacheSettings {
    static let limitKey = "remote_cache_limit_bytes"
    static let maxAgeKey = "remote_cache_max_age_seconds"
    static let defaultLimit: Int64 = 2 * 1024 * 1024 * 1024      // 2GB
    static let defaultMaxAge: Int64 = 30 * 24 * 3600            // 30日

    static func limitBytes(_ d: UserDefaults = .standard) -> Int64 {
        d.object(forKey: limitKey) == nil ? defaultLimit : Int64(d.integer(forKey: limitKey))
    }
    static func setLimitBytes(_ v: Int64, _ d: UserDefaults = .standard) { d.set(Int(v), forKey: limitKey) }
    static func maxAgeSeconds(_ d: UserDefaults = .standard) -> Int64 {
        d.object(forKey: maxAgeKey) == nil ? defaultMaxAge : Int64(d.integer(forKey: maxAgeKey))
    }
    static func setMaxAgeSeconds(_ v: Int64, _ d: UserDefaults = .standard) { d.set(Int(v), forKey: maxAgeKey) }

    static let wholeBookPrefetchKey = "remote_prefetch_whole_book"
    static func wholeBookPrefetch(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: wholeBookPrefetchKey) }  // 既定 false
    static func setWholeBookPrefetch(_ v: Bool, _ d: UserDefaults = .standard) {
        d.set(v, forKey: wholeBookPrefetchKey)
        // G60 §5.9: 中継の先読み（127.0.0.1 の口）に知らせる。先読み係は取るページを選ぶたびに設定を読むが、
        // 近傍を取り終えて止まっているときに ON にされたことは、この知らせでしか分からない。
        // 内蔵ビューアはページを移るたびに読み直すので、知らせは要らない。
        NotificationCenter.default.post(name: .remoteWholeBookPrefetchDidChange, object: nil)
    }
}

extension Notification.Name {
    /// G60 §5.9: 「開いた本を全ページ先読みする」が切り替わった（`LocalControlController` が中継の先読みへ伝える）。
    static let remoteWholeBookPrefetchDidChange = Notification.Name("app.shelfsmith.stacknest.remoteWholeBookPrefetchDidChange")
}
