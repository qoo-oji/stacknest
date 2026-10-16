// SPDX-License-Identifier: MIT
import Testing
import AppKit
import Synchronization
import AppCore
import LibraryStore
@testable import StackNest

/// G62（spec §8）: 表の更新の呼び出しを数える。
final class CountingTableView: GatedTableView {
    var fullReloads = 0
    var rowReloads: [IndexSet] = []
    var removed: [IndexSet] = []
    var inserted: [IndexSet] = []

    override func reloadData() {
        fullReloads += 1
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        rowReloads.append(rowIndexes)
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions) {
        removed.append(indexes)
        super.removeRows(at: indexes, withAnimation: animationOptions)
    }

    override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions) {
        inserted.append(indexes)
        super.insertRows(at: indexes, withAnimation: animationOptions)
    }

    func resetCounts() {
        fullReloads = 0
        rowReloads = []
        removed = []
        inserted = []
    }
}

/// `withObservationTracking` の onChange（@Sendable）から立てる旗。
final class FiredFlag: Sendable {
    private let fired = Mutex(false)
    func set() { fired.withLock { $0 = true } }
    var value: Bool { fired.withLock { $0 } }
}

@Suite("G62: 一覧の変わった行だけを描き直す（リスト）")
@MainActor
struct BookTableRowUpdateTests {
    struct Harness {
        let state: AppState
        let db: Database
        let table: CountingTableView
        let coordinator: BookTableCoordinator
    }

    /// 合成の本 2,000 冊を持つ AppState と、それを出している表。最初の同期（全体）を済ませ、数を 0 に戻して返す。
    private func makeHarness(sort: ColumnSort = ColumnSort(column: .dateAdded, ascending: false)) throws -> Harness {
        let db = try Database.openInMemory()
        try db.migrate()
        try SyntheticLibrary.generate(into: db, count: 2_000)
        let settings = try LibrarySettings(database: db)
        settings.sortMode = .column
        settings.listViewSort = sort
        let state = AppState(bundleURL: URL(fileURLWithPath: "/tmp/g62-table.stacknest"))
        state.database = db
        state.librarySettings = settings
        try state.refreshDisplayedBooks()
        let coordinator = BookTableCoordinator(appState: state, settings: settings)
        let table = CountingTableView()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.tableView = table
        coordinator.installColumns(in: table)
        coordinator.syncFromAppState()
        table.resetCounts()
        return Harness(state: state, db: db, table: table, coordinator: coordinator)
    }

    /// DB を書き換えてから、サーバ経由の変更と同じ入口（まとめずに 1 冊）で AppState に知らせる。
    private func externalSet(_ h: Harness, _ id: Int, _ edit: (inout BookPatch) -> Void) throws {
        var patch = BookPatch()
        edit(&patch)
        try h.db.updateBook(id: id, patch: patch)
        h.state.handleExternalBookChange(bookID: id)
    }

    private func row(of id: Int, _ h: Harness) -> Int? {
        h.state.sortedDisplayedBooks.firstIndex { $0.id == id }
    }

    @Test func contentOnlyChangeReloadsJustThatRow() throws {
        let h = try makeHarness()
        let id = h.state.sortedDisplayedBooks[3].id
        try externalSet(h, id) { $0.series = "G62 行"; $0.volume = 99 }
        h.coordinator.syncFromAppState()
        #expect(h.table.fullReloads == 0)
        #expect(h.table.rowReloads == [IndexSet(integer: 3)])
        #expect(h.table.removed.isEmpty && h.table.inserted.isEmpty)
        #expect(h.state.sortedDisplayedBooks[3].series == "G62 行")
    }

    /// Q3 (a): 並べている列の値が変わった本だけが動き、ほかの行は作り直さない。
    @Test func sortChangingEditReinsertsOnlyTheMovedRow() throws {
        let h = try makeHarness(sort: ColumnSort(column: .title, ascending: true))
        let id = h.state.sortedDisplayedBooks[1_000].id
        try externalSet(h, id) { $0.title = "A G62 moved" }
        h.coordinator.syncFromAppState()
        #expect(h.table.fullReloads == 0)
        #expect(h.table.removed == [IndexSet(integer: 1_000)])
        #expect(h.table.inserted.count == 1)
        #expect(row(of: id, h) != 1_000)
        #expect(h.coordinator.displayedIDs == h.state.sortedDisplayedBooks.map(\.id))
        #expect(h.table.numberOfRows == 2_000)
    }

