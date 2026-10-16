// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// G62（spec §6.2・§6.9・§8）: 施錠の門はスナップショットの `isLocked` ではなく、DB から 1 回読んだ値で決まる。
@Suite("G62: 施錠の判定は DB が正")
struct LockFromDatabaseTests {
    /// DB と違う `isLocked` を持つ、古いスナップショットの書庫。
    private func stale(_ fx: TestLibraryFixture, isLocked: Bool) -> ServedLibrary {
        fx.servedLibrary().withLockState(isLocked)
    }

    private func makeApp(_ libs: [ServedLibrary], viewerTokens: ViewerTokenStore? = nil) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "tk", viewerTokens: viewerTokens),
                          dataSource: StaticLibraryDataSource(libraries: libs)).buildApplication()
    }

    private struct UnlockReplyBody: Decodable { let libraryToken: String }
    private struct ViewerTokenBody: Decodable { let token: String }

    @Test func databaseLockedButSnapshotUnlockedNeedsTheLibraryKey() async throws {
        let fx = try TestLibraryFixture(name: "G62-l1", bookCount: 2, locked: true, password: "pw"); defer { fx.cleanup() }
        let lib = stale(fx, isLocked: false)
        try await makeApp([lib]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books", method: .get,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .forbidden)
                #expect(r.headers[.init("X-Library-Locked")!] == "1")
            }
            var libraryToken = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/unlock", method: .post,
                                     headers: [.authorization: "Bearer tk"],
                                     body: .init(string: #"{"password":"pw"}"#)) { r in
                libraryToken = try JSONDecoder().decode(UnlockReplyBody.self, from: Data(buffer: r.body)).libraryToken
            }
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books", method: .get,
                                     headers: [.authorization: "Bearer tk", .init("X-Library-Token")!: libraryToken]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func databaseClearedButSnapshotLockedPassesWithoutAKey() async throws {
        let fx = try TestLibraryFixture(name: "G62-l2", bookCount: 2); defer { fx.cleanup() }
        let lib = stale(fx, isLocked: true)
        try await makeApp([lib]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books", method: .get,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// Q6 (a): 施錠の状態を読めない（閉じた DB）なら 503。施錠の 403 と取り違えないよう `X-Library-Locked` は付けない。
    @Test func closedDatabaseIs503WithoutTheLockedHeader() async throws {
        let fx = try TestLibraryFixture(name: "G62-l3", bookCount: 1); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        fx.db.close()
        try await makeApp([lib]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books", method: .get,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .serviceUnavailable)
                #expect(r.headers[.init("X-Library-Locked")!] == nil)
            }
        }
    }

    /// 返す書庫の `isLocked` は、DB から読んだ判定と同じ（G60 の本専用トークンの発行がこれで分岐する）。
    @Test func resolveReturnsTheJudgedLockState() async throws {
        let locked = try TestLibraryFixture(name: "G62-r1", bookCount: 1, locked: true, password: "pw"); defer { locked.cleanup() }
        let open = try TestLibraryFixture(name: "G62-r2", bookCount: 1); defer { open.cleanup() }
        let a = stale(locked, isLocked: false)
        let b = stale(open, isLocked: true)
        let store = LibraryTokenStore()
        let resolver = LibraryResolver(dataSource: StaticLibraryDataSource(libraries: [a, b]), tokenStore: store)

        let credential = try #require(try a.readLockCredential())
        let token = await store.issueToken(for: a.uuid, credential: credential)
        let resolvedA = try #require(try await resolver.resolve(uuid: a.uuid, libraryToken: token))
        #expect(resolvedA.isLocked == true)
        let resolvedB = try #require(try await resolver.resolve(uuid: b.uuid, libraryToken: nil))
        #expect(resolvedB.isLocked == false)
    }

    /// 本専用トークンは、1 回読んだハッシュの指紋で照合される（スナップショットが無施錠でも）。
    @Test func viewerAccessIsCheckedAgainstTheHashReadOnce() async throws {
        let fx = try TestLibraryFixture(name: "G62-v1", bookCount: 1, locked: true, password: "pw"); defer { fx.cleanup() }
        let lib = stale(fx, isLocked: false)
        let resolver = LibraryResolver(dataSource: StaticLibraryDataSource(libraries: [lib]), tokenStore: LibraryTokenStore())
        let credential = try #require(try lib.readLockCredential())

        let good = ViewerBookAccess(libraryUUID: lib.uuid, bookID: 1,
                                    lockFingerprint: ViewerTokenStore.lockFingerprint(for: credential))
        let resolved = try #require(try await resolver.resolve(uuid: lib.uuid, libraryToken: nil, viewerAccess: good))
        #expect(resolved.isLocked == true)

        let stalePrint = ViewerBookAccess(libraryUUID: lib.uuid, bookID: 1,
                                          lockFingerprint: ViewerTokenStore.lockFingerprint(for: "another-hash"))
        await #expect(throws: LibraryAccessError.self) {
            _ = try await resolver.resolve(uuid: lib.uuid, libraryToken: nil, viewerAccess: stalePrint)
        }
    }

    /// G60 の本専用トークンの発行（`POST …/viewer-token`）は、DB だけで施錠された書庫で書庫の鍵を求める。
    @Test func viewerTokenIssuingOnADatabaseOnlyLockedLibraryNeedsTheLibraryKey() async throws {
        let fx = try TestLibraryFixture(name: "G62-v2", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let (bookID, _) = try fx.addFolderBook(imageCount: 1)
        let lib = stale(fx, isLocked: false)
        let suite = "g62-viewer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ViewerTokenStore(defaults: defaults)
        let credential = try #require(try lib.readLockCredential())

        try await makeApp([lib], viewerTokens: store).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .forbidden)
                #expect(r.headers[.init("X-Library-Locked")!] == "1")
            }
            var libraryToken = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/unlock", method: .post,
                                     headers: [.authorization: "Bearer tk"],
                                     body: .init(string: #"{"password":"pw"}"#)) { r in
                libraryToken = try JSONDecoder().decode(UnlockReplyBody.self, from: Data(buffer: r.body)).libraryToken
            }
            var issued = ""
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/viewer-token", method: .post,
                                     headers: [.authorization: "Bearer tk", .init("X-Library-Token")!: libraryToken]) { r in
                #expect(r.status == .ok)
                issued = try JSONDecoder().decode(ViewerTokenBody.self, from: Data(buffer: r.body)).token
            }
            guard case .valid(let record) = store.lookup(token: issued, issuer: .sharedServer) else {
                Issue.record("発行したトークンが保存先に無い"); return
            }
            #expect(record.lockFingerprint == ViewerTokenStore.lockFingerprint(for: credential))
        }
    }

    @Test func librariesListReadsTheLockFromTheDatabase() async throws {
        let fx = try TestLibraryFixture(name: "G62-g1", bookCount: 1, locked: true, password: "pw"); defer { fx.cleanup() }
        let lib = stale(fx, isLocked: false)
        try await makeApp([lib]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get, headers: [.authorization: "Bearer tk"]) { r in
                let list = try JSONDecoder().decode([LibraryDTO].self, from: Data(buffer: r.body))
                #expect(list.first?.locked == true)
            }
        }
    }

    /// Review Focus 2: スナップショットに載ったまま DB が閉じた書庫は、落ちずに施錠として出る。
    @Test func librariesListTreatsAnUnreadableLockAsLocked() async throws {
        let fx = try TestLibraryFixture(name: "G62-g2", bookCount: 1); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        fx.db.close()
        try await makeApp([lib]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get, headers: [.authorization: "Bearer tk"]) { r in
                #expect(r.status == .ok)
                let list = try JSONDecoder().decode([LibraryDTO].self, from: Data(buffer: r.body))
                #expect(list.first?.locked == true)
            }
        }
    }

    @Test func eventHubCoarsensByTheDatabaseLock() async throws {
        let fx = try TestLibraryFixture(name: "G62-e1", bookCount: 1, locked: true, password: "pw"); defer { fx.cleanup() }
        let lib = stale(fx, isLocked: false)
        let core = LibraryServerCore(config: .init(port: 0, token: "tk"), dataSource: StaticLibraryDataSource(libraries: [lib]))
        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()
        await core.eventHub.publish(.bookChanged(library: lib.uuid, bookID: 1))
        #expect(await it.next() == .structureChanged(library: lib.uuid))
    }

    /// Review Focus 2: 施錠の状態を読めない書庫の `bookChanged` も丸める（本の ID を出さない）。
    @Test func eventHubCoarsensWhenTheLockCannotBeRead() async throws {
        let fx = try TestLibraryFixture(name: "G62-e2", bookCount: 1); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        fx.db.close()
        let core = LibraryServerCore(config: .init(port: 0, token: "tk"), dataSource: StaticLibraryDataSource(libraries: [lib]))
        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()
        await core.eventHub.publish(.bookChanged(library: lib.uuid, bookID: 1))
        #expect(await it.next() == .structureChanged(library: lib.uuid))
    }

    @Test func readLockCredentialThrowsOnAClosedDatabase() throws {
        let fx = try TestLibraryFixture(name: "G62-c1", bookCount: 0, locked: true, password: "pw"); defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        #expect(try lib.readLockCredential() != nil)
        fx.db.close()
        #expect(throws: DatabaseError.self) { try lib.readLockCredential() }
        // 今の currentLockCredential() は閉じた DB で nil（＝施錠なし）に化ける。門にはもう使わない。
        #expect(lib.currentLockCredential() == nil)
    }
}
