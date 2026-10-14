// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
import StackroomFormat
@testable import LibraryServer

/// G64: サーバ（spec §6.5 (b)・§6.4）。分類はサーバの一覧（`LibraryServerConfig.userExtensions`）で決め、
/// manifest の `format` の語彙は増やさない。読めない本の manifest は今の標準の動画と同じエラー。
@Suite("G64: サーバの標準の tar と足した拡張子")
struct UserExtensionServerTests {
    private let added: UserExtensionMap = ["tgz": .archive, "foo": .image, "docx": .text]

    private func app(_ fixture: TestLibraryFixture) -> some ApplicationProtocol {
        let list = added
        return LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: true, userExtensions: { list }),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// PNG 3 枚の tar を `/usr/bin/tar` で作る。
    private func makeTar(_ url: URL, gzip: Bool) throws {
        let src = url.deletingLastPathComponent().appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        for name in ["p1.png", "p2.png", "p3.png"] { try png.write(to: src.appendingPathComponent(name)) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.arguments = [gzip ? "-czf" : "-cf", url.path, "-C", src.path, "p1.png", "p2.png", "p3.png"]
        try process.run()
        process.waitUntilExit()
    }

    private func addBook(_ fixture: TestLibraryFixture, _ url: URL) throws -> Int {
        try fixture.db.insertBookReturningID(BookRecord(id: 0, title: url.lastPathComponent, path: url.path, dateAdded: Date()))
    }

    private func manifest(_ client: some TestClientProtocol, _ uuid: String, _ id: Int) async throws -> (HTTPResponse.Status, ManifestDTO?) {
        try await client.execute(uri: "/api/v1/libraries/\(uuid)/books/\(id)/manifest", method: .get,
                                 headers: [.authorization: "Bearer R"]) { response in
            (response.status, try? JSONDecoder().decode(ManifestDTO.self, from: Data(buffer: response.body)))
        }
    }

    @Test("標準の cbt と足した tgz: format は archive・ページ・表紙候補")
    func tarBooks() async throws {
        let fixture = try TestLibraryFixture(name: "G64T", bookCount: 0); defer { fixture.cleanup() }
        let cbt = fixture.bundleURL.appendingPathComponent("a.cbt"); try makeTar(cbt, gzip: false)
        let tgz = fixture.bundleURL.appendingPathComponent("b.tgz"); try makeTar(tgz, gzip: true)
        let cbtID = try addBook(fixture, cbt)
        let tgzID = try addBook(fixture, tgz)
        let uuid = fixture.servedLibrary().uuid
        try await app(fixture).test(.router) { client in
            for id in [cbtID, tgzID] {
                let (status, dto) = try await manifest(client, uuid, id)
                #expect(status == .ok)
                #expect(dto?.format == "archive")
                #expect(dto?.pageCount == 3)
                try await client.execute(uri: "/api/v1/libraries/\(uuid)/books/\(id)/pages/0", method: .get,
                                         headers: [.authorization: "Bearer R"]) { response in
                    #expect(response.status == .ok)
                }
                try await client.execute(uri: "/api/v1/libraries/\(uuid)/books/\(id)/cover-candidates", method: .get,
                                         headers: [.authorization: "Bearer R"]) { response in
                    let dto = try JSONDecoder().decode(CoverCandidatesDTO.self, from: Data(buffer: response.body))
                    #expect(dto.entries == ["p1.png", "p2.png", "p3.png"])
                }
                // entry-image も同じ振り分け（足した tgz でも選んだページの画像を返す）。
                try await client.execute(uri: "/api/v1/libraries/\(uuid)/books/\(id)/entry-image?name=p1.png", method: .get,
                                         headers: [.authorization: "Bearer R"]) { response in
                    #expect(response.status == .ok)
                    #expect(response.body.readableBytes > 0)
                }
            }
        }
    }

    @Test("足した画像の format は image（語彙は増えない）")
    func addedImageFormat() async throws {
        let fixture = try TestLibraryFixture(name: "G64I", bookCount: 0); defer { fixture.cleanup() }
        let url = fixture.bundleURL.appendingPathComponent("a.foo")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!.write(to: url)
        let id = try addBook(fixture, url)
        try await app(fixture).test(.router) { client in
            let (status, dto) = try await manifest(client, fixture.servedLibrary().uuid, id)
            #expect(status == .ok)
            #expect(dto?.format == "image")
            #expect(dto?.pageCount == 1)
            // 内容のキャッシュもサーバの一覧で作る（足した画像として 1 ページを返す。一覧を無視すると archive 扱いになり開けない）。
            try await client.execute(uri: "/api/v1/libraries/\(fixture.servedLibrary().uuid)/books/\(id)/pages/0",
                                     method: .get, headers: [.authorization: "Bearer R"]) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("読めない足した拡張子の本の manifest は、標準の動画と同じエラー")
    func unreadableAddedBookFailsLikeAStandardVideo() async throws {
        let fixture = try TestLibraryFixture(name: "G64E", bookCount: 0); defer { fixture.cleanup() }
        let video = try fixture.addUnsupportedFormatBook(extension: "mp4")
        let docx = try fixture.addUnsupportedFormatBook(extension: "docx")
        let junk = fixture.bundleURL.appendingPathComponent("junk.tgz"); try Data("not an archive at all".utf8).write(to: junk)
        let junkID = try addBook(fixture, junk)
        // 比べる相手: 標準の拡張子（cbt）の壊れた本。今のエラーと同じになること。
        let badCBT = fixture.bundleURL.appendingPathComponent("junk.cbt"); try Data("not an archive at all".utf8).write(to: badCBT)
        let badCBTID = try addBook(fixture, badCBT)
        let uuid = fixture.servedLibrary().uuid
        try await app(fixture).test(.router) { client in
            let (videoStatus, _) = try await manifest(client, uuid, video)
            let (docxStatus, _) = try await manifest(client, uuid, docx)
            let (junkStatus, _) = try await manifest(client, uuid, junkID)
            #expect(videoStatus != .ok)
            #expect(docxStatus == videoStatus)
            #expect(junkStatus != .ok, "200・0 ページにしない")
            let (badCBTStatus, _) = try await manifest(client, uuid, badCBTID)
            #expect(badCBTStatus != .ok)
            #expect(junkStatus == badCBTStatus, "標準の壊れたアーカイブと同じエラー")
        }
    }

    @Test("POST books: 標準の cbt と足した tgz にページ数と表紙が付く")
    func addTarBooks() async throws {
        let fixture = try TestLibraryFixture(name: "G64P", bookCount: 0); defer { fixture.cleanup() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-post-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cbt = dir.appendingPathComponent("a.cbt"); try makeTar(cbt, gzip: false)
        let tgz = dir.appendingPathComponent("b.tgz"); try makeTar(tgz, gzip: true)
        let uuid = fixture.servedLibrary().uuid
        try await app(fixture).test(.router) { client in
            let body = try JSONEncoder().encode(AddBooksRequestDTO(paths: [cbt.path, tgz.path]))
            try await client.execute(uri: "/api/v1/libraries/\(uuid)/books", method: .post,
                                     headers: [.authorization: "Bearer W", .contentType: "application/json"],
                                     body: .init(bytes: Array(body))) { response in
                #expect(response.status == .ok)
            }
        }
        for url in [cbt, tgz] {
            let book = try #require(try fixture.db.fetchAllBooks().first { $0.path == url.path })
            #expect(book.pages == 3)
            let thumb = fixture.bundleURL.appendingPathComponent("Thumbnails/\(book.id)/thumbnail.jpg")
            #expect(FileManager.default.fileExists(atPath: thumb.path))
        }
    }
}
