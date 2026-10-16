// SPDX-License-Identifier: MIT
import Foundation

/// G62（spec §6.4）: 一覧の「行の信号」。本ごとに、中身が最後に変わった版を記録する。
/// 受け手（リストの表）は自分が前に見た `contentVersion` より後に変わった本だけを描き直す。
/// 配列そのものを作り直したとき（構造の版が変わったとき）は `reset()` で記録を空にする（版は戻さない）。
public struct BookListChanges: Sendable, Equatable {
    /// 記録するたびに 1 つ進む。戻らない。
    public private(set) var contentVersion = 0
    private var lastChanged: [Int: Int] = [:]

    public init() {}

    /// `ids` の本の中身が変わった。空なら何もしない（版を進めない）。
    public mutating func markContent(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        contentVersion += 1
        for id in ids { lastChanged[id] = contentVersion }
    }

    /// 記録を空にする（構造の変化のとき）。`contentVersion` は戻さない。
    public mutating func reset() {
        lastChanged.removeAll()
    }

    /// `version` より後に中身が変わった本。
    public func changed(since version: Int) -> Set<Int> {
        Set(lastChanged.lazy.filter { $0.value > version }.map(\.key))
    }
}
