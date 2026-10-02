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
    nonisolated(unsafe) private static var storedIssueHeaders: [String: String] = [:]

    /// viewer-token の応答に足すヘッダ（施錠ゲートの 403 は `X-Library-Locked: 1`）。
    static var issueHeaders: [String: String] {
        get { lock.withLock { storedIssueHeaders } }
        set { lock.withLock { storedIssueHeaders = newValue } }
    }

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
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"].merging(isIssue ? Self.issueHeaders : [:]) { $1 })!
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

    /// G60 v3: 偽アプリの Info.plist に、StackNest への対応の宣言（`StackNestViewerSupport`）を書く。
    static func declareReferenceSupport(_ app: URL, versions: [Int] = [1]) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fakeviewer",
            "CFBundleName": "FakeViewer",
            ViewerSupportDeclaration.infoPlistKey: [ViewerSupportDeclaration.versionsKey: versions],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// G60 v3: 参照ファイルの型（UTType・拡張子）だけを宣言し、`StackNestViewerSupport` を持たない Info.plist
    /// （v2 で対応とみなしていた形）に差し替える。v3 では未対応。
    static func writeTypeOnlyInfoPlist(_ app: URL) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fakeviewer",
            "CFBundleName": "FakeViewer",
            "CFBundleDocumentTypes": [
                ["LSItemContentTypes": [BookReference.typeIdentifier]],
                ["CFBundleTypeExtensions": [BookReference.fileExtension, "zip"]],
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    func makeEnv(sync: Bool) throws -> Env {
        let name = "g60-wiring-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("g60-wiring-\(UUID().uuidString)", isDirectory: true)
        let viewerApp = base.appendingPathComponent("FakeViewer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerApp, withIntermediateDirectories: true)
        try Self.declareReferenceSupport(viewerApp)
        let settings = ViewerSettings(defaults: suite)
        settings.useBuiltInImageViewer = false
        settings.externalViewerAppPath = viewerApp.path
        settings.syncsReadingPositionWithExternalViewer = sync
        return Env(suiteName: name, suite: suite, base: base, viewerApp: viewerApp,
                   settings: settings, tokens: ViewerTokenStore(defaults: suite))
    }

    final class LastReads { var items: [LastReadBook] = [] }
    final class Fallbacks { var entries: [(bookID: Int, manifest: ManifestDTO?)] = [] }

    func handoff(_ env: Env, endpointRunning: Bool = true, lastReads: LastReads? = nil) -> ExternalViewerHandoff {
        ExternalViewerHandoff(
            tokens: env.tokens,
            references: BookReferenceStore(baseDirectory: env.base.appendingPathComponent("AppSupport")),
            localPort: { 4321 },
            isLocalEndpointRunning: { endpointRunning },
            recordLastRead: { lastReads?.items.append($0) },
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
        #expect(ref.version == 1, "宣言 [1] との共通の最大")
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
            viewer: try #require(HelperLauncher.referenceViewer(bookPath: row.path ?? "", settings: env.settings)),
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


    /// G60 v3: 参照ファイルの型だけを宣言し `StackNestViewerSupport` を持たないビューアには、トークンも参照ファイルも
    /// お知らせも出さず、G60 前と同じにファイルそのものを渡す（v2 ではこの形を対応とみなしていた）。
    @Test func localTypeOnlyViewerGetsTheFileSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.writeTypeOnlyInfoPlist(env.viewerApp)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))   // 余計な起動があれば、ここで届く

        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == dir.path, "参照ファイルではなく本そのもの")
        #expect(launches.entries.first?.viewer.path == env.viewerApp.path)
        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice == nil)
        #expect(state.error == nil)
    }

    /// G60 v3: 将来の版を併せて宣言していても、StackNest が書ける最大（1）で書く。
    @Test func localReferenceUsesTheNegotiatedVersion() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.declareReferenceSupport(env.viewerApp, versions: [1, 9])
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, _) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try BookReference.decode(Data(contentsOf: try #require(launches.entries.first).file))
        #expect(ref.version == 1)
    }

    /// G60 v3: 共通の版が無い（[9] だけを宣言）なら未対応。ファイルのまま黙って渡す。
    @Test func localViewerWithNoCommonVersionGetsTheFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.declareReferenceSupport(env.viewerApp, versions: [9])
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (state, row, dir) = try makeLocalState(env, handoff: handoff(env))

        state.openBooks([row])
        try await waitUntil { !launches.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(launches.entries.count == 1)
        #expect(launches.entries.first?.file.path == dir.path)
        #expect(env.tokens.allRecords().isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(state.watchNotice.notice == nil)
    }

    // MARK: - リモート

    /// 内蔵ビューアで開く本体は差し替える（`builtInOpenOverride`）。本物の窓・`LastReadTracker.shared` に触れず、
    /// 「内蔵へ倒した」を陽性の合図として待てる。ダウンロード済みコピーの問い合わせも差し替える（実 `~/Library` を読まない）。
    private func makeRemoteState(_ env: Env, issueStatus: Int, libraryToken: String? = nil,
                                 issueHeaders: [String: String] = [:], lastReads: LastReads? = nil,
                                 offlineLastPage: Int? = nil) throws -> (RemoteLibraryState, Fallbacks) {
        G60ViewerTokenStub.paths = []
        G60ViewerTokenStub.issueStatus = issueStatus
        G60ViewerTokenStub.issueHeaders = issueHeaders
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        G60ViewerTokenStub.issueBody = try encoder.encode(
            ViewerTokenReply(token: "VIEWER-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), tokenID: "TID-1"))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [G60ViewerTokenStub.self]
        let client = RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device",
                                         session: URLSession(configuration: cfg))
        let s = RemoteLibraryState(
            client: client, serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "テスト", locked: false, libraryToken: libraryToken,
            coverCache: RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil))
        s.viewerSettings = env.settings
        s.viewerHandoff = handoff(env, lastReads: lastReads)
        s.offlineLastPageOverride = { _ in offlineLastPage }
        let fallbacks = Fallbacks()
        s.builtInOpenOverride = { book, manifest in fallbacks.entries.append((book.id, manifest)) }
        return (s, fallbacks)
    }

    private func remoteBook(id: Int, filename: String, lastPage: Int) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: "本の題名", author: nil, series: nil, volume: nil,
            rating: 0, unseen: true, bookType: 0, pages: 20, lastPage: lastPage,
            lastReadAt: nil, dateAdded: Date(), hasCover: false, coverVersion: nil,
            filename: filename)
    }

    private func archiveManifest() -> ManifestDTO {
        ManifestDTO(pageCount: 20, direction: "ltr", format: "archive", etag: "e")
    }

    @Test func remoteSyncOnHandsAReferenceFile() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let lastReads = LastReads()
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200, lastReads: lastReads)
        s.testPutManifestHandoff(bookID: 42, value: archiveManifest())
        let book = remoteBook(id: 42, filename: "a.zip", lastPage: 5)
        s.books = [book]

        s.openViewer(book: book)
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try BookReference.decode(Data(contentsOf: try #require(launches.entries.first).file))
        #expect(ref.book == "http://127.0.0.1:1/api/v1/libraries/\(s.libraryUUID)/books/42")
        #expect(ref.token == "VIEWER-TOKEN")
        #expect(ref.pageCount == 20)
        #expect(ref.direction == "ltr")
        #expect(ref.startPage == 5)
        #expect(G60ViewerTokenStub.paths.contains("POST /api/v1/libraries/\(s.libraryUUID)/books/42/viewer-token"))
        #expect(s.errorText == nil)
        #expect(fallbacks.entries.isEmpty)
        // 内蔵と同じに、開いた時点で既読にし、最後に開いた本として記録する。
        #expect(s.books.first?.unseen == false)
        #expect(lastReads.items == [.remote(
            serverID: s.serverID, serverURL: "http://127.0.0.1:1/", libraryUUID: s.libraryUUID,
            libraryName: "テスト", bookID: 42, title: "本の題名", locked: false)])
        // 開いた後の既読の書き込み（投げっぱなしの POST /progress）が届くまで待つ。
        // 待たずに抜けると、次のテストが記録を空にした後にこの要求が届いて記録を汚す。
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/42/progress") } }
    }

    /// リモートのフォルダの本（filename に拡張子が無い）は、manifest の format でフォルダの外部ビューアへ渡す
    /// （filename の拡張子から決めるとアーカイブの指定に倒れていた＝最終レビュー M-1）。
    @Test func remoteFolderBookUsesTheFolderViewer() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let folderViewer = env.base.appendingPathComponent("FolderViewer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folderViewer, withIntermediateDirectories: true)
        try Self.declareReferenceSupport(folderViewer)
        env.settings.categoryViewerPaths[.folder] = folderViewer.path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 51, value: ManifestDTO(pageCount: 20, direction: "rtl", format: "folder", etag: "e"))

        s.openViewer(book: remoteBook(id: 51, filename: "フォルダの本", lastPage: 0))
        try await waitUntil { !launches.entries.isEmpty || !fallbacks.entries.isEmpty }

        #expect(fallbacks.entries.isEmpty)
        let launched = try #require(launches.entries.first)
        #expect(launched.file.pathExtension == "stacknestbook")
        #expect(launched.viewer.path == folderViewer.path, "フォルダの本はフォルダの外部ビューアで開く")
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/51/progress") } }
    }

    /// ダウンロード済みコピーの方が先まで読んでいるときは、内蔵と同じにそちらから始める（サーバを巻き戻さない）。
    @Test func remoteStartPageUsesTheFurtherOfServerAndOfflinePosition() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, _) = try makeRemoteState(env, issueStatus: 200, offlineLastPage: 12)
        s.testPutManifestHandoff(bookID: 48, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 48, filename: "a.zip", lastPage: 5))
        try await waitUntil { !launches.entries.isEmpty }

        let ref = try BookReference.decode(Data(contentsOf: try #require(launches.entries.first).file))
        #expect(ref.startPage == 12)
        try await waitUntil { G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/48/progress") } }
    }

    @Test func remoteIssueFailureFallsBackToTheBuiltInViewerWithABanner() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 500)
        s.testPutManifestHandoff(bookID: 43, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 43, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(launches.entries.isEmpty)
        #expect(fallbacks.entries.count == 1)
        #expect(fallbacks.entries.first?.manifest?.pageCount == 20, "取得済みの manifest を内蔵へ渡す")
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
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 404)
        s.testPutManifestHandoff(bookID: 45, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 45, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/45/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// 旧サーバが 501 を返しても、404 と同じく知らせずに内蔵で開く。
    @Test func remoteNotImplementedFallsBackSilently() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 501)
        s.testPutManifestHandoff(bookID: 46, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 46, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(G60ViewerTokenStub.paths.contains { $0.hasSuffix("/books/46/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// 施錠ゲートの 403（パスワード変更など）。他のリモート呼び出しと同じく解錠へ戻し、何も開かない。
    @Test func remoteLockGateAtIssuanceReturnsToUnlockAndOpensNothing() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(
            env, issueStatus: 403, libraryToken: "LIB-TOKEN", issueHeaders: [RemoteClientError.libraryLockedHeader: "1"])
        s.testPutManifestHandoff(bookID: 49, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 49, filename: "a.zip", lastPage: 0))
        try await waitUntil { s.libraryToken == nil || !fallbacks.entries.isEmpty || s.errorText != nil }

        #expect(s.libraryToken == nil, "失効としてトークンを捨てる（解錠フォームへ戻る）")
        #expect(s.locked)
        #expect(s.errorText?.contains("パスワードが変更されました") == true)
        #expect(launches.entries.isEmpty)
        #expect(fallbacks.entries.isEmpty, "内蔵へも倒さない")
    }

    /// 使える外部ビューアが無いときは、トークンを要求せずに黙って内蔵で開く。
    @Test func remoteMissingViewerSkipsTheTokenRequest() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        env.settings.externalViewerAppPath = env.base.appendingPathComponent("Nope.app").path
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 47, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 47, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }

        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(s.errorText == nil)
    }

    /// G60 v3: 参照ファイルの型だけを宣言した外部ビューアには、トークンを要求せずに黙って内蔵で開く。
    @Test func remoteTypeOnlyViewerSkipsTheTokenRequest() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        try Self.writeTypeOnlyInfoPlist(env.viewerApp)
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 52, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 52, filename: "a.zip", lastPage: 0))
        try await waitUntil { !fallbacks.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(fallbacks.entries.count == 1, "内蔵ビューアで開く")
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(referenceFiles(env).isEmpty)
        #expect(s.errorText == nil)
    }

    @Test func remoteSyncOffStaysBuiltIn() async throws {
        let env = try makeEnv(sync: false); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 44, value: archiveManifest())

        s.openViewer(book: remoteBook(id: 44, filename: "a.zip", lastPage: 0))

        // 同期 OFF なら内蔵の本体が**同期的に**呼ばれる（参照ファイルの Task を作っていれば、ここではまだ呼ばれない）。
        #expect(fallbacks.entries.count == 1)
        try await Task.sleep(for: .milliseconds(50))   // 余計な Task があれば、ここで走り出す
        #expect(fallbacks.entries.count == 1)
        #expect(launches.entries.isEmpty)
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
    }

    final class FakeViewerWindow: ViewerWindowControlling {
        var focused = 0
        func focus() { focused += 1 }
        func close() {}
    }

    /// この本の内蔵窓が既に開いているなら、従来どおり前面化するだけ（外部ビューアへ渡さない）。
    @Test func remoteOpenBuiltInWindowIsFrontedInsteadOfHandingOff() async throws {
        let env = try makeEnv(sync: true); defer { env.cleanup() }
        let launches = Launches()
        let original = HelperLauncher.launch
        defer { HelperLauncher.launch = original }
        HelperLauncher.launch = recording(launches)
        let (s, fallbacks) = try makeRemoteState(env, issueStatus: 200)
        s.testPutManifestHandoff(bookID: 50, value: archiveManifest())
        let identity = ViewerIdentity.remote(serverID: s.serverID.uuidString, libraryUUID: s.libraryUUID, bookID: 50)
        let window = FakeViewerWindow()
        #expect(ViewerWindowRegistry.shared.beginOpen(identity))
        ViewerWindowRegistry.shared.finishOpen(identity, controller: window)
        defer { ViewerWindowRegistry.shared.unregister(controller: window) }

        s.openViewer(book: remoteBook(id: 50, filename: "a.zip", lastPage: 0))

        #expect(window.focused == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!G60ViewerTokenStub.paths.contains { $0.hasSuffix("/viewer-token") })
        #expect(launches.entries.isEmpty)
        #expect(fallbacks.entries.isEmpty)
    }
}
