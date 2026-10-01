// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI
import RemoteClient
import StackroomFormat
@testable import StackNest

/// G60: 「StackNest と読書位置を同期する」の ON/OFF で開き方が変わること・失敗したら従来の開き方に戻ること。
/// `HelperLauncher.launch` を差し替えるので、ローカルもリモートも**この 1 つの Suite** に置いて直列で走らせる
/// （Suite を分けると並行に走り、差し替えが競合する）。
/// UserDefaults.standard・実ポート・`LastReadTracker.shared` には触れない（`ExternalViewerHandoff` を差し替える）。
@MainActor
@Suite("G60: 外部ビューアとの読書位置の同期（配線）", .serialized)
struct ExternalViewerSyncWiringTests {
    final class Launches { var entries: [(file: URL, viewer: URL)] = [] }

    struct Env {
        let suiteName: String
        let suite: UserDefaults
        let base: URL
        let viewerApp: URL
        let settings: ViewerSettings
        let tokens: ViewerTokenStore
        func cleanup() {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
    }

    func makeEnv(sync: Bool) throws -> Env {
        let name = "g60-wiring-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("g60-wiring-\(UUID().uuidString)", isDirectory: true)
        let viewerApp = base.appendingPathComponent("FakeViewer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerApp, withIntermediateDirectories: true)
        let settings = ViewerSettings(defaults: suite)
        settings.useBuiltInImageViewer = false
        settings.externalViewerAppPath = viewerApp.path
        settings.syncsReadingPositionWithExternalViewer = sync
        return Env(suiteName: name, suite: suite, base: base, viewerApp: viewerApp,
                   settings: settings, tokens: ViewerTokenStore(defaults: suite))
    }

    func handoff(_ env: Env, endpointRunning: Bool = true) -> ExternalViewerHandoff {
        ExternalViewerHandoff(
            tokens: env.tokens,
            references: BookReferenceStore(baseDirectory: env.base.appendingPathComponent("AppSupport")),
            localPort: { 4321 },
            isLocalEndpointRunning: { endpointRunning },
            recordLastRead: { _ in },
            now: { Date() })
    }

    func recording(_ launches: Launches) -> (URL, URL) -> Void {
        { file, viewer in launches.entries.append((file, viewer)) }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        // 全スイート並行のときは MainActor が混むので余裕を持たせる（成功時は即戻る）。
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("待ちきれなかった"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 3 ページのフォルダ本 1 冊（読書位置 2）を持つローカルの書庫。
    private func makeLocalState(_ env: Env, handoff: ExternalViewerHandoff) throws -> (AppState, BookRow, URL) {
        let dir = env.base.appendingPathComponent("folder-book", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<3 { try Data("p\(i)".utf8).write(to: dir.appendingPathComponent("p\(i).jpg")) }
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRecord(
            id: 1, title: "本の題名", author: nil, genre: nil,
            path: dir.path, dateAdded: Date(timeIntervalSince1970: 100), playDate: nil,
            bookType: 0, fileType: 2, pages: 3, myRate: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil))
        try db.saveViewerState(bookID: 1, spreadEnabled: false, coverOffset: false, lastPage: 2)
        let state = AppState(bundleURL: env.base.appendingPathComponent("g60.stacknest"))
        state.database = db
        state.librarySettings = try LibrarySettings(database: db)
        state.viewerSettings = env.settings
        state.viewerHandoff = handoff
        let row = try #require(try db.fetchBook(id: 1))
        return (state, row, dir)
    }

    // MARK: - ローカル

    @Test func localSyncOnHandsAReferenceFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        let launched = try #require(launches.entries.first)
        #expect(launches.entries.count == 1, "参照ファイルで開いたら従来の開き方は走らない")
        #expect(launched.file.pathExtension == "stacknestbook")
        #expect(launched.viewer.path == env.viewerApp.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: launched.file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let ref = try BookReference.decode(Data(contentsOf: launched.file))
        let uuid = try #require(state.librarySettings?.ensureLibraryUUID())
        #expect(ref.book == "http://127.0.0.1:4321/api/v1/libraries/\(uuid)/books/1")
        #expect(ref.title == "本の題名")
        #expect(ref.pageCount == 3)
        #expect(ref.startPage == 2)
        guard case .valid(let record) = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("参照ファイルのトークンが 127.0.0.1 の口で有効でない"); return
        }
        #expect(record.libraryUUID == uuid)
        #expect(record.bookID == 1)
        #expect(record.issuedByGrantID == nil, "アプリが手元で出したトークンはグラントに結び付かない")
    }

    @Test func localSyncOffOpensTheFile() async throws {
        let env = try makeEnv(sync: false); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        #expect(launches.entries.first?.file.path == dir.path)
        #expect(env.tokens.allRecords().isEmpty, "OFF ではトークンを出さない")
    }

    @Test func localFailureFallsBackToTheFileWithANotice() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env, endpointRunning: false))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == dir.path)
        #expect(state.watchNotice.notice?.kind == .warning)
        #expect(state.watchNotice.notice?.text.contains("ファイルをそのまま") == true)
        #expect(state.watchNotice.notice?.text.contains("127.0.0.1") == true)
    }

    // MARK: - ロック・ビューア未設定（G60 fix round 1）

    private func setLock(_ state: AppState, _ value: String) throws {
        try state.database?.setLibrarySetting(key: "lock_password_hash", value: value)
    }

    private func referenceFiles(_ env: Env) -> [URL] {
        let root = env.base.appendingPathComponent("AppSupport/ViewerHandoff")
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "stacknestbook" }
    }

    @Test func lockedLibraryBindsTheTokenToTheVerifiedHash() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))
        try setLock(state, "H1")
        state.markUnlocked(hash: "H1")

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        #expect(launches.entries.count == 1)
        let launched = try #require(launches.entries.first)
        let ref = try BookReference.decode(Data(contentsOf: launched.file))
        guard case .valid(let record) = env.tokens.lookup(token: ref.token, issuer: .localEndpoint) else {
            Issue.record("トークンが有効でない"); return
        }
        #expect(record.lockFingerprint == ViewerTokenStore.lockFingerprint(for: "H1"))
    }

    @Test func lockChangedBehindTheWindowOpensNothingAndIssuesNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let h = handoff(env)
        let (state, row, _) = try makeLocalState(env, handoff: h)
        try setLock(state, "H2")          // 書庫側は H2
        state.markUnlocked(hash: "H1")    // このウィンドウが検証したのは H1

        let failure = await h.openLocal(
            book: row, libraryUUID: try #require(state.librarySettings?.ensureLibraryUUID()),
            lockCredential: { "H2" }, verifiedLockHash: { "H1" }, startPage: 0,
            direction: .rightToLeft, settings: env.settings)
        #expect(failure == .libraryLocked)

        await state.openInExternalViewerSyncing([row])
        #expect(launches.entries.isEmpty, "施錠庫は生のファイルにも逃がさない")
        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice?.kind == .warning)
    }

    @Test func missingViewerSkipsTheHandoffWithoutIssuingAToken() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        env.settings.externalViewerAppPath = env.base.appendingPathComponent("Nope.app").path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))

        await state.openInExternalViewerSyncing([row])

        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(launches.entries.isEmpty)
        #expect(state.watchNotice.notice == nil, "同期失敗のお知らせは出さない")
        #expect(state.error != nil, "従来の開き方がビューア未設定を報告する")
    }
}
