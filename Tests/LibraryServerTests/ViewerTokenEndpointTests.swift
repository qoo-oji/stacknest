// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

@Suite("G60: viewer-token の発行")
struct ViewerTokenEndpointTests {
    private func makeStore() -> (ViewerTokenStore, () -> Void) {
        let name = "g60-issue-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ViewerTokenStore(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func readGrant(_ scope: GrantScope) -> Grant {
        Grant(id: "r", label: "r", token: "READ", tier: .read, scope: scope,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    private func makeApp(grants: [Grant], libs: [ServedLibrary], store: ViewerTokenStore?) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "unused", grantsProvider: { grants }, viewerTokens: store),
            dataSource: StaticLibraryDataSource(libraries: libs)
        ).buildApplication()
    }

    private func decodeReply(_ body: ByteBuffer) throws -> ViewerTokenReply {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ViewerTokenReply.self, from: Data(buffer: body))
    }

    @Test func readTierIssuesAWorkingToken() async throws {
        let fx = try TestLibraryFixture(name: "I1", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 3)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let before = Date()
        try await makeApp(grants: [readGrant(.all)], libs: [lib], store: store).test(.router) { client in
            var token = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
                let reply = try decodeReply(r.body)
                token = reply.token
                let expected = before.addingTimeInterval(ViewerTokenStore.lifetime)
                #expect(abs(reply.expiresAt.timeIntervalSince(expected)) < 60)
            }
            guard case .valid(let record) = store.lookup(token: token, issuer: .sharedServer) else {
                Issue.record("発行したトークンが保存先に無い"); return
            }
            #expect(record.libraryUUID == lib.uuid)
            #expect(record.bookID == id)
            #expect(record.lockFingerprint == nil)
            #expect(record.issuedByGrantID == "r")
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// 仕様（spec §7）は 403 と書くが、scope 外の書庫は既存の全ルートと同じく 404（存在を漏らさない）。
    @Test func outOfScopeLibraryIs404() async throws {
        let fa = try TestLibraryFixture(name: "I2a", bookCount: 0); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "I2b", bookCount: 0); defer { fb.cleanup() }
        let (b1, _) = try fb.addFolderBook(imageCount: 1)
        let la = fa.servedLibrary(), lb = fb.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        try await makeApp(grants: [readGrant(.libraries([la.uuid]))], libs: [la, lb], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lb.uuid)/books/\(b1)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notFound)
            }
        }
        #expect(store.allRecords().isEmpty)
    }

    @Test func lockedLibraryNeedsUnlockToIssue() async throws {
        let fx = try TestLibraryFixture(name: "I3", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 2)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let uri = "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token"
        try await makeApp(grants: [readGrant(.all)], libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: uri, method: .post, headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .forbidden)
                #expect(r.headers[.init("X-Library-Locked")!] == "1")
            }
            var libraryToken = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/unlock", method: .post,
                                     headers: [.authorization: "Bearer READ"],
                                     body: .init(string: #"{"password":"pw"}"#)) { r in
                libraryToken = try JSONDecoder().decode(UnlockReply.self, from: Data(buffer: r.body)).libraryToken
            }
            var token = ""
            try await client.execute(uri: uri, method: .post,
                                     headers: [.authorization: "Bearer READ",
                                               .init("X-Library-Token")!: libraryToken]) { r in
                #expect(r.status == .ok)
                token = try decodeReply(r.body).token
            }
            guard case .valid(let record) = store.lookup(token: token, issuer: .sharedServer) else {
                Issue.record("発行したトークンが保存先に無い"); return
            }
            #expect(record.lockFingerprint == ViewerTokenStore.lockFingerprint(for: lib.currentLockCredential()))
            // 発行したトークンは書庫のトークンなしでその本を読める。
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// I-3: 発行したトークンは発行元のグラントに結び付き、そのグラントを消すと読めなくなる。
    /// 固定トークン（グラントの無い経路）で発行したものは結び付かない。
    @Test func issuedTokenIsBoundToTheIssuingGrant() async throws {
        let fx = try TestLibraryFixture(name: "IG", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let repo = InMemoryGrantRepository(initial: [readGrant(.all)])
        let app = LibraryServerCore(
            config: .init(port: 0, token: "unused", grantRepository: repo, viewerTokens: store),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            var token = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .ok)
                token = try decodeReply(r.body).token
            }
            repo.delete(id: "r")
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
        // 固定トークンの経路（グラント無し）。
        let legacyApp = LibraryServerCore(
            config: .init(port: 0, token: "tk", viewerTokens: store),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await legacyApp.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .ok)
                let token = try decodeReply(r.body).token
                guard case .valid(let record) = store.lookup(token: token, issuer: .sharedServer) else {
                    Issue.record("発行したトークンが保存先に無い"); return
                }
                #expect(record.issuedByGrantID == nil)
            }
        }
    }

    /// I-1: 解錠の後でパスワードが変わったら、旧パスワードの書庫トークンでは発行できない。
    @Test func passwordChangedAfterUnlockCannotIssue() async throws {
        let fx = try TestLibraryFixture(name: "IR", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        try await makeApp(grants: [readGrant(.all)], libs: [lib], store: store).test(.router) { client in
            var libraryToken = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/unlock", method: .post,
                                     headers: [.authorization: "Bearer READ"],
                                     body: .init(string: #"{"password":"pw"}"#)) { r in
                libraryToken = try JSONDecoder().decode(UnlockReply.self, from: Data(buffer: r.body)).libraryToken
            }
            try fx.db.setLibrarySetting(key: "lock_password_hash", value: "rotated-hash")
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ",
                                               .init("X-Library-Token")!: libraryToken]) { r in
                #expect(r.status == .forbidden)
                #expect(r.headers[.init("X-Library-Locked")!] == "1")
            }
        }
        #expect(store.allRecords().isEmpty)
    }

    /// I-1: 書庫トークンが発行時に認証した世代を返す（現在の世代とは比べない）。
    @Test func libraryTokenStoreReturnsTheVerifiedCredential() async throws {
        let tokens = LibraryTokenStore()
        let t = await tokens.issueToken(for: "lib1", credential: "H1")
        #expect(await tokens.credential(for: t, libraryUUID: "lib1") == "H1")
        #expect(await tokens.credential(for: t, libraryUUID: "lib2") == nil)
        #expect(await tokens.credential(for: "unknown", libraryUUID: "lib1") == nil)
        let short = LibraryTokenStore(ttl: .milliseconds(20))
        let t2 = await short.issueToken(for: "lib1", credential: "H1")
        try await Task.sleep(for: .milliseconds(80))
        #expect(await short.credential(for: t2, libraryUUID: "lib1") == nil)
    }

    @Test func viewerTokenCannotIssueAnother() async throws {
        let fx = try TestLibraryFixture(name: "I4", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        let token = store.issue(libraryUUID: lib.uuid, bookID: id, issuer: .sharedServer, lockCredential: nil).token
        try await makeApp(grants: [], libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer \(token)"]) { r in
                #expect(r.status == .forbidden)
            }
        }
        #expect(store.allRecords().count == 1)
    }

    @Test func withoutAStoreIs501() async throws {
        let fx = try TestLibraryFixture(name: "I5", bookCount: 0); defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        try await makeApp(grants: [readGrant(.all)], libs: [lib], store: nil).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notImplemented)
            }
        }
    }

    @Test func unknownBookIs404() async throws {
        let fx = try TestLibraryFixture(name: "I6", bookCount: 0); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let (store, done) = makeStore(); defer { done() }
        try await makeApp(grants: [readGrant(.all)], libs: [lib], store: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/999/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer READ"]) { r in
                #expect(r.status == .notFound)
            }
        }
    }
}
