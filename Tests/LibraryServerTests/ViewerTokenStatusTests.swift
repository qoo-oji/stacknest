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

/// G60 v3: 本専用トークンが使われたかの照会（`GET /api/v1/viewer-tokens/{tokenID}`）。発行した主体だけが読める。
@Suite("G60 v3: 本専用トークンの使用の照会")
struct ViewerTokenStatusTests {
    private static let viewerHeader = HTTPField.Name("X-StackNest-Viewer")!

    private func makeStore() -> (ViewerTokenStore, () -> Void) {
        let name = "g60v3-status-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ViewerTokenStore(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func grant(_ id: String, token: String, scope: GrantScope = .all) -> Grant {
        Grant(id: id, label: id, token: token, tier: .read, scope: scope, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func makeApp(grants: [Grant], libs: [ServedLibrary], store: ViewerTokenStore?) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "unused", grantsProvider: { grants }, viewerTokens: store),
            dataSource: StaticLibraryDataSource(libraries: libs)
        ).buildApplication()
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func issuerSeesUnusedThenUsed() async throws {
        let fx = try TestLibraryFixture(name: "S1", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        try await makeApp(grants: [grant("r", token: "READ")], libs: [lib], store: store).test(.router) { client in
            var reply: ViewerTokenReply?
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
                reply = try decoder().decode(ViewerTokenReply.self, from: Data(buffer: r.body))
            }
            let issued = try #require(reply)
            let tokenID = try #require(issued.tokenID)
            #expect(store.record(id: tokenID) != nil, "tokenID は保存先の記録の id")
            #expect(tokenID != issued.token)
            let statusURI = "/api/v1/viewer-tokens/\(tokenID)"
            // Task 3 レビュー M-2: 認証の無い照会は 401（ルートは認証の中間処理の内側にある）。
            try await client.execute(uri: statusURI, method: .get) { r in
                #expect(r.status == .unauthorized)
            }
            try await client.execute(uri: statusURI, method: .get, headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.cacheControl] == "no-store")
                let obj = try #require(try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
                #expect(obj["firstUsedAt"] is NSNull, "まだ使われていなければ null（キーは省かない）")
                #expect(obj["viewer"] is NSNull)
            }
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)",
                                               Self.viewerHeader: "com.example.viewer/1.80; format=1"]) { r in
                #expect(r.status == .ok)
            }
            try await client.execute(uri: statusURI, method: .get, headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
                let status = try decoder().decode(ViewerTokenStatusReply.self, from: Data(buffer: r.body))
                #expect(status.firstUsedAt != nil)
                #expect(status.viewer == "com.example.viewer/1.80; format=1")
            }
        }
    }

    @Test func anotherPrincipalIsForbidden() async throws {
        let fx = try TestLibraryFixture(name: "S2", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                 lockCredential: nil, issuedByGrantID: "r")
        let grants = [grant("r", token: "READ"), grant("r2", token: "OTHER")]
        try await makeApp(grants: grants, libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/\(issued.record.id)", method: .get,
                                     headers: [.authorization: "Bearer OTHER"]) { r in
                #expect(r.status == .forbidden)
            }
            try await client.execute(uri: "/api/v1/viewer-tokens/\(issued.record.id)", method: .get,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func outOfScopeLibraryIsForbidden() async throws {
        let fx = try TestLibraryFixture(name: "S3", bookCount: 0); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: "LIB-ELSEWHERE", bookID: 1, issuer: .sharedServer,
                                 lockCredential: nil, issuedByGrantID: "r")
        let grants = [grant("r", token: "READ", scope: .libraries([lib.uuid]))]
        try await makeApp(grants: grants, libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/\(issued.record.id)", method: .get,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .forbidden)
            }
        }
    }

    @Test func theViewerTokenItselfIsForbidden() async throws {
        let fx = try TestLibraryFixture(name: "S4", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil)
        try await makeApp(grants: [], libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/\(issued.record.id)", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)"]) { r in
                #expect(r.status == .forbidden)
            }
        }
        #expect(store.record(id: issued.record.id)?.firstUsedAt == nil, "照会の 403 は使用に数えない")
    }

    @Test func unknownOrOtherEndpointIs404() async throws {
        let fx = try TestLibraryFixture(name: "S5", bookCount: 0); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let local = store.issue(libraryUUID: lib.uuid, bookID: 1, issuer: .localEndpoint, lockCredential: nil)
        try await makeApp(grants: [grant("r", token: "READ")], libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/NO-SUCH-ID", method: .get,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notFound)
            }
            try await client.execute(uri: "/api/v1/viewer-tokens/\(local.record.id)", method: .get,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notFound, "127.0.0.1 の口で出したものは共有サーバでは見えない")
            }
        }
    }

    /// 固定トークンの経路（グラント無し・"legacy"）は、自分が出したものだけを読める。
    @Test func fixedTokenPathReadsOnlyItsOwn() async throws {
        let fx = try TestLibraryFixture(name: "S6", bookCount: 0); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let own = store.issue(libraryUUID: lib.uuid, bookID: 1, issuer: .sharedServer, lockCredential: nil)
        let granted = store.issue(libraryUUID: lib.uuid, bookID: 1, issuer: .sharedServer,
                                  lockCredential: nil, issuedByGrantID: "r")
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", viewerTokens: store),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/\(own.record.id)", method: .get,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .ok)
            }
            try await client.execute(uri: "/api/v1/viewer-tokens/\(granted.record.id)", method: .get,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .forbidden)
            }
        }
    }

    /// 施錠庫でも、照会には書庫のトークン（`X-Library-Token`）を求めない（応答に本の中身が無い・裁定）。
    @Test func lockedLibraryStatusNeedsNoLibraryToken() async throws {
        let fx = try TestLibraryFixture(name: "S8", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer,
                                 lockCredential: lib.currentLockCredential(), issuedByGrantID: "r")
        try await makeApp(grants: [grant("r", token: "READ")], libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/\(issued.record.id)", method: .get,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.init("X-Library-Locked")!] == nil)
            }
        }
    }

    @Test func withoutAStoreIs501() async throws {
        let fx = try TestLibraryFixture(name: "S7", bookCount: 0); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        try await makeApp(grants: [grant("r", token: "READ")], libs: [lib], store: nil).test(.router) { client in
            try await client.execute(uri: "/api/v1/viewer-tokens/ANY", method: .get,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notImplemented)
            }
        }
    }

    @Test func statusReplyWritesExplicitNullsAndReadsBothShapes() throws {
        let text = String(decoding: try JSONEncoder().encode(ViewerTokenStatusReply(firstUsedAt: nil, viewer: nil)),
                          as: UTF8.self)
        #expect(text.contains(#""firstUsedAt":null"#))
        #expect(text.contains(#""viewer":null"#))
        #expect(try decoder().decode(ViewerTokenStatusReply.self, from: Data("{}".utf8))
                == ViewerTokenStatusReply(firstUsedAt: nil, viewer: nil))
        let used = try decoder().decode(ViewerTokenStatusReply.self, from: Data(
            #"{"firstUsedAt":"2026-10-02T00:00:00Z","viewer":"com.example.viewer/1.80; format=1"}"#.utf8))
        #expect(used.firstUsedAt == ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z"))
        #expect(used.viewer == "com.example.viewer/1.80; format=1")
    }
}
