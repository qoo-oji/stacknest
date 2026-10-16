// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI
@testable import StackNest

/// G62（spec §6.3・§8）: 両方のサーバの変更通知をまとめて、間隔ごとに 1 回だけ MainActor で反映する。
/// `.serialized`: 開く・閉じるで `ServedLibraryPublisher.directory`・`didReplace`・`AppState.activeInstances`
/// （プロセスで共有）に触る（`ServedLibrarySnapshotTests` と同じ）。
@Suite("G62: ExternalChangeCoalescer", .serialized)
@MainActor
struct ExternalChangeCoalescerTests {
    /// 反映の回数と、渡された分を記録する。
    @MainActor final class Deliveries {
        var batches: [[String: ExternalChangeCoalescer.Batch]] = []
        var count: Int { batches.count }
    }

    /// 合成の本を持つ、開いた状態の AppState（DB はメモリ上）と、その UUID。呼び出し側が closeBundle で片付ける。
    private func openState(books: Int = 200) throws -> (AppState, String) {
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g62-co-\(UUID().uuidString).stacknest"))
        let db = try Database.openInMemory()
        try db.migrate()
        try SyntheticLibrary.generate(into: db, count: books)
        try state.finishOpening(db: db)
        state.librarySettings?.backupEnabled = false
        return (state, try #require(state.librarySettings?.libraryUUID))
    }

    /// 条件が満たされるまで MainActor を手放しながら待つ（上限つき）。
    /// 全スイート並行のときは MainActor が混む（ほかのスイートの 1 つの試験が数秒続けて塞ぐ）ので、上限は
    /// `ExternalViewerSyncWiringTests` と同じく 60 秒にする（成功時は即戻る）。5 秒では、塞がれていた間に上限を過ぎ、
    /// 待っていた反映より先にこの確認が走って時間切れになった（全体の実行で実際に起きた）。
    private func waitUntil(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("条件が満たされないまま時間切れ"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func setSeries(_ state: AppState, _ id: Int, _ series: String) throws {
        var patch = BookPatch()
        patch.series = series
        try #require(state.database).updateBook(id: id, patch: patch)
    }

    /// 本 100 冊の通知 → 反映は「最初の 1 回＋間隔ごとに 1 回」以下で、100 冊の値が全部入る。
    @Test func aHundredNotesBecomeAFewDeliveriesAndAllValuesLand() async throws {
        let (state, uuid) = try openState()
        defer { state.closeBundle() }
        let log = Deliveries()
        let interval: Duration = .milliseconds(100)
        let co = ExternalChangeCoalescer(interval: interval, deliver: { batches in
            log.batches.append(batches)
            ExternalChangeCoalescer.deliver(batches, to: [state], bridge: { _ in })
        })
        let t0 = ContinuousClock.now
        for id in 1...100 {
            try setSeries(state, id, "G62-\(id)")
            co.note(book: id, in: uuid, origin: .sharedServer)
        }
        try await waitUntil {
            (1...100).allSatisfy { id in state.displayedBooks.first { $0.id == id }?.series == "G62-\(id)" }
        }
        let elapsed = t0.duration(to: .now)
        #expect(log.count <= Int(elapsed / interval) + 2)
        #expect(log.count < 100)
        #expect(log.batches.reduce(0) { $0 + ($1[uuid]?.bookIDs.count ?? 0) } == 100)
    }

    /// 構造の変化と本の変更が同じ回に入る → 全体の読み直し 1 回（本の値もそれで入る）。
    @Test func structureAndBookChangesInOneRoundReadTheListOnce() async throws {
        let (state, uuid) = try openState()
        defer { state.closeBundle() }
        let log = Deliveries()
        let co = ExternalChangeCoalescer(interval: .seconds(1), deliver: { batches in
            log.batches.append(batches)
            ExternalChangeCoalescer.deliver(batches, to: [state], bridge: { _ in })
        })
        co.note(book: 1, in: uuid, origin: .sharedServer)   // 1 回目はすぐ反映され、間隔が始まる
        try await waitUntil { log.count == 1 }
        let readsBefore = state.booksDataVersion
        try setSeries(state, 2, "G62-mixed")
        co.note(book: 2, in: uuid, origin: .sharedServer)
        co.noteStructure(in: uuid, origin: .sharedServer)
        try await waitUntil { log.count == 2 }
        #expect(log.batches[1][uuid] == ExternalChangeCoalescer.Batch(bookIDs: [2], structureChanged: true, bridged: []))
        #expect(state.booksDataVersion == readsBefore + 1)
        #expect(state.displayedBooks.first { $0.id == 2 }?.series == "G62-mixed")
    }

    /// 反映の前に書庫を閉じた → 落ちない・何も入らない（その分は捨てる）。
    @Test func closingBeforeTheFlushDropsTheChangesWithoutCrashing() async throws {
        let (state, uuid) = try openState()
        let log = Deliveries()
        let co = ExternalChangeCoalescer(interval: .milliseconds(300), deliver: { batches in
            log.batches.append(batches)
            ExternalChangeCoalescer.deliver(batches, to: [state], bridge: { _ in })
        })
        co.note(book: 1, in: uuid, origin: .sharedServer)
        try await waitUntil { log.count == 1 }
        co.note(book: 2, in: uuid, origin: .sharedServer)   // 予約される
        state.closeBundle()
        try await waitUntil { log.count == 2 }
        #expect(state.database == nil)
        #expect(state.displayedBooks.isEmpty)

        // 上の反映は書庫の UUID が引けずに `applyExternalChanges` まで届かない（`closeBundle` が `librarySettings` を
        // nil にする）。閉じた書庫へ直に入れても、落ちず・何も入らないことをここで確かめる（spec §8）。
        let versionAfterClose = state.booksDataVersion
        let coversAfterClose = state.coverVersionByBook
        state.applyExternalChanges(bookIDs: [1, 2], structureChanged: true)
        state.applyExternalChanges(bookIDs: [1, 2], structureChanged: false)
        // 表紙の版は MainActor の Task で上がる。門が無ければその Task が走って版が上がるので、待ってから見る。
        try await Task.sleep(for: .milliseconds(150))
        #expect(state.displayedBooks.isEmpty)
        #expect(state.booksDataVersion == versionAfterClose)
        #expect(state.coverVersionByBook == coversAfterClose)
    }

    /// 共有サーバへの橋渡しは、今どおりローカルコントロール発の分だけ・届いた順・同じ数。
    @Test func onlyLocalControlChangesAreBridgedInArrivalOrder() async throws {
        let log = Deliveries()
        let co = ExternalChangeCoalescer(interval: .seconds(1), deliver: { log.batches.append($0) })
        co.note(book: 1, in: "L", origin: .localControl)
        try await waitUntil { log.count == 1 }
        co.note(book: 2, in: "L", origin: .sharedServer)
        co.noteStructure(in: "L", origin: .localControl)
        co.note(book: 3, in: "L", origin: .localControl)
        try await waitUntil { log.count == 2 }
        #expect(log.batches[0]["L"]?.bridged == [.bookChanged(library: "L", bookID: 1)])
        #expect(log.batches[1]["L"]?.bridged == [.structureChanged(library: "L"), .bookChanged(library: "L", bookID: 3)])
        #expect(log.batches[1]["L"]?.bookIDs == [2, 3])

        // 本番の反映は、記録した橋渡しを順に出す。
        var sent: [LiveEvent] = []
        ExternalChangeCoalescer.deliver(log.batches[1], to: [], bridge: { sent.append($0) })
        #expect(sent == [.structureChanged(library: "L"), .bookChanged(library: "L", bookID: 3)])
    }

    /// Review Focus 3: A の変更は B の一覧を動かさない。
    @Test func changesForOneLibraryDoNotTouchAnother() throws {
        let (a, uuidA) = try openState(books: 50)
        defer { a.closeBundle() }
        let (b, _) = try openState(books: 50)
        defer { b.closeBundle() }
        let bRows = b.bookListChanges.contentVersion
        let bReads = b.booksDataVersion
        try setSeries(a, 7, "G62-A")
        ExternalChangeCoalescer.deliver([uuidA: .init(bookIDs: [7])], to: [a, b], bridge: { _ in })
        #expect(a.displayedBooks.first { $0.id == 7 }?.series == "G62-A")
        #expect(b.bookListChanges.contentVersion == bRows)
        #expect(b.booksDataVersion == bReads)
        #expect(b.displayedBooks.first { $0.id == 7 }?.series != "G62-A")
    }

    /// Review Focus 1: 通知の後・反映の前にローカルで同じ本を書いても、ローカルの新しい値が残る（反映のときに読む）。
    @Test func readsTheBookWhenApplyingNotWhenNoted() async throws {
        let (state, uuid) = try openState()
        defer { state.closeBundle() }
        let log = Deliveries()
        let co = ExternalChangeCoalescer(interval: .milliseconds(300), deliver: { batches in
            log.batches.append(batches)
            ExternalChangeCoalescer.deliver(batches, to: [state], bridge: { _ in })
        })
        co.note(book: 1, in: uuid, origin: .sharedServer)
        try await waitUntil { log.count == 1 }
        try setSeries(state, 2, "G62-server")
        co.note(book: 2, in: uuid, origin: .sharedServer)          // 予約される
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.markVolumeAsReadAndReflect(bookID: 2, at: readAt)   // 反映の前のローカルの書き込み
        try await waitUntil { log.count == 2 }
        let shown = try #require(state.displayedBooks.first { $0.id == 2 })
        #expect(shown.playDate?.timeIntervalSince1970 == readAt.timeIntervalSince1970)
        #expect(shown.unseen == false)
        #expect(shown.series == "G62-server")
    }

    /// 表紙の版は、まとめた本ごとに 1 つずつ上がる（1 回の代入）。
    @Test func coverVersionsGoUpOnceForTheBatch() async throws {
        let (state, _) = try openState()
        defer { state.closeBundle() }
        state.applyExternalChanges(bookIDs: [1, 2, 3], structureChanged: false)
        try await waitUntil { [1, 2, 3].allSatisfy { state.coverVersionByBook[$0] == 1 } }
        #expect(state.coverVersionByBook[4] == nil)
    }
}
