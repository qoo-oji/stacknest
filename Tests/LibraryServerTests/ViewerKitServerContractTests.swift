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

/// G63 段 4（spec §11.2 の②③）: 実際のサーバの出力と記録を、StackNestViewerKit の型で読む。
@Suite("G63: 部品との契約（サーバ）")
struct ViewerKitServerContractTests {
    private func makeStore() -> (ViewerTokenStore, () -> Void) {
        let name = "g63-server-contract-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ViewerTokenStore(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    /// ② サーバが返す manifest（`pageOverrides` 付き）を、部品の `StackNestBookManifest.parse` が読める。
    @Test func kitReadsTheServersManifest() async throws {
        let fixture = try TestLibraryFixture(name: "K1", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        let base = "/api/v1/libraries/\(lib.uuid)/books/\(bookID)"
        try await app.test(.router) { client in
            try await client.execute(uri: "\(base)/page-layout", method: .post,
                                     headers: [.authorization: "Bearer W"],
                                     body: .init(string: #"{"page":2,"mode":1}"#)) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "\(base)/manifest", method: .get,
                                     headers: [.authorization: "Bearer R"]) { response in
                #expect(response.status == .ok)
                let body = Data(buffer: response.body)
                let dto = try JSONDecoder().decode(ManifestDTO.self, from: body)
                #expect(dto.pageOverrides == ["2": 1], "pageOverrides の付いた manifest で確かめる")
                let manifest = try StackNestBookManifest.parse(body)
                #expect(manifest.pageCount == dto.pageCount)
                #expect(manifest.direction?.rawValue == dto.direction)
                #expect(manifest.format == dto.format)
                #expect(manifest.etag == dto.etag)
            }
        }
    }

    /// ③ 部品の `headerValue` で組んだ最長の形の名乗り（bundle id と版は 64 文字で切れ、部品の版は 16 文字）を、
    /// サーバの鍵の記録は `kit=` を含めた文字列のまま（200 文字以内）保ち、部品の `parse` で読み戻せる。
    @Test func serverStoresTheKitHeaderAsIs() async throws {
        let fx = try TestLibraryFixture(name: "K2", bookCount: 0)
        defer { fx.cleanup() }
        let (id, _) = try fx.addFolderBook(imageCount: 1)
        let lib = fx.servedLibrary()
        let (store, done) = makeStore()
        defer { done() }
        let stamp = ViewerTokenRecord.bookStamp(dateAdded: try #require(try lib.db.fetchBook(id: id)).dateAdded)
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, bookStamp: stamp, issuer: .sharedServer,
                                 lockCredential: nil)
        let header = StackNestViewerIdentification(
            bundleIdentifier: "com." + String(repeating: "a", count: 70), version: String(repeating: "9", count: 80),
            format: 1, kitVersion: "0.1.0-beta.1+b.7"
        ).headerValue
        #expect(header.count <= StackNestViewerIdentification.maxStoredLength)
        #expect(header.hasSuffix("; format=1; kit=0.1.0-beta.1+b.7"))
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", viewerTokens: store, viewerTokenIssuer: .sharedServer),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)",
                                               HTTPField.Name("X-StackNest-Viewer")!: header]) { response in
                #expect(response.status == .ok)
            }
        }
        let stored = try #require(store.record(id: issued.record.id)?.viewer)
        #expect(stored == header, "部品の名乗りは整えても変わらない（印字できる ASCII・200 文字以内）")
        let parsed = try #require(StackNestViewerIdentification.parse(stored))
        #expect(parsed.bundleIdentifier == "com." + String(repeating: "a", count: 60))
        #expect(parsed.version == String(repeating: "9", count: 64))
        #expect(parsed.format == 1)
        #expect(parsed.kitVersion == "0.1.0-beta.1+b.7")
    }
}
