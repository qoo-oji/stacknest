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

/// G60: 本専用の読み取りトークンは、その本の manifest・pages・cover（GET）と progress（POST）だけを通す。
@Suite("G60: 本専用トークンの認証")
struct ViewerTokenAuthTests {
    private func makeStore() -> (ViewerTokenStore, () -> Void) {
        let name = "g60-auth-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ViewerTokenStore(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func makeApp(_ libs: [ServedLibrary], store: ViewerTokenStore,
                         issuer: ViewerTokenIssuer = .sharedServer) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "tk", viewerTokens: store, viewerTokenIssuer: issuer),
            dataSource: StaticLibraryDataSource(libraries: libs)
        ).buildApplication()
    }

    @Test func routeTable() {
        let base = "/api/v1/libraries/L-1/books/7"
        func allows(_ m: HTTPRequest.Method, _ p: String) -> Bool {
            ViewerTokenRoutes.allows(method: m, path: p, libraryUUID: "L-1", bookID: 7)
        }
        #expect(allows(.get, "\(base)/manifest"))
        #expect(allows(.get, "\(base)/pages/0"))
        #expect(allows(.get, "\(base)/pages/12"))
        #expect(allows(.get, "\(base)/cover"))
        #expect(allows(.post, "\(base)/progress"))
        #expect(!allows(.post, "\(base)/manifest"))
        #expect(!allows(.get, "\(base)/progress"))
        #expect(!allows(.delete, "\(base)/cover"))
        #expect(!allows(.get, "\(base)/pages/"))
        #expect(!allows(.get, "\(base)/pages/1x"))
        #expect(!allows(.get, "\(base)/pages/-1"))
        #expect(!allows(.get, "\(base)/pages/1/extra"))
        #expect(!allows(.get, "\(base)/manifest/"))
        #expect(!allows(.get, "\(base)/MANIFEST"))
        #expect(!allows(.get, "\(base)/detail"))
        #expect(!allows(.get, "\(base)/epub-progress"))
        #expect(!allows(.patch, base))
        #expect(!allows(.get, "/api/v1/libraries/L-1/books/70/manifest"))
        #expect(!allows(.get, "/api/v1/libraries/L-10/books/7/manifest"))
        #expect(!allows(.get, "/local/libraries/L-1/books/7/manifest"))
    }

    @Test func theFourBookRoutesAcceptTheToken() async throws {
        let fx = try TestLibraryFixture(name: "V1", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 3)
        try fx.addCover(bookID: id)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil).token
        let base = "/api/v1/libraries/\(lib.uuid)/books/\(id)"
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
                let m = try JSONDecoder().decode(ManifestDTO.self, from: Data(buffer: r.body))
                #expect(m.pageCount == 3)
            }
            try await client.execute(uri: "\(base)/pages/0?maxw=800", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
            try await client.execute(uri: "\(base)/cover", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
            try await client.execute(uri: "\(base)/progress", method: .post,
                                     headers: [.authorization: "Bearer \(token)"],
                                     body: .init(string: #"{"page": 2}"#)) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(try fx.db.loadViewerState(bookID: id).lastPage == 2)
    }

    @Test func otherRoutesAreForbidden() async throws {
        let fx = try TestLibraryFixture(name: "V2", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil).token
        let book = "/api/v1/libraries/\(lib.uuid)/books/\(id)"
        let cases: [(HTTPRequest.Method, String)] = [
            (.get, "/api/v1/libraries"),
            (.get, "/api/v1/me"),
            (.post, "/api/v1/session"),          // 長命のセッショントークンに換えさせない
            (.get, "/api/v1/events"),
            (.get, "/api/v1/libraries/\(lib.uuid)/books"),
            (.get, "\(book)/detail"),
            (.get, "\(book)/file"),
            (.post, "\(book)/epub-progress"),
            (.post, "\(book)/rating"),
            (.patch, book),
        ]
        try await makeApp([lib], store: store).test(.router) { client in
            for (method, uri) in cases {
                try await client.execute(uri: uri, method: method,
                                         headers: [.authorization: "Bearer \(token)"],
                                         body: .init(string: "{}")) { r in
                    #expect(r.status == .forbidden, "\(method) \(uri) は 403 であるべき")
                }
            }
            // クエリ（?token=）で出した本専用トークンは照合しない（401）。
            try await client.execute(uri: "/api/v1/libraries?token=\(token)", method: .get) { r in
                #expect(r.status == .unauthorized)
            }
            // 末尾スラッシュ・大文字違いは通さない（403 か、ルートが無ければ 404）。
            for uri in ["\(book)/manifest/", "\(book)/MANIFEST"] {
                try await client.execute(uri: uri, method: .get,
                                         headers: [.authorization: "Bearer \(token)"]) { r in
                    #expect(r.status == .forbidden || r.status == .notFound, "\(uri)")
                }
            }
        }
    }

    /// I-2: 本専用トークンは Authorization ヘッダでだけ受け付ける（spec §5.1）。許可された道でもクエリなら 401。
    @Test func queryTokenIsNotAccepted() async throws {
        let fx = try TestLibraryFixture(name: "VQ", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil).token
        let manifest = "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest"
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "\(manifest)?token=\(token)", method: .get) { r in
                #expect(r.status == .unauthorized)
            }
            try await client.execute(uri: manifest, method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// I-3: 共有サーバで発行したトークンは、発行元のグラントを消す・その書庫を scope から外すと即時に 401。
    @Test func grantDeletionRevokesItsViewerTokens() async throws {
        let fx = try TestLibraryFixture(name: "VG", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let grant = Grant(id: "g-share", label: "share", token: "SHARE", tier: .read, scope: .all,
                          createdAt: Date(timeIntervalSince1970: 0))
        let repo = InMemoryGrantRepository(initial: [grant])
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                lockCredential: nil, issuedByGrantID: "g-share").token
        let app = LibraryServerCore(
            config: .init(port: 0, token: "unused", grantRepository: repo, viewerTokens: store),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        let uri = "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
            var narrowed = grant
            narrowed.scope = .libraries(["OTHER-LIBRARY"])
            repo.upsert(narrowed)
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .unauthorized, "scope から外したら読めない")
            }
            repo.upsert(grant)
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
            repo.delete(id: "g-share")
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .unauthorized, "グラントを消したら即時に読めない")
            }
        }
    }

    /// I-3: アプリが手元で出した（グラントに結び付かない）トークンは、グラントの増減に左右されない。
    @Test func locallyMintedTokensIgnoreGrantChanges() async throws {
        let fx = try TestLibraryFixture(name: "VM", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let repo = InMemoryGrantRepository(initial: [
            Grant(id: "g-any", label: "any", token: "ANY", tier: .admin, scope: .all,
                  createdAt: Date(timeIntervalSince1970: 0)),
        ])
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .localEndpoint, lockCredential: nil).token
        let app = LibraryServerCore(
            config: .init(host: "127.0.0.1", port: 0, token: "unused", grantRepository: repo,
                          viewerTokens: store, viewerTokenIssuer: .localEndpoint),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        let uri = "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
            repo.delete(id: "g-any")
            try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func otherBookAndOtherLibraryAreForbidden() async throws {
        let fa = try TestLibraryFixture(name: "VA", bookCount: 0); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "VB", bookCount: 0); defer { fb.cleanup() }
        let (a1, _) = try fa.addFolderBook(imageCount: 2)
        let (a2, _) = try fa.addFolderBook(imageCount: 2)
        let (b1, _) = try fb.addFolderBook(imageCount: 2)
        let la = fa.servedLibrary(), lb = fb.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let token = store.issue(libraryUUID: la.uuid, bookID: a1, issuer: .sharedServer, lockCredential: nil).token
        try await makeApp([la, lb], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(la.uuid)/books/\(a2)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .forbidden)
            }
            try await client.execute(uri: "/api/v1/libraries/\(lb.uuid)/books/\(b1)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .forbidden)
            }
        }
    }

    @Test func expiredTokenIs401() async throws {
        let fx = try TestLibraryFixture(name: "V3", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let longAgo = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                lockCredential: nil, now: longAgo).token
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }

    @Test func tokenFromTheOtherEndpointIs401() async throws {
        let fx = try TestLibraryFixture(name: "V4", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let localToken = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .localEndpoint, lockCredential: nil).token
        try await makeApp([lib], store: store, issuer: .sharedServer).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(localToken)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }

    @Test func principalTokensStillWorkWithAStore() async throws {
        let fx = try TestLibraryFixture(name: "V5", bookCount: 1); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func lockedLibraryLetsOnlyThatBookThrough() async throws {
        let fx = try TestLibraryFixture(name: "VL", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let (other, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let unlocked = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                   lockCredential: lib.currentLockCredential()).token
        let beforeLock = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                     lockCredential: nil).token
        let base = "/api/v1/libraries/\(lib.uuid)/books"
        try await makeApp([lib], store: store).test(.router) { client in
            // 書庫のトークン（X-Library-Token）なしで、その本だけ読める。
            try await client.execute(uri: "\(base)/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(unlocked)"]) { r in
                #expect(r.status == .ok)
            }
            // 同じ書庫の別の本は 403。
            try await client.execute(uri: "\(base)/\(other)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(unlocked)"]) { r in
                #expect(r.status == .forbidden)
            }
            // 施錠前（解錠の世代なし）に出したトークンは施錠庫では通らない。
            try await client.execute(uri: "\(base)/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(beforeLock)"]) { r in
                #expect(r.status == .forbidden)
                #expect(r.headers[.init("X-Library-Locked")!] == "1")
            }
        }
        // パスワードを変えたら、それ以前に出したトークンでは読めない。
        try fx.db.setLibrarySetting(key: "lock_password_hash", value: "rotated-hash")
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "\(base)/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(unlocked)"]) { r in
                #expect(r.status == .forbidden)
            }
        }
    }

    /// 127.0.0.1 の口を「本専用トークンだけ」で動かす形（ローカルコントロール OFF・同期 ON）。
    @Test func viewerOnlyEndpointRejectsTheCLIToken() async throws {
        let fx = try TestLibraryFixture(name: "V6", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .localEndpoint, lockCredential: nil).token
        let app = LibraryServerCore(
            config: .init(host: "127.0.0.1", port: 0, token: "unused-read", editToken: "cli-token",
                          apiOnly: true, adminTier: true,
                          enableLocalLibraryControl: true,   // 仮にルートがあっても CLI のトークンは通さない
                          viewerTokens: store, viewerTokenIssuer: .localEndpoint,
                          acceptsPrincipalTokens: false),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get,
                                     headers: [.authorization: "Bearer cli-token"]) { r in
                #expect(r.status == .unauthorized)
            }
            try await client.execute(uri: "/local/libraries/open", method: .post,
                                     headers: [.authorization: "Bearer cli-token"],
                                     body: .init(string: #"{"path":"/tmp/none.stacknest"}"#)) { r in
                #expect(r.status == .unauthorized)
            }
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    // MARK: - G60 v3: 初めて使われたことの記録

    private static let viewerHeader = HTTPField.Name("X-StackNest-Viewer")!

    @Test func firstSuccessfulUseIsRecordedOnceWithTheHeader() async throws {
        let fx = try TestLibraryFixture(name: "U1", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil)
        let base = "/api/v1/libraries/\(lib.uuid)/books/\(id)"
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .ok)
            }
            let first = try #require(store.record(id: issued.record.id))
            let usedAt = try #require(first.firstUsedAt)
            #expect(first.viewer == "com.example.viewer/1.80; format=1")
            try await client.execute(uri: "\(base)/pages/0", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)",
                                               Self.viewerHeader: "com.example.other/9; format=1"]) { r in
                #expect(r.status == .ok)
            }
            let second = try #require(store.record(id: issued.record.id))
            #expect(second.firstUsedAt == usedAt, "2 回目以降は書かない")
            #expect(second.viewer == "com.example.viewer/1.80; format=1")
        }
    }

    /// 403 になった要求は「使った」に数えない（許可された道を通った要求だけ）。
    @Test func refusedRequestsDoNotCountAsUse() async throws {
        let fx = try TestLibraryFixture(name: "U2", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let (other, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil)
        let cases: [(HTTPRequest.Method, String)] = [
            (.get, "/api/v1/libraries/\(lib.uuid)/books/\(id)/detail"),
            (.post, "/api/v1/session"),
            (.get, "/api/v1/libraries/\(lib.uuid)/books/\(other)/manifest"),
        ]
        try await makeApp([lib], store: store).test(.router) { client in
            for (method, uri) in cases {
                try await client.execute(uri: uri, method: method,
                                         headers: [.authorization: "Bearer \(issued.token)",
                                                   Self.viewerHeader: "com.example.viewer/1.0; format=1"],
                                         body: .init(string: "{}")) { r in
                    #expect(r.status == .forbidden, "\(method) \(uri)")
                }
            }
        }
        #expect(store.record(id: issued.record.id)?.firstUsedAt == nil)
        #expect(store.record(id: issued.record.id)?.viewer == nil)
    }

    @Test func missingHeaderRecordsUseWithoutAViewer() async throws {
        let fx = try TestLibraryFixture(name: "U3", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil)
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)"]) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(store.record(id: issued.record.id)?.firstUsedAt != nil, "名乗りが無くても拒まず、使ったことは記録する")
        #expect(store.record(id: issued.record.id)?.viewer == nil)
    }

    @Test func longHeaderIsCutTo200Characters() async throws {
        let fx = try TestLibraryFixture(name: "U4", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil)
        let long = "com.example.viewer/1.0; format=1; " + String(repeating: "x", count: 500)
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)", Self.viewerHeader: long]) { r in
                #expect(r.status == .ok)
            }
        }
        let viewer = try #require(store.record(id: issued.record.id)?.viewer)
        #expect(viewer.count == ViewerIdentification.maxLength)
        #expect(viewer.hasPrefix("com.example.viewer/1.0; format=1"))
    }

    /// 127.0.0.1 の口（本専用トークンだけの形）でも同じに記録する。
    @Test func localEndpointRecordsFirstUseToo() async throws {
        let fx = try TestLibraryFixture(name: "U5", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .localEndpoint, lockCredential: nil)
        let app = LibraryServerCore(
            config: .init(host: "127.0.0.1", port: 0, token: "unused-read", editToken: "cli-token",
                          apiOnly: true, adminTier: true,
                          viewerTokens: store, viewerTokenIssuer: .localEndpoint,
                          acceptsPrincipalTokens: false),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(store.record(id: issued.record.id)?.firstUsedAt != nil)
        #expect(store.record(id: issued.record.id)?.viewer == "com.example.viewer/1.80; format=1")
    }

    /// 中間処理を通った後で施錠の 403 になった要求は「使った」に数える（裁定。ビューアはトークンで本に届いている。
    /// `refusedRequestsDoNotCountAsUse` の裏側）。施錠庫で発行 → パスワードの世代を変える → manifest は 403。
    @Test func lockGate403AfterTheMiddlewareStillCountsAsUse() async throws {
        let fx = try TestLibraryFixture(name: "U6", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                 lockCredential: lib.currentLockCredential())
        try fx.db.setLibrarySetting(key: "lock_password_hash", value: "rotated-hash")
        try await makeApp([lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .forbidden)
            }
        }
        #expect(store.record(id: issued.record.id)?.firstUsedAt != nil)
        #expect(store.record(id: issued.record.id)?.viewer == "com.example.viewer/1.80; format=1")
    }
}
