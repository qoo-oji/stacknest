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

/// 中継先（リモートのサーバ）の代わり。パスごとに決めた応答を返し、届いた要求を記録する。
/// 記録は URLSession のスレッドとテストの両方から触るので `NSLock` で包む。
final class RelayRemoteStub: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }
    struct Seen: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedResponses: [String: Canned] = [:]
    nonisolated(unsafe) private static var storedSeen: [Seen] = []
    nonisolated(unsafe) private static var storedFailure: URLError.Code?

    /// キーは中継先の URL のパス。無いパスは 404。
    static var responses: [String: Canned] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }
    static var seen: [Seen] { lock.withLock { storedSeen } }
    /// 非 nil なら、応答の代わりにこの通信の失敗を返す。
    static var failure: URLError.Code? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }
    static func reset() {
        lock.withLock { storedResponses = [:]; storedSeen = []; storedFailure = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body = request.httpBody ?? Self.readAll(request.httpBodyStream)
        let seen = Seen(method: request.httpMethod ?? "", url: url,
                        headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.lock.withLock { Self.storedSeen.append(seen) }
        if let code = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let canned = Self.responses[url.path] ?? Canned(status: 404)
        let resp = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                   headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func readAll(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// G60 v3（spec §5.8・試用）: 127.0.0.1 の口が、中継の鍵で来た要求をリモートのサーバへ取り次ぐ。
/// スタブの記録を共有するので直列に走らせる。
@Suite("G60 v3: リモートの本の中継（127.0.0.1 の口）", .serialized)
struct ViewerRelayTests {
    private static let viewerHeader = HTTPField.Name("X-StackNest-Viewer")!
    private static let lockedHeader = HTTPField.Name("X-Library-Locked")!
    private let remoteBook = "/api/v1/libraries/LIB-R/books/42"
    private let remoteOrigin = "http://100.64.0.5:51234"

    private struct Fixture: Sendable {
        let store: ViewerTokenStore
        let registry: ViewerRelayRegistry
        let relayID: String
        let token: String
        let recordID: String
        let done: @Sendable () -> Void
    }

    private func makeFixture() -> Fixture {
        let name = "g60v3-relay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = ViewerTokenStore(defaults: defaults)
        let registry = ViewerRelayRegistry()
        let relayID = registry.register(ViewerRelayTarget(
            serverID: UUID(), serverBase: URL(string: "http://100.64.0.5:51234/")!,
            libraryUUID: "LIB-R", bookID: 42, remoteToken: "REMOTE-SECRET"))
        // 中継の鍵の記録は本物の書庫・本を持たない（見張り用の値）。実際の相手は中継の記録（`registry`）にだけある。
        let issued = store.issue(libraryUUID: ViewerTokenRecord.relaySentinelLibraryUUID,
                                 bookID: ViewerTokenRecord.relaySentinelBookID, issuer: .localEndpoint,
                                 lockCredential: nil, relayID: relayID)
        RelayRemoteStub.reset()
        return Fixture(store: store, registry: registry, relayID: relayID, token: issued.token,
                       recordID: issued.record.id,
                       // UserDefaults(suiteName:) は同じ名前なら同じ領域を指すので、閉包には名前だけを持たせる。
                       done: { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) })
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayRemoteStub.self]
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg)
    }

    /// 127.0.0.1 の口と同じ形。既定は「本専用トークンだけ」、`acceptsPrincipalTokens` で CLI のトークンも受ける形。
    /// `maxResponseBytes`・`maxRequestBytes` は既定（64 MiB・64 KiB）のまま、または小さくして上限を試す。
    private func makeApp(_ fx: Fixture, acceptsPrincipalTokens: Bool = false,
                         maxResponseBytes: Int = ViewerRelayConfig.defaultMaxResponseBytes,
                         maxRequestBytes: Int = ViewerRelayConfig.defaultMaxRequestBytes) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(host: "127.0.0.1", port: 0, token: "unused-read", editToken: "cli-token",
                          apiOnly: true, adminTier: true,
                          viewerTokens: fx.store, viewerTokenIssuer: .localEndpoint,
                          acceptsPrincipalTokens: acceptsPrincipalTokens,
                          viewerRelay: ViewerRelayConfig(registry: fx.registry, session: session(),
                                                         maxResponseBytes: maxResponseBytes,
                                                         maxRequestBytes: maxRequestBytes)),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    @Test func relayRouteTable() {
        func allows(_ m: HTTPRequest.Method, _ p: String) -> Bool {
            ViewerTokenRoutes.allowsRelay(method: m, path: p, relayID: "R-1")
        }
        let base = "/api/v1/relay/R-1"
        #expect(allows(.get, "\(base)/manifest"))
        #expect(allows(.get, "\(base)/cover"))
        #expect(allows(.get, "\(base)/pages/0"))
        #expect(allows(.get, "\(base)/pages/12"))
        #expect(allows(.post, "\(base)/progress"))
        #expect(!allows(.get, "\(base)/progress"))
        #expect(!allows(.post, "\(base)/manifest"))
        #expect(!allows(.get, "\(base)/pages/x"))
        #expect(!allows(.get, "\(base)/pages/-1"))
        #expect(!allows(.get, "\(base)/detail"))
        #expect(!allows(.get, "\(base)/manifest/"))
        #expect(!allows(.get, "/api/v1/relay/R-10/manifest"))
        #expect(!allows(.get, "/api/v1/libraries/LIB-R/books/42/manifest"))
        // 既存の routeTable と同じく、GET・POST 以外は通さない。
        #expect(!allows(.delete, "\(base)/manifest"))
        #expect(!allows(.patch, "\(base)/progress"))
        #expect(!allows(.put, "\(base)/progress"))
        #expect(!allows(.head, "\(base)/manifest"))
    }

    @Test func forwardsTheFourRequestsWithTheRemoteToken() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(status: 200, headers: ["Content-Type": "application/json", "ETag": "\"m1\""],
                                            body: Data(#"{"pageCount":20,"direction":"rtl","format":"archive","etag":"m1"}"#.utf8)),
            "\(remoteBook)/pages/3": .init(status: 200, headers: ["Content-Type": "image/jpeg", "ETag": "\"p3\""],
                                           body: Data([0xFF, 0xD8, 0xFF])),
            "\(remoteBook)/cover": .init(status: 200, headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50])),
            "\(remoteBook)/progress": .init(status: 200),
        ]
        let base = "/api/v1/relay/\(fx.relayID)"
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.contentType] == "application/json")
                #expect(r.headers[.eTag] == "\"m1\"")
                #expect(String(decoding: Data(buffer: r.body), as: UTF8.self).contains(#""pageCount":20"#))
            }
            // maxw だけを渡す（ほかのクエリは渡さない）。
            try await client.execute(uri: "\(base)/pages/3?maxw=800&other=x", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)", .ifNoneMatch: "\"p0\""]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.contentType] == "image/jpeg")
                #expect(r.headers[.eTag] == "\"p3\"")
                #expect(Data(buffer: r.body) == Data([0xFF, 0xD8, 0xFF]))
            }
            try await client.execute(uri: "\(base)/cover", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.contentType] == "image/png")
            }
            try await client.execute(uri: "\(base)/progress", method: .post,
                                     headers: [.authorization: "Bearer \(fx.token)", .contentType: "application/json"],
                                     body: .init(string: #"{"page": 3}"#)) { r in
                #expect(r.status == .ok)
            }
        }
        let seen = RelayRemoteStub.seen
        #expect(seen.map(\.url.absoluteString) == [
            "\(remoteOrigin)\(remoteBook)/manifest",
            "\(remoteOrigin)\(remoteBook)/pages/3?maxw=800",
            "\(remoteOrigin)\(remoteBook)/cover",
            "\(remoteOrigin)\(remoteBook)/progress",
        ])
        #expect(seen.allSatisfy { $0.header("Authorization") == "Bearer REMOTE-SECRET" },
                "リモートの鍵を付ける（中継の鍵は渡さない）")
        #expect(seen[0].header("X-StackNest-Viewer") == "com.example.viewer/1.80; format=1")
        #expect(seen[1].header("If-None-Match") == "\"p0\"")
        #expect(seen[3].method == "POST")
        #expect(String(decoding: seen[3].body, as: UTF8.self) == #"{"page": 3}"#)
    }

    /// 状態コード・本文・X-Library-Locked はそのまま返す（ビューアが「開き直して」「解錠して」を出せるように）。
    /// 作者の決定（2026-10-10）で、上流の 401・403 はそのまま返したうえで中継を閉じる。閉じない応答（404・304）を先に、
    /// 閉じる応答を後に確かめる（閉じた後の振る舞いは ViewerRelayCacheTests の `anUpstreamRefusalClosesTheRelayEvenForCachedPages`）。
    @Test func passesThroughErrorsAndTheLockHeader() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(status: 401),
            "\(remoteBook)/cover": .init(status: 403, headers: ["X-Library-Locked": "1"]),
            "\(remoteBook)/pages/1": .init(status: 304, headers: ["ETag": "\"p1\""]),
        ]
        let base = "/api/v1/relay/\(fx.relayID)"
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "\(base)/pages/9", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .notFound)
            }
            try await client.execute(uri: "\(base)/pages/1", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)", .ifNoneMatch: "\"p1\""]) { r in
                #expect(r.status == .notModified)
                #expect(r.headers[.eTag] == "\"p1\"")
            }
            #expect(fx.registry.target(for: fx.relayID) != nil, "404・304 では閉じない")
            try await client.execute(uri: "\(base)/cover", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .forbidden)
                #expect(r.headers[Self.lockedHeader] == "1")
            }
        }
        #expect(fx.registry.target(for: fx.relayID) == nil, "施錠の 403 で閉じる")

        let fx2 = makeFixture(); defer { fx2.done() }
        RelayRemoteStub.responses = ["\(remoteBook)/manifest": .init(status: 401)]
        try await makeApp(fx2).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx2.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx2.token)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
        #expect(fx2.registry.target(for: fx2.relayID) == nil, "401 で閉じる")
    }

    /// 中継の鍵はその relayID だけ。CLI のトークン・本の鍵・別の中継の鍵は中継の道で 403、中継の鍵は本の道で 403。
    /// 中継の 4 つ以外の道（`relay/{id}/detail`）はルートが無いので 404（Hummingbird はルートが一致しないと
    /// グループの中間処理を走らせない）。どれもリモートへは何も送らない。
    @Test func refusesOtherRelaysAndOtherTokens() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let other = fx.registry.register(ViewerRelayTarget(
            serverID: UUID(), serverBase: URL(string: "http://100.64.0.5:51234/")!,
            libraryUUID: "LIB-R", bookID: 43, remoteToken: "OTHER-SECRET"))
        let bookToken = fx.store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .localEndpoint,
                                       lockCredential: nil).token
        let cases: [(String, HTTPRequest.Method, String, HTTPResponse.Status)] = [
            (fx.token, .get, "/api/v1/relay/\(other)/manifest", .forbidden),
            ("cli-token", .get, "/api/v1/relay/\(fx.relayID)/manifest", .forbidden),
            (bookToken, .get, "/api/v1/relay/\(fx.relayID)/manifest", .forbidden),
            (fx.token, .get, "/api/v1/libraries/LIB-R/books/42/manifest", .forbidden),
            (fx.token, .get, "/api/v1/libraries/LIB-R/books/42/detail", .forbidden),
            (fx.token, .get, "/api/v1/relay/\(fx.relayID)/detail", .notFound),
            (fx.token, .get, "/api/v1/libraries", .forbidden),
        ]
        try await makeApp(fx, acceptsPrincipalTokens: true).test(.router) { client in
            for (token, method, uri, expected) in cases {
                try await client.execute(uri: uri, method: method, headers: [.authorization: "Bearer \(token)"]) { r in
                    #expect(r.status == expected, "\(uri)")
                }
            }
        }
        #expect(RelayRemoteStub.seen.isEmpty)
    }

    /// 中継の記録が無い（StackNest を終了した後など）なら 401（ビューアは「StackNest から開き直して」を出す）。
    @Test func missingRelayRecordIs401() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let orphan = fx.store.issue(libraryUUID: ViewerTokenRecord.relaySentinelLibraryUUID,
                                    bookID: ViewerTokenRecord.relaySentinelBookID, issuer: .localEndpoint,
                                    lockCredential: nil, relayID: "GONE").token
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/GONE/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(orphan)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
        #expect(RelayRemoteStub.seen.isEmpty)
    }

    /// リダイレクトは辿らない（鍵を別のオリジンへ運ばない）。3xx は 502。
    @Test func redirectsAreNotFollowed() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(status: 302, headers: ["Location": "http://evil.example/steal"]),
        ]
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .badGateway)
            }
        }
        #expect(!RelayRemoteStub.seen.contains { $0.url.host == "evil.example" })
        // URLSession が本物の HTTP でリダイレクトを辿ろうとしたときも、作業ごとの delegate が止める。
        let refuse = ViewerRelayForwarder.RefuseRedirects()
        let from = URL(string: "\(remoteOrigin)\(remoteBook)/manifest")!
        let task = URLSession.shared.dataTask(with: from)   // resume しない（通信しない）
        let next = await refuse.urlSession(
            URLSession.shared, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: from, statusCode: 302, httpVersion: "HTTP/1.1",
                                                        headerFields: ["Location": "http://evil.example/steal"])!,
            newRequest: URLRequest(url: URL(string: "http://evil.example/steal")!))
        #expect(next == nil)
    }

    @Test func unreachableRemoteIs502() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.failure = .cannotConnectToHost
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .badGateway)
            }
        }
    }

    /// 中継の鍵の初回使用も Task 2 の仕組みで記録される（App の確認はこれを読む）。
    @Test func firstUseOfTheRelayTokenIsRecorded() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = ["\(remoteBook)/manifest": .init(status: 200, headers: ["Content-Type": "application/json"],
                                                                      body: Data("{}".utf8))]
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(fx.store.record(id: fx.recordID)?.firstUsedAt != nil)
        #expect(fx.store.record(id: fx.recordID)?.viewer == "com.example.viewer/1.80; format=1")
    }


    // MARK: - レビュー（Task 3b M-3・Minor-1・Minor-2）

    /// M-3: 中継の鍵の記録は見張り用の書庫・本（`relay`・0）を持つので、中継より前のビルドが本の鍵として
    /// 解釈しても、本物の本の道は通らない（手元に同じ UUID の書庫があっても、同じ bookID の本を読めない）。
    @Test func relayRecordIdentityNeverMatchesARealBookPath() {
        let fx = makeFixture(); defer { fx.done() }
        guard let record = fx.store.record(id: fx.recordID) else { Issue.record("記録が無い"); return }
        #expect(record.libraryUUID == ViewerTokenRecord.relaySentinelLibraryUUID)
        #expect(record.bookID == ViewerTokenRecord.relaySentinelBookID)
        #expect(record.relayID == fx.relayID)
        // 実在の書庫の UUID（UUID 形式）にも、実在しうる本の id（1 以上）にも一致しない。
        #expect(UUID(uuidString: record.libraryUUID) == nil)
        #expect(record.bookID == 0)
        for (lib, book) in [("LIB-R", 42), (UUID().uuidString, 1), (UUID().uuidString, 0)] {
            let base = "/api/v1/libraries/\(lib)/books/\(book)"
            for (method, tail) in [(HTTPRequest.Method.get, "manifest"), (.get, "cover"), (.get, "pages/0"), (.post, "progress")] {
                // 旧ビルドの判定（`allows(libraryUUID: record.libraryUUID, bookID: record.bookID)`）が通さない。
                let allowed = ViewerTokenRoutes.allows(method: method, path: "\(base)/\(tail)",
                                                       libraryUUID: record.libraryUUID, bookID: record.bookID)
                #expect(!allowed, "\(lib)/\(book)/\(tail)")
            }
        }
        // 中継の鍵そのものは、自分の relayID の道を通る（見張り用の値でも中継は動く）。
        #expect(ViewerTokenRoutes.allowsRelay(method: .get, path: "/api/v1/relay/\(fx.relayID)/manifest",
                                              relayID: fx.relayID))
    }

    /// Minor-1: 本文の上限は逐次に数える。作業を始めない（`resume` しない）データ作業に上限を超える 1 かたまりを渡した
    /// 時点で取り消される（全部を受けてから数えるのではない）。上限以内のかたまりでは取り消さない。
    @Test func streamingCapCancelsTheTaskAsSoonAsAChunkExceedsIt() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func task() -> URLSessionDataTask {
            session.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:1/")!))   // resume しない
        }
        let within = task()
        let loader = ViewerRelayForwarder.BoundedLoader(limit: 16)
        loader.urlSession(session, dataTask: within, didReceive: Data(repeating: 1, count: 16))
        #expect(within.state == .suspended, "上限ちょうどは取り消さない")

        let over = task()
        let loader2 = ViewerRelayForwarder.BoundedLoader(limit: 16)
        loader2.urlSession(session, dataTask: over, didReceive: Data(repeating: 1, count: 10))
        #expect(over.state == .suspended)
        loader2.urlSession(session, dataTask: over, didReceive: Data(repeating: 1, count: 7))
        #expect(over.state != .suspended, "累計が上限を超えた 1 かたまりで、残りを待たずに取り消す（\(over.state.rawValue)）")
    }

    /// Codex P2: 継続を置く前に完了が届いても（呼び出し側の取り消しで `task.cancel()` が先に走った）、結果を失わない。
    /// 失うと、後から置いた継続には二度と完了が来ず、`load` が待ち続ける。
    @Test func completionBeforeTheContinuationIsInstalledIsNotLost() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:1/")!))   // resume しない
        let loader = ViewerRelayForwarder.BoundedLoader(limit: 16)
        loader.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        // 直す前は待ち続けるので、別の Task で待ち、期限で打ち切る（試験全体を止めない）。
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: ViewerRelayForwarder.Outcome?
            var value: ViewerRelayForwarder.Outcome? { lock.withLock { stored } }
            func set(_ o: ViewerRelayForwarder.Outcome) { lock.withLock { stored = o } }
        }
        let box = Box()
        Task { box.set(await withCheckedContinuation { loader.start(task, continuation: $0) }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while box.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }

        guard case .failed? = box.value else {
            Issue.record("先に届いた完了の結果（failed）が返らない: \(String(describing: box.value))")
            return
        }
        #expect(task.state == .suspended, "先に完了した作業は始めない")
    }

    /// Minor-2（意図した動き）: 中継の鍵の初回使用は「有効な中継の鍵で 127.0.0.1 の口に届いた」こと。
    /// リモートが 502 を返しても、中継の記録が無くて 401 でも記録される（本を読み込めたかは意味しない）。
    @Test func relayFirstUseMeansReachingTheEndpoint() async throws {
        // 取り次ぎ先が届かない（502）。
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.failure = .cannotConnectToHost
        #expect(fx.store.record(id: fx.recordID)?.firstUsedAt == nil)
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .badGateway)
            }
        }
        #expect(fx.store.record(id: fx.recordID)?.firstUsedAt != nil, "502 でも「届いた」は記録する")

        // 中継の記録が無い（終了後の孤児の鍵）。
        let orphan = fx.store.issue(libraryUUID: ViewerTokenRecord.relaySentinelLibraryUUID,
                                    bookID: ViewerTokenRecord.relaySentinelBookID, issuer: .localEndpoint,
                                    lockCredential: nil, relayID: "GONE")
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/GONE/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(orphan.token)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
        #expect(fx.store.record(id: orphan.record.id)?.firstUsedAt != nil, "401（中継の記録なし）でも記録する")
    }

    // MARK: - レビュー（I-2・I-3・M-1・M-4・M-6 と足りないテスト）

    /// I-3: 共有サーバの形（中継なし・発行先 `.sharedServer`）には中継のルートが無い。
    /// R トークン・共有サーバの本の鍵・127.0.0.1 の口の中継の鍵のどれで叩いても中継に入らず、リモートへ何も送らない。
    @Test func sharedServerShapeHasNoRelay() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let sharedBookToken = fx.store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .sharedServer,
                                             lockCredential: nil).token
        let app = LibraryServerCore(
            config: .init(port: 0, token: "READ", viewerTokens: fx.store, viewerTokenIssuer: .sharedServer),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
        let uri = "/api/v1/relay/\(fx.relayID)/manifest"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notFound, "ルートが無い")
            }
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(sharedBookToken)"]) { r in
                #expect([.notFound, .forbidden].contains(r.status), "本の鍵は中継の道に入れない（\(r.status)）")
            }
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect([.notFound, .unauthorized].contains(r.status), "127.0.0.1 の口の鍵は共有サーバでは知らない鍵（\(r.status)）")
            }
        }
        #expect(RelayRemoteStub.seen.isEmpty)
    }

    /// I-3: 中継は発行先 `.localEndpoint` の口だけ（`LibraryServerCore.init` の precondition が使う判定）。
    @Test func relayRequiresTheLocalEndpointIssuer() {
        let relay = ViewerRelayConfig(registry: ViewerRelayRegistry(), session: session())
        #expect(LibraryServerConfig.relayConfigurationIsValid(viewerRelay: relay, issuer: .localEndpoint))
        #expect(!LibraryServerConfig.relayConfigurationIsValid(viewerRelay: relay, issuer: .sharedServer))
        #expect(LibraryServerConfig.relayConfigurationIsValid(viewerRelay: nil, issuer: .sharedServer))
        #expect(LibraryServerConfig.relayConfigurationIsValid(viewerRelay: nil, issuer: .localEndpoint))
    }

    /// I-2: 応答の本文が上限を超えたら 502。長さが分かっている（Content-Length）ときは読む前に、
    /// 分からないときは受けながら数えて打ち切る。上限ちょうどは通す。
    @Test func responseBodyOverTheCapIs502() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let big = Data(repeating: 0xAB, count: 64)
        RelayRemoteStub.responses = [
            "\(remoteBook)/pages/1": .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: big),
            "\(remoteBook)/pages/2": .init(status: 200, headers: ["Content-Type": "image/jpeg", "Content-Length": "64"],
                                           body: big),
            "\(remoteBook)/pages/3": .init(status: 200, headers: ["Content-Type": "image/jpeg"],
                                           body: Data(repeating: 0xCD, count: 16)),
        ]
        let base = "/api/v1/relay/\(fx.relayID)"
        try await makeApp(fx, maxResponseBytes: 16).test(.router) { client in
            for n in [1, 2] {
                try await client.execute(uri: "\(base)/pages/\(n)", method: .get,
                                         headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == .badGateway, "pages/\(n)")
                    #expect(r.body.readableBytes == 0, "上限を超えた本文の一部も返さない")
                }
            }
            try await client.execute(uri: "\(base)/pages/3", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .ok)
                #expect(Data(buffer: r.body) == Data(repeating: 0xCD, count: 16))
            }
        }
    }

    /// I-2: POST の本文が上限（既定 64 KiB）を超えたら 413 で、リモートへは送らない。ちょうどは通す。
    @Test func postBodyOver64KiBIs413() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = ["\(remoteBook)/progress": .init(status: 200)]
        #expect(ViewerRelayConfig.defaultMaxRequestBytes == 64 * 1024)
        let uri = "/api/v1/relay/\(fx.relayID)/progress"
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: uri, method: .post,
                                     headers: [.authorization: "Bearer \(fx.token)", .contentType: "application/json"],
                                     body: ByteBuffer(bytes: [UInt8](repeating: 0x20, count: 64 * 1024 + 1))) { r in
                #expect(r.status == .contentTooLarge)
            }
            #expect(RelayRemoteStub.seen.isEmpty, "上限を超えた POST はリモートへ送らない")
            try await client.execute(uri: uri, method: .post,
                                     headers: [.authorization: "Bearer \(fx.token)", .contentType: "application/json"],
                                     body: ByteBuffer(bytes: [UInt8](repeating: 0x20, count: 64 * 1024))) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(RelayRemoteStub.seen.count == 1)
        #expect(RelayRemoteStub.seen.first?.body.count == 64 * 1024)
    }

    /// I-2: 上限は設定から変えられる（POST）。
    @Test func postCapIsInjectable() async throws {
        let fx = makeFixture(); defer { fx.done() }
        try await makeApp(fx, maxRequestBytes: 8).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/progress", method: .post,
                                     headers: [.authorization: "Bearer \(fx.token)"],
                                     body: .init(string: #"{"page": 12}"#)) { r in
                #expect(r.status == .contentTooLarge)
            }
        }
        #expect(RelayRemoteStub.seen.isEmpty)
    }

    /// M-6: `maxw` は正の整数のときだけ渡す（数でない・負・0 は落とす）。
    @Test func maxwIsForwardedOnlyWhenPositive() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = ["\(remoteBook)/pages/0": .init(status: 200, headers: ["Content-Type": "image/jpeg"])]
        let base = "/api/v1/relay/\(fx.relayID)/pages/0"
        try await makeApp(fx).test(.router) { client in
            for query in ["?maxw=abc", "?maxw=-1", "?maxw=0", "?maxw=", "?maxw=1.5", "?maxw=640"] {
                try await client.execute(uri: base + query, method: .get,
                                         headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == .ok, "\(query)")
                }
            }
        }
        #expect(RelayRemoteStub.seen.map(\.url.query) == [nil, nil, nil, nil, nil, "maxw=640"])
    }

    /// 許可リストに無いヘッダは通さない: 要求の Cookie・X-Library-Token・Range はリモートへ届かず、
    /// 応答の Set-Cookie・Content-Length 以外のほかのヘッダはビューアへ返らない。Authorization は付け替える。
    @Test func headersOutsideTheAllowListAreNotCopied() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(status: 200, headers: [
                "Content-Type": "application/json", "ETag": "\"m1\"", "Set-Cookie": "sid=remote",
                "X-Remote-Internal": "1", "Cache-Control": "private",
            ], body: Data("{}".utf8)),
        ]
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)", .cookie: "sid=viewer",
                                               HTTPField.Name("X-Library-Token")!: "LIB-TOKEN",
                                               .range: "bytes=0-1"]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.setCookie] == nil)
                #expect(r.headers[HTTPField.Name("X-Remote-Internal")!] == nil)
                #expect(r.headers[.cacheControl] == nil)
                #expect(r.headers[.eTag] == "\"m1\"")
            }
        }
        let seen = try #require(RelayRemoteStub.seen.first)
        #expect(seen.header("Cookie") == nil)
        #expect(seen.header("X-Library-Token") == nil)
        #expect(seen.header("Range") == nil)
        #expect(seen.header("Authorization") == "Bearer REMOTE-SECRET")
        #expect(!seen.headers.values.contains { $0.contains(fx.token) }, "中継の鍵はリモートへ渡さない")
    }

    /// M-1: 名乗りは保存のときと同じ規則（印字できる ASCII・200 文字）で整えてから渡す。
    @Test func viewerIdentificationIsSanitizedBeforeForwarding() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = ["\(remoteBook)/cover": .init(status: 200, headers: ["Content-Type": "image/png"])]
        let raw = "com.example.viewer/1.80\u{00E9}; format=1" + String(repeating: "x", count: 300)
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(fx.relayID)/cover", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)", Self.viewerHeader: raw]) { r in
                #expect(r.status == .ok)
            }
        }
        let forwarded = try #require(RelayRemoteStub.seen.first?.header("X-StackNest-Viewer"))
        #expect(forwarded == ViewerIdentification.sanitize(raw))
        #expect(forwarded.hasPrefix("com.example.viewer/1.80; format=1"))
        #expect(forwarded.count == ViewerIdentification.maxLength, "200 文字で切る")
        #expect(forwarded.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E })
    }

    /// GET・POST 以外（DELETE・PATCH・PUT）は中継のルートが無いので 404（許可リストでも通さない＝relayRouteTable）。
    /// リモートへは送らない。
    @Test func otherMethodsAreNotRouted() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let base = "/api/v1/relay/\(fx.relayID)"
        try await makeApp(fx).test(.router) { client in
            for (method, path) in [(HTTPRequest.Method.delete, "manifest"), (.patch, "progress"),
                                   (.put, "progress"), (.delete, "pages/1")] {
                try await client.execute(uri: "\(base)/\(path)", method: method,
                                         headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == .notFound, "\(method) \(path)")
                }
            }
        }
        #expect(RelayRemoteStub.seen.isEmpty)
    }

    /// M-4: 中継の記録の期限（中継の鍵とリモートの鍵の早い方）が過ぎたら 401。リモートへは送らない。
    @Test func expiredRelayRecordIs401() async throws {
        let fx = makeFixture(); defer { fx.done() }
        let past = fx.registry.register(ViewerRelayTarget(
            serverID: UUID(), serverBase: URL(string: "http://100.64.0.5:51234/")!,
            libraryUUID: "LIB-R", bookID: 42, remoteToken: "EXPIRED-SECRET"),
            expiresAt: Date().addingTimeInterval(-1))
        let token = fx.store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .localEndpoint,
                                   lockCredential: nil, relayID: past).token
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "/api/v1/relay/\(past)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
        #expect(RelayRemoteStub.seen.isEmpty)
    }

    /// リモートの鍵は、中継の口が返すどの応答（成功・失敗）の本文とヘッダにも出ない。
    @Test func remoteTokenNeverReachesTheViewer() async throws {
        let fx = makeFixture(); defer { fx.done() }
        RelayRemoteStub.responses = [
            "\(remoteBook)/manifest": .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)),
            "\(remoteBook)/cover": .init(status: 302, headers: ["Location": "http://evil.example/steal"]),
        ]
        let base = "/api/v1/relay/\(fx.relayID)"
        @Sendable func showsNoSecret(_ r: TestResponse) -> Bool {
            !String(decoding: Data(buffer: r.body), as: UTF8.self).contains("REMOTE-SECRET")
                && !r.headers.contains { $0.value.contains("REMOTE-SECRET") }
        }
        try await makeApp(fx, maxResponseBytes: 1).test(.router) { client in
            for path in ["manifest", "cover", "pages/9"] {
                try await client.execute(uri: "\(base)/\(path)", method: .get,
                                         headers: [.authorization: "Bearer \(fx.token)"]) { r in
                    #expect(r.status == .badGateway || r.status == .notFound, "\(path)")
                    #expect(showsNoSecret(r), "\(path)")
                }
            }
        }
        RelayRemoteStub.failure = .timedOut
        try await makeApp(fx).test(.router) { client in
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(fx.token)"]) { r in
                #expect(r.status == .badGateway)
                #expect(showsNoSecret(r))
            }
        }
        var dumped = ""
        dump(fx.registry, to: &dumped)
        #expect(!dumped.contains("REMOTE-SECRET"), "レジストリを dump しても出ない")
        #expect(!String(describing: ViewerRelayConfig(registry: fx.registry, session: session())).contains("REMOTE-SECRET"))
    }
}
