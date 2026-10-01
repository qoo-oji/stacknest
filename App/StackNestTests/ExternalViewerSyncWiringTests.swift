// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI
import RemoteClient
import StackroomFormat
@testable import StackNest

/// viewer-token にだけ答える URLProtocol（G60 の App テスト用）。それ以外の要求は 200 `{}`。
/// 記録は URLSession のスレッドと main の両方から触るので `NSLock` で包む。
final class G60ViewerTokenStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedIssueStatus = 200
    nonisolated(unsafe) private static var storedIssueBody = Data()
    nonisolated(unsafe) private static var storedPaths: [String] = []

    static var issueStatus: Int {
        get { lock.withLock { storedIssueStatus } }
        set { lock.withLock { storedIssueStatus = newValue } }
    }
    static var issueBody: Data {
        get { lock.withLock { storedIssueBody } }
        set { lock.withLock { storedIssueBody = newValue } }
    }
    static var paths: [String] {
        get { lock.withLock { storedPaths } }
        set { lock.withLock { storedPaths = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.storedPaths.append("\(request.httpMethod ?? "") \(path)") }
        let isIssue = path.hasSuffix("/viewer-token")
        let resp = HTTPURLResponse(url: request.url!, statusCode: isIssue ? Self.issueStatus : 200,
                                   httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isIssue ? Self.issueBody : Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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


    // MARK: - リモート

    private func makeRemoteState(_ env: Env, issueStatus: Int) throws -> RemoteLibraryState {
        G60ViewerTokenStub.paths = []
        G60ViewerTokenStub.issueStatus = issueStatus
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        G60ViewerTokenStub.issueBody = try encoder.encode(
            ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000)))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [G60ViewerTokenStub.self]
        let client = RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device",
                                         session: URLSession(configuration: cfg))
        let s = RemoteLibraryState(
            client: client, serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: false, libraryToken: nil,
            coverCache: RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil))
        s.viewerSettings = env.settings
        s.viewerHandoff = handoff(env)
        return s
    }

    private func remoteBook(id: Int, filename: String, lastPage: Int) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: "本の題名", author: nil, series: nil, volume: nil,
            rating: 0, unseen: true, bookType: 0, pages: 20, lastPage: lastPage,
            lastReadAt: nil, dateAdded: Date(), hasCover: false, coverVersion: nil,
            filename: filename)
    }

    @Test func remoteSyncOnHandsAReferenceFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let s = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 42, value: ManifestDTO(pageCount: 20, direction: "ltr", format: "archive", etag: "e"))

        s.openViewer(book: remoteBook(id: 42, filename: "a.zip", lastPage: 5))
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try BookReference.decode(Data(contentsOf: try #require(launches.entries.first).file))
        #expect(ref.book == "http://127.0.0.1:1/api/v1/libraries/\(s.libraryUUID)/books/42")
        #expect(ref.token == "VIEWER-TOKEN")
        #expect(ref.pageCount == 20)
        #expect(ref.direction == "ltr")
        #expect(ref.startPage == 5)
        #expect(G60ViewerTokenStub.paths.contains("POST /api/v1/libraries/\(s.libraryUUID)/books/42/viewer-token"))
        #expect(s.errorText == nil)
        // 開いた後の既読の書き込み（投げっぱなしの POST /progress）が届くまで待つ。
        // 待たずに抜けると、次のテストが記録を空にした後にこの要求が届いて記録を汚す。
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/42/progress") } }
    }

    @Test func remoteIssueFailureFallsBackToTheBuiltInViewerWithABanner() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let s = try makeRemoteState(env, issueStatus: 500)
        s.testPutManifestHandoff(bookID: 43, value: ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "e"))
        // 内蔵ビューアの経路は「開き中」で早く戻らせる（テストホストで本物の窓を作らない）。
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 43)
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }

        s.openViewer(book: remoteBook(id: 43, filename: "a.zip", lastPage: 0))
        try await waitUntil { s.errorText != nil }

        #expect(launches.entries.isEmpty)
        #expect(s.errorText?.contains("内蔵ビューアで開きました") == true)
        #expect(s.errorText?.contains("トークンを発行できませんでした") == true)
    }

    /// 旧サーバ（viewer-token のルートが無い＝404）は G60 前と同じ挙動なので、知らせずに内蔵で開く。
    @Test func remoteOldServerFallsBackSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let s = try makeRemoteState(env, issueStatus: 404)
        s.testPutManifestHandoff(bookID: 45, value: ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "e"))
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 45)
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }

        s.openViewer(book: remoteBook(id: 45, filename: "a.zip", lastPage: 0))
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/45/viewer-token") } }
        try await Task.sleep(for: .milliseconds(300))   // 404 を受けて内蔵へ倒すまでの余裕

        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    @Test func remoteSyncOffStaysBuiltIn() async throws {
        let env = try makeEnv(sync: false); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let s = try makeRemoteState(env, issueStatus: 200)
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 44)
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }

        s.openViewer(book: remoteBook(id: 44, filename: "a.zip", lastPage: 0))   // 同期 OFF の判定は同期的

        #expect(launches.entries.isEmpty)
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
    }

    /// 旧サーバが 501 を返しても、404 と同じく知らせずに内蔵で開く。
    @Test func remoteNotImplementedFallsBackSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let s = try makeRemoteState(env, issueStatus: 501)
        s.testPutManifestHandoff(bookID: 46, value: ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "e"))
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 46)
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }

        s.openViewer(book: remoteBook(id: 46, filename: "a.zip", lastPage: 0))
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/46/viewer-token") } }
        try await Task.sleep(for: .milliseconds(300))

        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// 使える外部ビューアが無いときは、トークンを要求せずに黙って内蔵で開く。
    @Test func remoteMissingViewerSkipsTheTokenRequest() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        env.settings.externalViewerAppPath = env.base.appendingPathComponent("Nope.app").path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let s = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 47, value: ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "e"))
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 47)
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        defer { ViewerWindowRegistry.shared.cancelOpen(identity) }

        s.openViewer(book: remoteBook(id: 47, filename: "a.zip", lastPage: 0))
        try await Task.sleep(for: .milliseconds(500))

        #expect(launches.entries.isEmpty)
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(s.errorText == nil)
    }
}
