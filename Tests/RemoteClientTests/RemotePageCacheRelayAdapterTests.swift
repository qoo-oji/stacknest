// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient
import AppCore
import LibraryServerAPI

/// 内蔵ビューアのページの取得を数えるスタブ。ほかのスイートの `StubURLProtocol` と記録を分ける（並行に走っても混ざらない）。
final class RelaySharingStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedCount = 0
    nonisolated(unsafe) private static var storedBody = Data()

    static var requestCount: Int { lock.withLock { storedCount } }
    static func reset(body: Data = Data([0xFF, 0xD8, 0x99])) {
        lock.withLock { storedCount = 0; storedBody = body }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data = Self.lock.withLock {
            Self.storedCount += 1
            return Self.storedBody
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 呼ばれた回数を数える箱（`@Sendable` の閉包から触る）。
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// G60 §5.9（2026-10-08 作者の決定）: 中継（127.0.0.1 の口）と内蔵ビューアは、同じキーでリモートのページの
/// キャッシュを分け合う。どちらが入れたページも、もう一方が取りに行かずに使う。
@Suite("G60 §5.9: 中継と内蔵ビューアのページのキャッシュ", .serialized)
struct RemotePageCacheRelayAdapterTests {
    private let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func tempCache(limit: Int64 = 0) -> RemotePageCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rpc-relay-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RemotePageCache(baseDirectory: dir, limitBytes: limit, maxAgeSeconds: 0)
    }

    private func client() -> RemoteLibraryClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelaySharingStub.self]
        return RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "d",
                                   session: URLSession(configuration: cfg))
    }

    private func target(etag: String = "\"e1\"") -> ViewerRelayTarget {
        ViewerRelayTarget(serverID: serverID, serverBase: URL(string: "http://h:8080/")!, libraryUUID: "LIB",
                          bookID: 42, remoteToken: "REMOTE-SECRET", pageCount: 10, manifestETag: etag)
    }

    /// 内蔵ビューアが本を開くときと同じ組み立て（`RemoteLibraryState.openViewer` の `RemoteBookContent`）。
    private func builtIn(_ cache: RemotePageCache, etag: String = "\"e1\"") -> RemoteBookContent {
        RemoteBookContent(client: client(), serverID: serverID, libraryUUID: "LIB", bookID: 42, libraryToken: nil,
                          maxWidth: RemoteViewerPage.maxWidth,
                          snapshot: RemoteBookSnapshot(manifest: ManifestDTO(pageCount: 10, direction: "rtl",
                                                                             format: "archive", etag: etag)),
                          cache: cache)
    }

    @Test func relayStoredPageIsABuiltInHit() async throws {
        let cache = tempCache()
        let adapter = RemotePageCacheRelayAdapter { cache }
        let bytes = Data([0xFF, 0xD8, 0x01])
        await adapter.storePage(bytes, for: ViewerRelayPageKey(target: target(), page: 3))
        RelaySharingStub.reset()
        let data = try await builtIn(cache).imageData(at: 3)
        #expect(data == bytes)
        #expect(RelaySharingStub.requestCount == 0, "中継が入れたページを内蔵ビューアが取りに行かずに使う")
    }

    @Test func builtInStoredPageIsARelayHit() async throws {
        let cache = tempCache()
        let adapter = RemotePageCacheRelayAdapter { cache }
        let bytes = Data([0xFF, 0xD8, 0x02])
        RelaySharingStub.reset(body: bytes)
        _ = try await builtIn(cache).imageData(at: 4)
        #expect(RelaySharingStub.requestCount == 1)
        #expect(await adapter.cachedPage(ViewerRelayPageKey(target: target(), page: 4)) == bytes,
                "内蔵ビューアが入れたページを中継が使う")
    }

    /// 版（manifest の etag）が違えば当たらない（差し替えた本の古いページを出さない）。
    @Test func aDifferentVersionMisses() async throws {
        let cache = tempCache()
        let adapter = RemotePageCacheRelayAdapter { cache }
        await adapter.storePage(Data([1]), for: ViewerRelayPageKey(target: target(etag: "\"e1\""), page: 3))
        RelaySharingStub.reset(body: Data([2]))
        let data = try await builtIn(cache, etag: "\"e2\"").imageData(at: 3)
        #expect(data == Data([2]))
        #expect(RelaySharingStub.requestCount == 1)
        #expect(await adapter.cachedPage(ViewerRelayPageKey(target: target(etag: "\"e2\""), page: 3)) == Data([2]))
        #expect(await adapter.cachedPage(ViewerRelayPageKey(target: target(etag: "\"e1\""), page: 3)) == Data([1]))
    }

    /// 版の剥がし方は内蔵ビューアと中継で 1 つ（`RemoteBookContent.normalizeVersion` は AppCore に任せる）。
    @Test func builtInVersionUsesTheSharedNormalizer() {
        for raw in ["\"e1\"", "e1", "\"", "\"\"", "\"e1"] {
            #expect(RemoteBookContent.normalizeVersion(raw) == RemoteViewerPage.version(fromManifestETag: raw))
        }
        #expect(builtIn(tempCache()).versionValue == ViewerRelayPageKey(target: target(), page: 0).version)
    }

    /// 先読みが取らずに済ませるページ（その本・その版・内蔵の幅）。どちらが入れた分も数える。
    @Test func cachedPageIndicesCountBothViewers() async throws {
        let cache = tempCache()
        let adapter = RemotePageCacheRelayAdapter { cache }
        await adapter.storePage(Data([1]), for: ViewerRelayPageKey(target: target(), page: 1))
        RelaySharingStub.reset()
        _ = try await builtIn(cache).imageData(at: 2)
        #expect(await adapter.cachedPageIndices(for: target()) == [1, 2])
        #expect(await adapter.cachedPageIndices(for: target(etag: "\"e9\"")).isEmpty)
    }

    /// 中継が入れても、上限の退避は内蔵と同じに走る（1 冊ごとの上限は無く、1 冊が上限を超えても古い順に消えるだけ）。
    @Test func storingEvictsToTheLimitLikeTheBuiltIn() async {
        let cache = tempCache(limit: 250)
        let adapter = RemotePageCacheRelayAdapter { cache }
        for page in 0..<3 {
            await adapter.storePage(Data(count: 100), for: ViewerRelayPageKey(target: target(), page: page))
        }
        #expect(await cache.totalBytes() <= 250)
    }

    /// 消し方は内蔵と同じ: 本を消したとき（`deleteBook`）と「今すぐ空にする」（`clearAll`）で中継が入れた分も消える。
    @Test func deletingTheBookOrClearingSweepsRelayPages() async {
        let cache = tempCache()
        let adapter = RemotePageCacheRelayAdapter { cache }
        let key = ViewerRelayPageKey(target: target(), page: 5)
        await adapter.storePage(Data([5]), for: key)
        await cache.deleteBook(serverID: serverID, libraryUUID: "LIB", bookID: 42)
        #expect(await adapter.cachedPage(key) == nil)
        await adapter.storePage(Data([5]), for: key)
        await cache.clearAll()
        #expect(await adapter.cachedPage(key) == nil)
    }

    /// 本物のキャッシュは使うときに引く（`LocalControlController()` を作るだけのテストで置き場を作らない）。
    @Test func theCacheIsResolvedOnlyWhenUsed() async {
        let calls = CallCount()
        let cache = tempCache()
        let adapter = RemotePageCacheRelayAdapter { calls.bump(); return cache }
        #expect(calls.value == 0)
        _ = await adapter.cachedPage(ViewerRelayPageKey(target: target(), page: 0))
        #expect(calls.value == 1)
    }
}
