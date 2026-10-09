// SPDX-License-Identifier: MIT
import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// 中継先（リモートのサーバ）の代わり（このファイル専用・`RelayRemoteStub` と記録を分ける）。
/// 応答は「パス?クエリ」で引き、無ければパスだけで引く（どちらも無ければ 404）。
final class RelayCacheRemoteStub: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// この状態コードの応答は、通信の失敗（届かない）として返す。
        static let unreachable = -1
    }
    struct Seen: Sendable {
        let url: URL
        let headers: [String: String]
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedResponses: [String: Canned] = [:]
    nonisolated(unsafe) private static var storedSeen: [Seen] = []

    static var responses: [String: Canned] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }
    static var seen: [Seen] { lock.withLock { storedSeen } }
    static func reset() { lock.withLock { storedResponses = [:]; storedSeen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let seen = Seen(url: url, headers: request.allHTTPHeaderFields ?? [:])
        Self.lock.withLock { Self.storedSeen.append(seen) }
        let withQuery = url.path + (url.query.map { "?" + $0 } ?? "")
        let canned = Self.responses[withQuery] ?? Self.responses[url.path] ?? Canned(status: 404)
        if canned.status == Canned.unreachable {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                   headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 中継のテスト用のページのキャッシュ（メモリだけ）。引いた回数・入れた回数を数える。
actor FakeRelayPageCache: ViewerRelayPageCache {
    private(set) var pages: [ViewerRelayPageKey: Data] = [:]
    private(set) var lookups = 0
    private(set) var stores = 0

    func put(_ data: Data, for key: ViewerRelayPageKey) { pages[key] = data }

    func cachedPage(_ key: ViewerRelayPageKey) -> Data? {
        lookups += 1
        return pages[key]
    }
    func storePage(_ data: Data, for key: ViewerRelayPageKey) {
        stores += 1
        pages[key] = data
    }
    func cachedPageIndices(for target: ViewerRelayTarget) -> Set<Int> {
        let probe = ViewerRelayPageKey(target: target, page: 0)
        return Set(pages.keys.filter {
            $0.serverID == probe.serverID && $0.libraryUUID == probe.libraryUUID && $0.bookID == probe.bookID
                && $0.maxw == probe.maxw && $0.version == probe.version
        }.map(\.page))
    }
}

/// 開くまで `wait` が戻らない門。
actor RelayTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

actor RelayCallCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// G60 §5.9（2026-10-08 作者の決定）: 中継の `pages/{n}` を、内蔵ビューアと分け合うキャッシュから返す。
/// スタブの記録を共有するので直列に走らせる。
@Suite("G60 §5.9: 中継のページのキャッシュ", .serialized, .timeLimit(.minutes(1)))
struct ViewerRelayCacheTests {
    private static let viewerHeader = HTTPField.Name("X-StackNest-Viewer")!
    private static let lockedHeader = HTTPField.Name("X-Library-Locked")!
    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0x42])
    private let remoteBook = "/api/v1/libraries/LIB-R/books/42"
    private let remoteOrigin = "http://100.64.0.5:51234"

    struct Fixture: Sendable {
        let store: ViewerTokenStore
        let registry: ViewerRelayRegistry
        let target: ViewerRelayTarget
        let relayID: String
        let token: String
        let done: @Sendable () -> Void
    }

    func makeFixture(pageCount: Int = 20, etag: String = "\"e1\"") -> Fixture {
        let name = "g60-relay-cache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = ViewerTokenStore(defaults: defaults)
        let registry = ViewerRelayRegistry()
        let target = ViewerRelayTarget(
            serverID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            serverBase: URL(string: "http://100.64.0.5:51234/")!,
            libraryUUID: "LIB-R", bookID: 42, remoteToken: "REMOTE-SECRET",
            pageCount: pageCount, manifestETag: etag)
        let relayID = registry.register(target)
        let issued = store.issue(libraryUUID: ViewerTokenRecord.relaySentinelLibraryUUID,
                                 bookID: ViewerTokenRecord.relaySentinelBookID, issuer: .localEndpoint,
                                 lockCredential: nil, relayID: relayID)
        RelayCacheRemoteStub.reset()
        return Fixture(store: store, registry: registry, target: target, relayID: relayID, token: issued.token,
                       done: { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) })
    }

    func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayCacheRemoteStub.self]
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg)
    }

    func makeRelay(_ fx: Fixture, cache: (any ViewerRelayPageCache)?,
                   tuning: ViewerRelayPrefetcher.Tuning = ViewerRelayPrefetcher.Tuning(),
                   wholeBook: Bool = true,
                   maxResponseBytes: Int = ViewerRelayConfig.defaultMaxResponseBytes) -> ViewerRelayConfig {
        ViewerRelayConfig(registry: fx.registry, session: session(), maxResponseBytes: maxResponseBytes,
                          pageCache: cache, prefetchTuning: tuning,
                          wholeBookPrefetch: { wholeBook })
    }

    func makeApp(_ fx: Fixture, relay: ViewerRelayConfig,
                 acceptsPrincipalTokens: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(host: "127.0.0.1", port: 0, token: "unused-read", editToken: "cli-token",
                          apiOnly: true, adminTier: true,
                          viewerTokens: fx.store, viewerTokenIssuer: .localEndpoint,
                          acceptsPrincipalTokens: acceptsPrincipalTokens, viewerRelay: relay),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    private func key(_ fx: Fixture, _ n: Int) -> ViewerRelayPageKey { ViewerRelayPageKey(target: fx.target, page: n) }

    private func issueRelayToken(_ fx: Fixture, relayID: String) -> String {
        fx.store.issue(libraryUUID: ViewerTokenRecord.relaySentinelLibraryUUID,
                       bookID: ViewerTokenRecord.relaySentinelBookID, issuer: .localEndpoint,
                       lockCredential: nil, relayID: relayID).token
    }

    /// `maxw` の無い要求は、内蔵ビューアと同じ形（`maxw=1600`・`v=<版>`）でリモートから取ってキャッシュに入れ、
    /// 2 回目からはリモートへ行かない。`maxw=1600` の要求も同じキャッシュに当たる。応答に `ETag` は付けない。
    @Test func cachedPathAsksForTheBuiltInVariantAndStores() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = [
            "\(remoteBook)/pages/3": .init(status: 200, headers: ["Content-Type": "image/jpeg", "ETag": "\"x\""],
                                           body: Self.jpeg),
        ]
        let base = "/api/v1/relay/\(fx.relayID)"
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            try await client.execute(uri: "\(base)/pages/3", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)", .ifNoneMatch: "\"x\"",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .ok)
                #expect(Data(buffer: r.body) == Self.jpeg)
                #expect(r.headers[.contentType] == "image/jpeg")
                #expect(r.headers[.eTag] == nil, "キャッシュの道は ETag を付けない")
            }
            for uri in ["\(base)/pages/3", "\(base)/pages/3?maxw=1600", "\(base)/pages/3?maxw=abc"] {
                try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == .ok, "\(uri)")
                    #expect(Data(buffer: r.body) == Self.jpeg, "\(uri)")
                }
            }
        }
        let seen = RelayCacheRemoteStub.seen
        #expect(seen.map(\.url.absoluteString) == ["\(remoteOrigin)\(remoteBook)/pages/3?maxw=1600&v=e1"],
                "1 回だけ・内蔵ビューアと同じ幅と版で取る")
        #expect(seen.first?.header("Authorization") == "Bearer REMOTE-SECRET")
        #expect(seen.first?.header("X-StackNest-Viewer") == "com.example.viewer/1.80; format=1")
        #expect(seen.first?.header("If-None-Match") == nil, "キャッシュの道はバイトが要るので If-None-Match を渡さない")
        #expect(await cache.pages[key(fx, 3)] == Self.jpeg)
        #expect(await cache.stores == 1)
    }

    /// キャッシュにあっても、中継の関門（その relayID の中継の鍵・中継の記録が期限内）を通らない要求には返さない。
    /// 関門で止まった要求はキャッシュを引きもしない。
    @Test func cachedPagesStillNeedTheRelayToken() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        await cache.put(Self.jpeg, for: key(fx, 3))
        let other = fx.registry.register(ViewerRelayTarget(
            serverID: UUID(), serverBase: URL(string: "http://100.64.0.5:51234/")!,
            libraryUUID: "LIB-R", bookID: 43, remoteToken: "OTHER-SECRET"))
        let otherToken = issueRelayToken(fx, relayID: other)
        let bookToken = fx.store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .localEndpoint,
                                       lockCredential: nil).token
        // 同じ本・同じ版の中継（キャッシュのキーは同じ）だが、期限が切れている。
        let expired = fx.registry.register(fx.target, expiresAt: Date().addingTimeInterval(-1))
        let expiredToken = issueRelayToken(fx, relayID: expired)
        let orphanToken = issueRelayToken(fx, relayID: "GONE")
        let cases: [(String?, String, HTTPResponse.Status)] = [
            (nil, "/api/v1/relay/\(fx.relayID)/pages/3", .unauthorized),
            ("not-a-token", "/api/v1/relay/\(fx.relayID)/pages/3", .unauthorized),
            ("cli-token", "/api/v1/relay/\(fx.relayID)/pages/3", .forbidden),
            (bookToken, "/api/v1/relay/\(fx.relayID)/pages/3", .forbidden),
            (otherToken, "/api/v1/relay/\(fx.relayID)/pages/3", .forbidden),
            (expiredToken, "/api/v1/relay/\(expired)/pages/3", .unauthorized),
            (orphanToken, "/api/v1/relay/GONE/pages/3", .unauthorized),
        ]
        try await makeApp(fx, relay: makeRelay(fx, cache: cache), acceptsPrincipalTokens: true).test(.router) { client in
            for (token, uri, expected) in cases {
                var headers = HTTPFields()
                if let token { headers[.authorization] = "Bearer \(token)" }
                try await client.execute(uri: uri, method: .get, headers: headers) { r in
                    #expect(r.status == expected, "\(uri) \(token ?? "no token")")
                    #expect(Data(buffer: r.body) != Self.jpeg, "キャッシュのバイトを返さない")
                }
            }
        }
        #expect(await cache.lookups == 0, "関門で止まった要求はキャッシュを引かない")
        #expect(RelayCacheRemoteStub.seen.isEmpty)
        // 対照: その中継の鍵なら、リモートへ行かずにキャッシュから返す。
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/3", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
                #expect(Data(buffer: r.body) == Self.jpeg)
            }
        }
        #expect(await cache.lookups == 1)
        #expect(RelayCacheRemoteStub.seen.isEmpty)
    }

    /// リモートが `no-store`（`v` が今の版と違う＝本の差し替えの直後）を返したら、ビューアへは返すがキャッシュに入れない
    /// （内蔵ビューアの `RemoteBookContent.imageData` と同じ）。
    @Test func noStoreIsServedButNotStored() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = [
            "\(remoteBook)/pages/2": .init(status: 200, headers: ["Content-Type": "image/jpeg", "Cache-Control": "no-store"],
                                           body: Self.jpeg),
        ]
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            for _ in 0..<2 {
                try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/2", method: .get,
                                         headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == .ok)
                    #expect(Data(buffer: r.body) == Self.jpeg)
                }
            }
        }
        #expect(await cache.stores == 0)
        #expect(RelayCacheRemoteStub.seen.count == 2, "入れていないので 2 回目も取りに行く")
        #expect(RelayCacheRemoteStub.seen.allSatisfy { $0.url.query == "maxw=1600&v=e1" }, "キャッシュの道で取っている")
    }

    /// キャッシュの道でも、リモートの 200 以外は状態コード・`X-Library-Locked` をそのまま返し、入れない。
    /// リダイレクトは辿らず 502。
    /// 作者の決定（2026-10-10）で 401・403 は中継を閉じるので、場合ごとに中継を分ける（閉じた後の振る舞いは
    /// `anUpstreamRefusalClosesTheRelayEvenForCachedPages`）。
    @Test func remoteErrorsOnTheCachedPathPassThroughUnstored() async throws {
        let responses: [String: RelayCacheRemoteStub.Canned] = [
            "\(remoteBook)/pages/1": .init(status: 401),
            "\(remoteBook)/pages/2": .init(status: 403,
                                           headers: ["X-Library-Locked": "1", "Content-Type": "text/plain",
                                                     "Set-Cookie": "sid=secret", "X-Other": "leak"],
                                           body: Data("locked".utf8)),
            "\(remoteBook)/pages/3": .init(status: 500),
            "\(remoteBook)/pages/4": .init(status: 302, headers: ["Location": "http://evil.example/steal"]),
            // pages/9 は無い → 404
        ]
        let expected: [(Int, HTTPResponse.Status)] = [
            (1, .unauthorized), (2, .forbidden), (3, .internalServerError), (4, .badGateway), (9, .notFound),
        ]
        for (n, status) in expected {
          let fx = makeFixture(); defer { fx.done() }
          let cache = FakeRelayPageCache()
          RelayCacheRemoteStub.responses = responses
          try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
                try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/\(n)", method: .get,
                                         headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == status, "pages/\(n)")
                    if n == 2 {
                        #expect(r.headers[Self.lockedHeader] == "1")
                        #expect(r.headers[.contentType] == "text/plain", "許可リストの Content-Type は写す")
                        #expect(String(decoding: Data(buffer: r.body), as: UTF8.self) == "locked", "本文はそのまま")
                        #expect(r.headers[.setCookie] == nil, "許可リスト外のヘッダは写さない")
                        #expect(r.headers[HTTPField.Name("X-Other")!] == nil, "許可リスト外のヘッダは写さない")
                    }
                }
          }
          #expect(await cache.stores == 0, "pages/\(n)")
          #expect(RelayCacheRemoteStub.seen.allSatisfy { $0.url.query == "maxw=1600&v=e1" }, "キャッシュの道で取っている")
          #expect((fx.registry.target(for: fx.relayID) == nil) == (status == .unauthorized || status == .forbidden),
                  "401・403 だけが中継を閉じる（pages/\(n)）")
        }
    }

    /// ほかの `maxw` は今までどおり取り次ぐ（`v` を付けない・`If-None-Match` を渡す・キャッシュを引かない）。
    @Test func otherMaxwStaysPassThrough() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = [
            "\(remoteBook)/pages/3": .init(status: 200, headers: ["Content-Type": "image/jpeg", "ETag": "\"p3\""],
                                           body: Self.jpeg),
        ]
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/3?maxw=800", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)", .ifNoneMatch: "\"p0\""]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.eTag] == "\"p3\"")
            }
        }
        let seen = RelayCacheRemoteStub.seen
        #expect(seen.map(\.url.absoluteString) == ["\(remoteOrigin)\(remoteBook)/pages/3?maxw=800"])
        #expect(seen.first?.header("If-None-Match") == "\"p0\"")
        #expect(await cache.lookups == 0)
        #expect(await cache.stores == 0)
    }

    /// キャッシュを渡さない形（§5.8 のまま）は、`maxw` の無い要求も今までどおり素通し（原寸）。
    @Test func withoutACacheEverythingStaysPassThrough() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayCacheRemoteStub.responses = ["\(remoteBook)/pages/2": .init(status: 200, body: Self.jpeg)]
        try await makeApp(fx, relay: makeRelay(fx, cache: nil)).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/2", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(RelayCacheRemoteStub.seen.map(\.url.absoluteString) == ["\(remoteOrigin)\(remoteBook)/pages/2"])
    }

    /// ビューアが manifest を読み直したら（素通しした応答）、中継の記録のページ数と版をその manifest に合わせ、
    /// 以後のページはその版で引く（内蔵ビューアが「開いた時点の manifest」の版で引くのと同じ）。読めない本文なら変えない。
    @Test func manifestPassThroughMovesTheVersion() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"pageCount":25,"direction":"rtl","format":"archive","etag":"\"e2\""}"#.utf8)),
            "\(remoteBook)/pages/0": .init(status: 200, body: Self.jpeg),
        ]
        let base = "/api/v1/relay/\(fx.relayID)"
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
                #expect(String(decoding: Data(buffer: r.body), as: UTF8.self).contains(#""pageCount":25"#),
                        "本文はそのまま返す")
            }
            try await client.execute(uri: "\(base)/pages/0", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        let t = try #require(fx.registry.target(for: fx.relayID))
        #expect(t.pageCount == 25)
        #expect(t.manifestETag == "\"e2\"")
        #expect(t.remoteToken == "REMOTE-SECRET")
        #expect(RelayCacheRemoteStub.seen.last?.url.query == "maxw=1600&v=e2")
        #expect(await cache.pages[ViewerRelayPageKey(target: t, page: 0)] == Self.jpeg)

        // 読めない manifest（項目の足りない {}）は記録を変えない。
        RelayCacheRemoteStub.responses = ["\(remoteBook)/manifest": .init(status: 200, body: Data("{}".utf8))]
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { _ in }
        }
        #expect(fx.registry.target(for: fx.relayID)?.manifestETag == "\"e2\"")
    }

    /// サーバが `?v=` と比べる剥がし方（`stripETagQuotes`）と、中継が `?v=` を作る剥がし方は同じ。
    @Test func serverAndRelayStripQuotesTheSameWay() {
        for raw in ["\"e1\"", "e1", "\"", "\"\"", "\"e1"] {
            #expect(stripETagQuotes(raw) == RemoteViewerPage.version(fromManifestETag: raw))
        }
    }

    /// 同じページを同時に頼まれたら（ビューアと先読み）、リモートへは 1 回だけ取りに行き、両方が同じ結果を受け取る。
    @Test(.timeLimit(.minutes(1))) func concurrentRequestsForOnePageFetchOnce() async {
        let fx = makeFixture(); defer { fx.done() }
        let loader = ViewerRelayPageLoader()
        let pageKey = key(fx, 3)
        let gate = RelayTestGate()
        let calls = RelayCallCounter()
        let bytes = Self.jpeg
        async let first = loader.load(pageKey, relayID: "R1") {
            await calls.bump()
            await gate.wait()
            return .fetched(bytes, stored: true)
        }
        // 1 本目が取り中になってから 2 本目を頼み、相乗りしたのを見てから門を開ける。
        while await loader.inFlightCount == 0 { await Task.yield() }
        async let second = loader.load(pageKey, relayID: "R1") {
            await calls.bump()
            return .fetched(Data([0]), stored: true)
        }
        while await loader.joinedCount(for: pageKey, relayID: "R1") == 0 { await Task.yield() }
        await gate.open()
        let (a, b) = await (first, second)
        #expect(await calls.value == 1)
        guard case .fetched(let da, _) = a, case .fetched(let db, _) = b else {
            Issue.record("取れていない"); return
        }
        #expect(da == bytes)
        #expect(db == bytes)
        #expect(await loader.inFlightCount == 0)
    }

    /// 作者の決定（2026-10-10・最終レビュー m2）: 相乗りは中継ごと。別の中継が同じページを同時に頼んだら、それぞれが
    /// 自分のリモートの鍵で取りに行く（古い中継が断られた結果を、新しい中継が受け取って閉じないように）。
    @Test(.timeLimit(.minutes(1))) func requestsFromDifferentRelaysDoNotShareAFetch() async {
        let fx = makeFixture(); defer { fx.done() }
        let loader = ViewerRelayPageLoader()
        let pageKey = key(fx, 3)
        let gate = RelayTestGate()
        let calls = RelayCallCounter()
        async let old = loader.load(pageKey, relayID: "OLD") {
            await calls.bump()
            await gate.wait()
            return .upstream(status: 401, headers: HTTPFields(), body: Data())
        }
        while await loader.inFlightCount == 0 { await Task.yield() }
        async let new = loader.load(pageKey, relayID: "NEW") {
            await calls.bump()
            return .fetched(Self.jpeg, stored: true)
        }
        // 中継ごとなら 2 本が取り中になる。相乗りしてしまう作りでは 1 本のままなので、期限で見切って門を開ける
        // （試験を止めずに、取りに行った回数で落とす）。
        let deadline = ContinuousClock.now + .seconds(2)
        while await loader.inFlightCount < 2, ContinuousClock.now < deadline { await Task.yield() }
        await gate.open()
        let (a, b) = await (old, new)
        #expect(await calls.value == 2)
        guard case .upstream(401, _, _) = a, case .fetched(let data, _) = b else {
            Issue.record("中継ごとの結果になっていない"); return
        }
        #expect(data == Self.jpeg)
    }

    /// 作者の決定（2026-10-10・Codex P1）: 上流に 401・403 で断られたら、その中継を閉じる。断った応答そのものは
    /// そのまま返し（施錠の印も）、以後はキャッシュにあるページも含めて 401（「StackNest から開き直して」）。
    /// ページ（キャッシュの道）・manifest（素通し）のどちらで断られても閉じる。
    @Test(arguments: ["pages/5", "manifest"])
    func anUpstreamRefusalClosesTheRelayEvenForCachedPages(_ refusedPath: String) async throws {
        for (status, headers) in [(401, [String: String]()), (403, ["X-Library-Locked": "1"])] {
            let fx = makeFixture(); defer { fx.done() }
            let cache = FakeRelayPageCache()
            await cache.put(Self.jpeg, for: key(fx, 3))
            RelayCacheRemoteStub.responses = ["\(remoteBook)/\(refusedPath)": .init(status: status, headers: headers)]
            let base = "/api/v1/relay/\(fx.relayID)"
            let auth: HTTPFields = [.authorization: "Bearer \(fx.token)"]
            try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
                try await client.execute(uri: "\(base)/pages/3", method: .get, headers: auth) { r in
                    #expect(r.status == .ok, "断られる前はキャッシュから返す")
                }
                try await client.execute(uri: "\(base)/\(refusedPath)", method: .get, headers: auth) { r in
                    #expect(Int(r.status.code) == status, "断った応答はそのまま（\(refusedPath)・\(status)）")
                    if status == 403 { #expect(r.headers[Self.lockedHeader] == "1") }
                }
                try await client.execute(uri: "\(base)/pages/3", method: .get, headers: auth) { r in
                    #expect(r.status == .unauthorized, "閉じた中継はキャッシュにあるページも返さない（\(refusedPath)・\(status)）")
                    #expect(Data(buffer: r.body) != Self.jpeg)
                }
            }
            #expect(fx.registry.target(for: fx.relayID) == nil)
        }
    }

    // MARK: - 先読み（Task 3）

    /// 設定が ON なら、先読みは中継自身の道（リモートの鍵・内蔵の幅と版）で全ページを取り、キャッシュに入れる。
    /// 名乗りは付けない。キャッシュにあるページは取らない。入れた後のビューアの要求はリモートへ行かない。
    @Test func prefetchFillsTheCacheThroughTheRelay() async throws {
        let fx = makeFixture(pageCount: 4); defer { fx.done() }
        let cache = FakeRelayPageCache()
        await cache.put(Self.jpeg, for: key(fx, 2))   // 内蔵ビューアが読んだ分
        var responses: [String: RelayCacheRemoteStub.Canned] = [:]
        for n in 0..<4 { responses["\(remoteBook)/pages/\(n)"] = .init(status: 200, body: Data([UInt8(n)])) }
        RelayCacheRemoteStub.responses = responses
        let relay = makeRelay(fx, cache: cache)

        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await relay.prefetcher?.waitUntilIdle()

        let seen = RelayCacheRemoteStub.seen
        #expect(Set(seen.map(\.url.path)) == ["\(remoteBook)/pages/0", "\(remoteBook)/pages/1", "\(remoteBook)/pages/3"])
        #expect(seen.count == 3, "1 枚 1 回・キャッシュにある 2 は取らない")
        #expect(seen.allSatisfy { $0.url.query == "maxw=1600&v=e1" })
        #expect(seen.allSatisfy { $0.header("Authorization") == "Bearer REMOTE-SECRET" })
        #expect(seen.allSatisfy { $0.header("X-StackNest-Viewer") == nil }, "先読みはビューアの要求ではない")
        for n in 0..<4 { #expect(await cache.pages[key(fx, n)] != nil, "pages/\(n)") }

        try await makeApp(fx, relay: relay).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/3", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(Data(buffer: r.body) == Data([3]))
            }
        }
        #expect(RelayCacheRemoteStub.seen.count == 3, "先読みした後はリモートへ行かない")
    }

    /// 設定が OFF（既定）なら、中継の先読みは内蔵ビューアと同じ近傍だけ: 渡した時点は開くページのまわり、
    /// ビューアがページを頼んだら、そのページのまわり。遠くのページは取らない。
    @Test func withTheSettingOffTheRelayPrefetchesOnlyAroundTheViewer() async throws {
        let fx = makeFixture(pageCount: 30); defer { fx.done() }
        let cache = FakeRelayPageCache()
        var responses: [String: RelayCacheRemoteStub.Canned] = [:]
        for n in 0..<30 { responses["\(remoteBook)/pages/\(n)"] = .init(status: 200, body: Data([UInt8(n)])) }
        RelayCacheRemoteStub.responses = responses
        let relay = makeRelay(fx, cache: cache, wholeBook: false)
        func fetchedPages() -> Set<Int> {
            Set(RelayCacheRemoteStub.seen.compactMap { Int($0.url.lastPathComponent) })
        }

        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await relay.prefetcher?.waitUntilIdle()
        #expect(fetchedPages() == [1, 2, 3, 4, 5, 6, 9, 10, 11], "開くページ（0）のまわりだけ")

        try await makeApp(fx, relay: relay).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/20", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        await relay.prefetcher?.waitUntilIdle()
        // 20 はビューアの要求。そのまわり（21〜26・19・18・29。9〜11 は取ってある）を足す。15 などの遠くは取らない。
        #expect(fetchedPages() == [1, 2, 3, 4, 5, 6, 9, 10, 11, 20, 21, 22, 23, 24, 25, 26, 19, 18, 29])
        #expect(RelayCacheRemoteStub.seen.count == 19, "1 枚 1 回")
    }

    /// リモートが断ったら（施錠の 403 など）先読みは止まり、理由を覚える。その後はビューアがページを頼んでも
    /// 先読みは始め直さない（リモートへ行くのはビューアの要求の 1 回だけ）。
    @Test func prefetchStopsWhenTheRemoteRefuses() async throws {
        let fx = makeFixture(pageCount: 10); defer { fx.done() }
        let cache = FakeRelayPageCache()
        var responses: [String: RelayCacheRemoteStub.Canned] = [:]
        for n in 0..<10 { responses["\(remoteBook)/pages/\(n)"] = .init(status: 200, body: Data([UInt8(n)])) }
        responses["\(remoteBook)/pages/1"] = .init(status: 403, headers: ["X-Library-Locked": "1"])
        RelayCacheRemoteStub.responses = responses
        let relay = makeRelay(fx, cache: cache, tuning: .init(concurrency: 1))

        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await relay.prefetcher?.waitUntilIdle()

        #expect(RelayCacheRemoteStub.seen.map(\.url.path) == ["\(remoteBook)/pages/1"])
        #expect(await cache.stores == 0)
        #expect(await relay.prefetcher?.stopReason(for: fx.relayID) == .refused)

        // 作者の決定（2026-10-10）: 先読みが断られたら中継を閉じる。以後のビューアの要求は 401 で、リモートへも行かない。
        #expect(fx.registry.target(for: fx.relayID) == nil)
        try await makeApp(fx, relay: relay).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/5", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
        await relay.prefetcher?.waitUntilIdle()
        #expect(RelayCacheRemoteStub.seen.map(\.url.path) == ["\(remoteBook)/pages/1"], "閉じた中継はリモートへ行かない")
        #expect(await relay.prefetcher?.stopReason(for: fx.relayID) == .refused)
    }

    /// ビューアが manifest を読み直して版が変わったら、最後に渡した本の先読みは新しい版でし直す。
    @Test func aNewManifestVersionRestartsThePrefetch() async throws {
        let fx = makeFixture(pageCount: 2); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = [
            // 渡した時点の版（e1）は古い: サーバは今の版のバイトを no-store で返す → 先読みは止まる。
            "\(remoteBook)/pages/1?maxw=1600&v=e1": .init(status: 200, headers: ["Cache-Control": "no-store"], body: Data([9])),
            "\(remoteBook)/pages/0?maxw=1600&v=e1": .init(status: 200, headers: ["Cache-Control": "no-store"], body: Data([9])),
            "\(remoteBook)/manifest": .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"pageCount":2,"direction":"rtl","format":"archive","etag":"\"e2\""}"#.utf8)),
            "\(remoteBook)/pages/0?maxw=1600&v=e2": .init(status: 200, body: Data([0])),
            "\(remoteBook)/pages/1?maxw=1600&v=e2": .init(status: 200, body: Data([1])),
        ]
        let relay = makeRelay(fx, cache: cache, tuning: .init(concurrency: 1))
        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await relay.prefetcher?.waitUntilIdle()
        #expect(await cache.stores == 0, "古い版のバイトは入れない")
        #expect(RelayCacheRemoteStub.seen.count == 1, "no-store を見たら止まる")

        try await makeApp(fx, relay: relay).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        await relay.prefetcher?.waitUntilIdle()
        let t = try #require(fx.registry.target(for: fx.relayID))
        #expect(await cache.pages[ViewerRelayPageKey(target: t, page: 0)] == Data([0]))
        #expect(await cache.pages[ViewerRelayPageKey(target: t, page: 1)] == Data([1]))
    }

    /// 401・404・410 も、先読みは断られたものとして止まり、取り直さない（403 は上の `prefetchStopsWhenTheRemoteRefuses`）。
    @Test(arguments: [401, 404, 410])
    func prefetchStopsOnTerminalStatuses(_ status: Int) async throws {
        let fx = makeFixture(pageCount: 6); defer { fx.done() }
        let cache = FakeRelayPageCache()
        var responses: [String: RelayCacheRemoteStub.Canned] = [:]
        for n in 0..<6 { responses["\(remoteBook)/pages/\(n)"] = .init(status: 200, body: Data([UInt8(n)])) }
        responses["\(remoteBook)/pages/1"] = .init(status: status)
        RelayCacheRemoteStub.responses = responses
        let relay = makeRelay(fx, cache: cache, tuning: .init(concurrency: 1))
        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await relay.prefetcher?.waitUntilIdle()
        #expect(RelayCacheRemoteStub.seen.map(\.url.path) == ["\(remoteBook)/pages/1"], "取り直さない")
        #expect(await relay.prefetcher?.stopReason(for: fx.relayID) == .refused)
        #expect(await cache.stores == 0)
    }

    /// ビューアが `maxw` のほかの幅で頼んだ（素通しする）ページも、先読みの中心を移す（そのまわりを先読みする）。
    @Test func aPassThroughPageRequestStillMovesThePrefetchCentre() async throws {
        let fx = makeFixture(pageCount: 40); defer { fx.done() }
        let cache = FakeRelayPageCache()
        var responses: [String: RelayCacheRemoteStub.Canned] = [:]
        for n in 0..<40 { responses["\(remoteBook)/pages/\(n)"] = .init(status: 200, body: Data([UInt8(n)])) }
        RelayCacheRemoteStub.responses = responses
        let relay = makeRelay(fx, cache: cache, wholeBook: false)
        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await relay.prefetcher?.waitUntilIdle()
        let before = RelayCacheRemoteStub.seen.count
        try await makeApp(fx, relay: relay).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/20?maxw=800", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        await relay.prefetcher?.waitUntilIdle()
        let after = RelayCacheRemoteStub.seen.dropFirst(before)
        let cachedPathPages = Set(after.filter { $0.url.query == "maxw=1600&v=e1" }.compactMap { Int($0.url.lastPathComponent) })
        #expect(cachedPathPages == [21, 22, 23, 24, 25, 26, 19, 18, 29, 30, 31], "中心が 20 に移り、そのまわりを先読みした")
    }

    /// カナリア: 先読みの本物の `sleep`（`makePrefetcher` が渡す閉包）を、ビューアの要求の待ちで実際に通す。
    /// async の既定引数の閉包がモジュールごとに食い違うと、最初の本物の待ちでプロセスごと異常終了する。
    /// つなぎが悪ければ落ち、良ければ落ちようがない（結果は変わらない）。
    @Test(.timeLimit(.minutes(1))) func canaryProductionSleepOnTheLiveRequestWait() async throws {
        let fx = makeFixture(pageCount: 4); defer { fx.done() }
        let cache = FakeRelayPageCache()
        var responses: [String: RelayCacheRemoteStub.Canned] = [:]
        for n in 0..<4 { responses["\(remoteBook)/pages/\(n)"] = .init(status: 200, body: Data([UInt8(n)])) }
        RelayCacheRemoteStub.responses = responses
        let relay = makeRelay(fx, cache: cache)
        let prefetcher = try #require(relay.prefetcher)
        await prefetcher.liveRequestBegan(relayID: "ANOTHER", page: 0)   // ビューアの要求を ~250 ms 保つ
        let ender = Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            await prefetcher.liveRequestEnded(relayID: "ANOTHER")
        }
        await relay.startPrefetch(relayID: fx.relayID, focus: 0)
        await prefetcher.waitUntilIdle()
        await ender.value
        for n in 0..<4 { #expect(await cache.pages[key(fx, n)] != nil, "pages/\(n)") }
    }

    // MARK: - 補強（Task 2 のレビュー）

    /// 最初に頼んだ側が取り消されても、取りに行く作業は最後まで走り、相乗りした側も同じ結果を受け取る
    /// （先読みを止めても取り中の 1 枚は入る、の土台）。
    @Test(.timeLimit(.minutes(1))) func loaderSurvivesCancellationOfTheFirstRequester() async {
        let fx = makeFixture(); defer { fx.done() }
        let loader = ViewerRelayPageLoader()
        let pageKey = key(fx, 3)
        let gate = RelayTestGate()
        let sawCancellation = RelayCallCounter()
        let bytes = Self.jpeg
        let first = Task {
            await loader.load(pageKey, relayID: "R1") {
                await gate.wait()
                if Task.isCancelled { await sawCancellation.bump() }
                return .fetched(bytes, stored: true)
            }
        }
        while await loader.inFlightCount == 0 { await Task.yield() }
        let second = Task {
            await loader.load(pageKey, relayID: "R1") { .fetched(Data([0]), stored: true) }
        }
        while await loader.joinedCount(for: pageKey, relayID: "R1") == 0 { await Task.yield() }
        first.cancel()
        await gate.open()
        let (a, b) = await (first.value, second.value)
        guard case .fetched(let da, let sa) = a, case .fetched(let db, let sb) = b else {
            Issue.record("取れていない"); return
        }
        #expect(da == bytes && db == bytes)
        #expect(sa && sb)
        #expect(await sawCancellation.value == 0, "作業は取り消しを見ない")
        #expect(await loader.inFlightCount == 0)
    }

    /// キャッシュの道でも、大きすぎる応答は 502 で入れない。
    @Test func cachedPathEnforcesTheResponseSizeLimit() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = ["\(remoteBook)/pages/1": .init(status: 200, body: Self.jpeg)]
        try await makeApp(fx, relay: makeRelay(fx, cache: cache, maxResponseBytes: 1)).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/1", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .badGateway)
            }
        }
        #expect(await cache.stores == 0)
        #expect(RelayCacheRemoteStub.seen.count == 1)
        #expect(RelayCacheRemoteStub.seen.allSatisfy { $0.url.query == "maxw=1600&v=e1" }, "キャッシュの道で取っている")
    }

    /// キャッシュの道でも、届かないリモートは 502 で入れない。
    @Test func cachedPathUnreachableRemoteIs502() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let cache = FakeRelayPageCache()
        RelayCacheRemoteStub.responses = [
            "\(remoteBook)/pages/1": .init(status: RelayCacheRemoteStub.Canned.unreachable),
        ]
        try await makeApp(fx, relay: makeRelay(fx, cache: cache)).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/pages/1", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .badGateway)
            }
        }
        #expect(RelayCacheRemoteStub.seen.count == 1, "取りには行った")
        #expect(RelayCacheRemoteStub.seen.allSatisfy { $0.url.query == "maxw=1600&v=e1" }, "キャッシュの道で取っている")
        #expect(await cache.stores == 0)
    }

    /// キャッシュを渡さない形では、manifest を素通ししても中継の記録（ページ数・版）を変えない（§5.8 のまま）。
    @Test func manifestPassThroughWithoutACacheLeavesTheRecordAlone() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayCacheRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"pageCount":25,"direction":"rtl","format":"archive","etag":"\"e2\""}"#.utf8)),
        ]
        try await makeApp(fx, relay: makeRelay(fx, cache: nil)).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        let t = try #require(fx.registry.target(for: fx.relayID))
        #expect(t.pageCount == 20)
        #expect(t.manifestETag == "\"e1\"")
    }
}
