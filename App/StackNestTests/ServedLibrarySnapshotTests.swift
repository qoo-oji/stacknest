// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import LibraryServer
@testable import StackNest

/// G62（spec §6.1・§8）: 配信中の書庫のスナップショットを、開閉と設定の変化のたびにその場で作り直す。
/// `.serialized`: `ServedLibraryPublisher.directory`・`didReplace`・`AppState.activeInstances` はプロセスで共有する。
@Suite("G62: 配信中の書庫のスナップショット", .serialized)
@MainActor
struct ServedLibrarySnapshotTests {
    @MainActor final class ReplaceLog {
        var count = 0
        var databaseOpenWhenDropped: Bool?
    }

    /// 開いた状態の AppState（DB はメモリ上）。呼び出し側が closeBundle で片付ける。
    private func openState() throws -> AppState {
        let state = AppState(bundleURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("g62-snap-\(UUID().uuidString).stacknest"))
        let db = try Database.openInMemory()
        try db.migrate()
        try state.finishOpening(db: db)
        state.librarySettings?.backupEnabled = false   // closeBundle でバックアップを作らない
        return state
    }

    private func entry(_ uuid: String) -> ServedLibraryDirectory.Entry? {
        ServedLibraryPublisher.directory.current().first { $0.library.uuid == uuid }
    }

    @Test func openedLibraryIsInTheDirectory() throws {
        let state = try openState()
        defer { state.closeBundle() }
        let uuid = try #require(state.librarySettings?.libraryUUID)
        #expect(entry(uuid)?.library.db === state.database)
        #expect(entry(uuid)?.sharedRemotely == false)
    }

    /// `database.close()` より前に一覧から外す（閉じ始めた書庫を新しいリクエストに出さない）。
    @Test func closeBundleDropsTheLibraryBeforeTheDatabaseCloses() throws {
        let state = try openState()
        let uuid = try #require(state.librarySettings?.libraryUUID)
        let db = try #require(state.database)
        let log = ReplaceLog()
        ServedLibraryPublisher.didReplace = { libs in
            if log.databaseOpenWhenDropped == nil, !libs.contains(where: { $0.uuid == uuid }) {
                log.databaseOpenWhenDropped = db.isOpen
            }
        }
        defer { ServedLibraryPublisher.didReplace = nil }

        state.closeBundle()

        #expect(log.databaseOpenWhenDropped == true)
        #expect(entry(uuid) == nil)
        #expect(state.isClosing)
    }

    @Test func settingsChangesShowUpImmediately() throws {
        let state = try openState()
        defer { state.closeBundle() }
        let settings = try #require(state.librarySettings)
        let uuid = try #require(settings.libraryUUID)

        settings.displayName = "G62 表示名"
        #expect(entry(uuid)?.library.name == "G62 表示名")

        settings.remoteSharingEnabled = true
        #expect(ServedLibraryPublisher.directory.libraries(sharedRemotelyOnly: true).contains { $0.uuid == uuid })
        settings.remoteSharingEnabled = false
        #expect(!ServedLibraryPublisher.directory.libraries(sharedRemotelyOnly: true).contains { $0.uuid == uuid })

        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "pw", saltHex: salt)
        #expect(try settings.setLock(hash: hash, salt: salt, expectedHash: nil))
        #expect(entry(uuid)?.library.isLocked == true)
        #expect(try settings.clearLock(expectedHash: hash))
        #expect(entry(uuid)?.library.isLocked == false)
    }

    /// Review Focus 4: 開いたとき 1 回・表示名の変更 1 回で 1 回（UUID を作って書いても、もう 1 回は起きない）。
    @Test func oneSettingsChangeRebuildsTheDirectoryOnce() throws {
        let log = ReplaceLog()
        ServedLibraryPublisher.didReplace = { _ in log.count += 1 }
        defer { ServedLibraryPublisher.didReplace = nil }
        let state = try openState()
        defer { state.closeBundle() }
        #expect(log.count == 1)
        state.librarySettings?.displayName = "G62 一度だけ"
        #expect(log.count == 2)
    }

    /// 別の Task が走り始めるのを待ってから、メインスレッドを `seconds` 秒塞ぐ。
    /// 同期の関数に包む（`DispatchSemaphore.wait` は async の中で直接呼べない＝noasync）。
    /// 待ちには上限を付ける（probe が走り出せないとき、止まらずに時間切れとして失敗させる）。
    private func blockMainThread(after started: DispatchSemaphore, seconds: TimeInterval) -> DispatchTimeoutResult {
        let result = started.wait(timeout: .now() + 5)
        if result == .success { Thread.sleep(forTimeInterval: seconds) }
        return result
    }

    /// hop が無いこと: メインスレッドを 1 秒塞いでいる間に、別の Task から `servedLibraries()` が 50 ms 以内に返る。
    @Test func servedLibrariesDoesNotWaitForTheMainThread() async throws {
        let state = try openState()
        defer { state.closeBundle() }
        let uuid = try #require(state.librarySettings?.libraryUUID)
        let local = AllOpenLibrariesDataSource(directory: ServedLibraryPublisher.directory)
        let shared = AppStateLibraryDataSource(directory: ServedLibraryPublisher.directory)
        let started = DispatchSemaphore(value: 0)
        let probe = Task.detached { () -> (Duration, Bool, Bool) in
            started.signal()
            let t0 = ContinuousClock.now
            let all = await local.servedLibraries()
            let sharedOnly = await shared.servedLibraries()
            return (t0.duration(to: .now), all.contains { $0.uuid == uuid }, sharedOnly.contains { $0.uuid == uuid })
        }
        #expect(blockMainThread(after: started, seconds: 1.0) == .success)
        let (elapsed, inLocal, inShared) = await probe.value
        #expect(inLocal)
        #expect(!inShared)   // 共有は既定で OFF
        #expect(elapsed < .milliseconds(50))
    }
}