    @Test func severalMovedBooksAreReinsertedTogether() throws {
        let h = try makeHarness(sort: ColumnSort(column: .title, ascending: true))
        let ids = [10, 900, 1_700].map { h.state.sortedDisplayedBooks[$0].id }
        for (n, id) in ids.enumerated() { try externalSet(h, id) { $0.title = "A G62 \(n)" } }
        h.coordinator.syncFromAppState()
        #expect(h.table.fullReloads == 0)
        #expect(h.table.removed == [IndexSet([10, 900, 1_700])])
        #expect(h.table.inserted.first?.count == 3)
        #expect(h.coordinator.displayedIDs == h.state.sortedDisplayedBooks.map(\.id))
    }

    @Test func sixtyFiveChangesFallBackToOneFullReload() throws {
        let h = try makeHarness()
        for id in h.state.sortedDisplayedBooks.prefix(65).map(\.id) {
            try externalSet(h, id) { $0.series = "G62 多い" }
        }
        h.coordinator.syncFromAppState()
        #expect(h.table.fullReloads == 1)
        #expect(h.table.rowReloads.isEmpty)
    }

    @Test func sameValueSetDoesNothing() throws {
        let h = try makeHarness()
        let book = h.state.sortedDisplayedBooks[5]
        let before = h.state.bookListChanges.contentVersion
        try externalSet(h, book.id) { $0.series = book.series; $0.volume = book.volume }
        h.coordinator.syncFromAppState()
        #expect(h.state.bookListChanges.contentVersion == before)
        #expect(h.table.fullReloads == 0 && h.table.rowReloads.isEmpty && h.table.removed.isEmpty)
    }

    @Test func movedSelectedBookStaysSelected() throws {
        let h = try makeHarness(sort: ColumnSort(column: .title, ascending: true))
        let id = h.state.sortedDisplayedBooks[500].id
        h.state.selectedBookIDs = [id]
        h.coordinator.syncFromAppState()
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 500))

        try externalSet(h, id) { $0.title = "A G62 selected" }
        h.coordinator.syncFromAppState()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // 遅れて届く選択の通知も受けてから見る

        let newRow = try #require(row(of: id, h))
        #expect(h.state.selectedBookIDs == [id])
        #expect(h.table.selectedRowIndexes == IndexSet(integer: newRow))
    }

    @Test func changeDuringAClickIsAppliedAfterTheClick() throws {
        let h = try makeHarness()
        let id = h.state.sortedDisplayedBooks[2].id
        h.table.isClickInProgress = true
        try externalSet(h, id) { $0.series = "G62 クリック中" }
        h.coordinator.syncFromAppState()
        #expect(h.table.rowReloads.isEmpty)
        let pending = try #require(h.table.pendingPostClickSync)
        h.table.isClickInProgress = false
        h.table.pendingPostClickSync = nil
        pending()
        #expect(h.table.rowReloads == [IndexSet(integer: 2)])
    }

    /// Review Focus 5: 行の変更の直後に並べ替え（構造）→ 同じ同期で全体 1 回だけ。次の同期は何もしない。
    @Test func structureAndRowSignalsInOneSyncGiveOneFullReload() throws {
        let h = try makeHarness()
        try externalSet(h, h.state.sortedDisplayedBooks[4].id) { $0.series = "G62 両方" }
        h.state.refreshSortedDisplayedBooks()
        h.coordinator.syncFromAppState()
        #expect(h.table.fullReloads == 1)
        #expect(h.table.rowReloads.isEmpty)
        h.coordinator.syncFromAppState()
        #expect(h.table.fullReloads == 1)
        #expect(h.table.rowReloads.isEmpty)
    }

    /// 行の中身の変更で、親の View（`LibraryBrowserView`）が読む信号は動かない。
    @Test func contentChangeLeavesTheParentSignalsAlone() throws {
        let h = try makeHarness()
        let id = h.state.sortedDisplayedBooks[3].id
        let fired = FiredFlag()
        withObservationTracking {
            _ = h.state.hasDisplayedBooks
            _ = h.state.booksDataVersion
            _ = h.state.sortedDisplayedBooksVersion
        } onChange: { fired.set() }
        try externalSet(h, id) { $0.series = "G62 親" }
        #expect(!fired.value)
        #expect(h.state.hasDisplayedBooks)
    }

    @Test func unselectedChangeDoesNotReassignTheSelectedBooks() throws {
        let h = try makeHarness()
        let selected = h.state.sortedDisplayedBooks[0].id
        let other = h.state.sortedDisplayedBooks[1].id
        h.state.selectedBookIDs = [selected]
        let fired = FiredFlag()
        withObservationTracking { _ = h.state.displayedSelectedBooks } onChange: { fired.set() }
        try externalSet(h, other) { $0.series = "G62 ほか" }
        #expect(!fired.value)
        try externalSet(h, selected) { $0.series = "G62 選択中" }
        #expect(fired.value)
        #expect(h.state.displayedSelectedBooks.first?.series == "G62 選択中")
    }
}
