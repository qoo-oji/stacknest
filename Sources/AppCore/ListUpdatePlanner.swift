// SPDX-License-Identifier: MIT
import Foundation

/// G62（spec §6.4）: 一覧（NSTableView）をどう更新するか。
public enum ListUpdate: Equatable, Sendable {
    /// 何もしない。
    case unchanged
    /// 並びは同じ。変わった本の行（今の並びの番号）だけを作り直す。
    case reloadRows(IndexSet)
    /// 変わった本を前の並びの番号で外し、新しい並びの番号へ入れ直す（動いたのは変わった本だけ）。
    case reinsert(remove: IndexSet, insert: IndexSet)
    /// 全体を作り直す。
    case full
}

/// G62（spec §6.4）: 表が今出している並び・AppState の並び・変わった本から、表の更新の仕方を決める純粋な関数。
/// 前提が崩れたら（件数が違う・変わった本が多すぎる・変わっていない本どうしの順が違う）`.full` に落ちる（安全側）。
public enum ListUpdatePlanner {
    /// これより多くの本が変わったら、行ごとに直さず全体を作り直す。
    public static let maxChangedRows = 64

    /// - Parameters:
    ///   - displayed: 表が今出している本の ID の並び。
    ///   - current: AppState の今の並び（`sortedDisplayedBooks` の ID）。
    ///   - changed: 表が前に見た後で中身が変わった本（一覧に居ない本が混じってよい）。
    ///   - structureChanged: 構造の版（`sortedDisplayedBooksVersion`）が変わったか。
    public static func plan(displayed: [Int], current: [Int], changed: Set<Int>, structureChanged: Bool) -> ListUpdate {
        if structureChanged || displayed.count != current.count { return .full }
        var oldRows = IndexSet()
        var newRows = IndexSet()
        if !changed.isEmpty {
            for (row, id) in displayed.enumerated() where changed.contains(id) { oldRows.insert(row) }
            for (row, id) in current.enumerated() where changed.contains(id) { newRows.insert(row) }
        }
        if oldRows.isEmpty && newRows.isEmpty { return displayed == current ? .unchanged : .full }
        if oldRows.count != newRows.count || newRows.count > maxChangedRows { return .full }
        if displayed == current { return .reloadRows(newRows) }
        let restOld = displayed.enumerated().lazy.filter { !oldRows.contains($0.offset) }.map(\.element)
        let restNew = current.enumerated().lazy.filter { !newRows.contains($0.offset) }.map(\.element)
        guard restOld.elementsEqual(restNew) else { return .full }
        return .reinsert(remove: oldRows, insert: newRows)
    }
}
