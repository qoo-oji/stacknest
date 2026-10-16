// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G62（spec §6.4・§8）: 表の更新の計画。
@Suite("G62: ListUpdatePlanner")
struct ListUpdatePlannerTests {
    /// NSTableView と同じ順で計画を当てる（外す行は前の並びの番号、入れる行は新しい並びの番号）。
    private func applied(_ update: ListUpdate, displayed: [Int], current: [Int]) -> [Int] {
        switch update {
        case .unchanged, .reloadRows:
            return displayed
        case .full:
            return current
        case .reinsert(let remove, let insert):
            var rows = displayed
            for i in remove.reversed() { rows.remove(at: i) }
            for i in insert { rows.insert(current[i], at: i) }
            return rows
        }
    }

    @Test func sameOrderReloadsOnlyTheChangedRowsInTheList() {
        let ids = Array(1...10)
        let update = ListUpdatePlanner.plan(displayed: ids, current: ids, changed: [3, 7, 99], structureChanged: false)
        #expect(update == .reloadRows(IndexSet([2, 6])))   // 99 は一覧に居ないので行に含めない
    }

    @Test func oneMovedBookIsReinserted() {
        let before = [1, 2, 3, 4, 5], after = [4, 1, 2, 3, 5]
        let update = ListUpdatePlanner.plan(displayed: before, current: after, changed: [4], structureChanged: false)
        #expect(update == .reinsert(remove: IndexSet(integer: 3), insert: IndexSet(integer: 0)))
        #expect(applied(update, displayed: before, current: after) == after)
    }

    @Test func severalMovedBooksAreReinserted() {
        let before = [1, 2, 3, 4, 5, 6, 7, 8], after = [8, 1, 2, 6, 3, 4, 5, 7]   // 8 と 6 が動き、3 は中身だけ
        let update = ListUpdatePlanner.plan(displayed: before, current: after, changed: [3, 6, 8], structureChanged: false)
        #expect(update == .reinsert(remove: IndexSet([2, 5, 7]), insert: IndexSet([0, 3, 4])))
        #expect(applied(update, displayed: before, current: after) == after)
    }

    @Test func fallsBackToFullWhenThePremiseBreaks() {
        let ids = Array(1...100)
        #expect(ListUpdatePlanner.plan(displayed: ids, current: ids, changed: [1], structureChanged: true) == .full)
        #expect(ListUpdatePlanner.plan(displayed: [1, 2, 3], current: [1, 2], changed: [3], structureChanged: false) == .full)
        #expect(ListUpdatePlanner.plan(displayed: ids, current: ids, changed: Set(1...65), structureChanged: false) == .full)
        // 変わっていない本どうしの順が違う
        #expect(ListUpdatePlanner.plan(displayed: [1, 2, 3, 4], current: [2, 1, 3, 4], changed: [3], structureChanged: false) == .full)
        // 変わった本が無いのに並びが違う（前提が崩れている）
        #expect(ListUpdatePlanner.plan(displayed: [1, 2], current: [2, 1], changed: [], structureChanged: false) == .full)
    }

    @Test func exactlySixtyFourStaysRowLevel() {
        let ids = Array(1...100)
        #expect(ListUpdatePlanner.plan(displayed: ids, current: ids, changed: Set(1...64), structureChanged: false)
                == .reloadRows(IndexSet(0..<64)))
    }

    @Test func nothingToDo() {
        let ids = Array(1...5)
        #expect(ListUpdatePlanner.plan(displayed: ids, current: ids, changed: [], structureChanged: false) == .unchanged)
        #expect(ListUpdatePlanner.plan(displayed: ids, current: ids, changed: [42], structureChanged: false) == .unchanged)
    }
}
