// SPDX-License-Identifier: MIT
import Foundation
import Synchronization

/// G62（spec §6.1）: 配信中の書庫の一覧（スナップショット）。App が開く・閉じる・名前・共有・施錠の変化のたびに
/// MainActor 上で丸ごと差し替え、サーバのリクエストは読むだけにする（MainActor を待たない）。部分的な更新はしない。
/// 1 つのリクエストはこれを 1 回だけ読み、その中の 1 件を使う。施錠の判定には使わない（DB を読む・§6.2）。
public final class ServedLibraryDirectory: Sendable {
    public struct Entry: Sendable {
        public let library: ServedLibrary
        /// 共有サーバに出してよいか（`remoteSharingEnabled`）。ローカルコントロールはこれを見ない。
        public let sharedRemotely: Bool

        public init(library: ServedLibrary, sharedRemotely: Bool) {
            self.library = library
            self.sharedRemotely = sharedRemotely
        }
    }

    private let entries = Mutex<[Entry]>([])

    public init() {}

    /// 一覧を丸ごと差し替える。
    public func replace(_ newEntries: [Entry]) {
        entries.withLock { $0 = newEntries }
    }

    /// 今の一覧。
    public func current() -> [Entry] {
        entries.withLock { $0 }
    }

    /// 配信する書庫。`sharedRemotelyOnly` なら共有を許した書庫だけ（共有サーバ用）。
    public func libraries(sharedRemotelyOnly: Bool) -> [ServedLibrary] {
        current().compactMap { (!sharedRemotelyOnly || $0.sharedRemotely) ? $0.library : nil }
    }
}
