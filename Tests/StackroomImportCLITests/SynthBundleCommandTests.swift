// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
@testable import StackroomImportCLI

/// G62（spec §7.1-1・§8 末尾）: 計測用の合成の書庫を作るサブコマンド。
@Suite("G62: synth-bundle")
struct SynthBundleCommandTests {
    private func tempBundleURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("g62-synth-\(UUID().uuidString).stacknest")
    }

    @Test @MainActor func makesAValidBundleWithBooksAndTheListSettings() throws {
        let url = tempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try SynthBundleCommand.make(at: url, count: 300, seed: 7)

        try LibraryBundle(url: url).validate()
        let db = try Database.openExisting(at: LibraryBundle(url: url).databaseURL)
        defer { db.close() }
        #expect(try db.fetchBookCount() == 300)
        let settings = try LibrarySettings(database: db)
        #expect(settings.viewMode == .list)
        #expect(settings.sortMode == .column)
        #expect(settings.listViewSort == ColumnSort(column: .dateAdded, ascending: false))
        #expect(settings.topPaneMode == "browse")
        #expect(settings.listViewColumns == Set(SynthBundleCommand.visibleColumns))
        #expect(Array(settings.listColumnOrder.prefix(7)) == SynthBundleCommand.visibleColumns)
        // 開いたときに UUID を書く回（spec §12 の 5）を計測に混ぜないよう、作るときに入れておく。
        #expect(settings.libraryUUID != nil)
    }

    @Test @MainActor func refusesAnExistingPath() throws {
        let url = tempBundleURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try SynthBundleCommand.make(at: url, count: 1, seed: 1) }
    }
}
