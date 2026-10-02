// SPDX-License-Identifier: MIT
import Foundation
import Testing
import LibraryStore
@testable import AppCore

@Suite("G60: 参照ファイル（.stacknestbook・版 1）")
struct BookReferenceTests {
    private func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g60-ref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sample(title: String = "本の題名",
                        expiresAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> BookReference {
        BookReference(version: 1, title: title,
                      book: "http://192.168.1.10:51234/api/v1/libraries/LIB-1/books/42",
                      token: "SECRET-TOKEN", expiresAt: expiresAt,
                      pageCount: 180, direction: "rtl", startPage: 41)
    }

    /// G60 v3: 版はビューアの宣言から選んだ値をそのまま書く。
    @Test func writesTheChosenVersion() throws {
        let ref = BookReference(version: 2, title: "本の題名", book: "http://h:1/api/v1/libraries/L/books/1",
                                token: "T", expiresAt: Date(timeIntervalSince1970: 1_790_000_000),
                                pageCount: 1, direction: "rtl", startPage: 0)
        let obj = try #require(try JSONSerialization.jsonObject(with: ref.encoded()) as? [String: Any])
        #expect(obj["version"] as? Int == 2)
        #expect(ref.version == 2)
    }

    @Test func encodesTheVersionOneFields() throws {
        let ref = sample()
        let data = try ref.encoded()
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(obj.keys) == ["format", "version", "title", "book", "token", "expiresAt",
                                   "pageCount", "direction", "startPage"])
        #expect(obj["format"] as? String == "stacknest-book-reference")
        #expect(obj["version"] as? Int == 1)
        #expect(obj["title"] as? String == "本の題名")
        #expect(obj["book"] as? String == "http://192.168.1.10:51234/api/v1/libraries/LIB-1/books/42")
        #expect(obj["token"] as? String == "SECRET-TOKEN")
        #expect(obj["expiresAt"] as? String == ISO8601DateFormatter().string(from: ref.expiresAt))
        #expect((obj["expiresAt"] as? String)?.hasSuffix("Z") == true)
        #expect(obj["pageCount"] as? Int == 180)
        #expect(obj["direction"] as? String == "rtl")
        #expect(obj["startPage"] as? Int == 41)
        #expect(String(data: data, encoding: .utf8)?.contains(#"\/"#) == false, "URL のスラッシュをエスケープしない")
    }

    @Test func roundTripsAndIgnoresUnknownKeys() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: sample().encoded()) as? [String: Any])
        obj["somethingNew"] = "x"
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(try BookReference.decode(data) == sample())
    }

    @Test func helpers() {
        #expect(BookReference.bookURL(serverBase: URL(string: "http://127.0.0.1:4321/")!, libraryUUID: "LIB-1", bookID: 7)
                == "http://127.0.0.1:4321/api/v1/libraries/LIB-1/books/7")
        #expect(BookReference.bookURL(serverBase: URL(string: "http://h:8080")!, libraryUUID: "LIB-1", bookID: 7)
                == "http://h:8080/api/v1/libraries/LIB-1/books/7")
        #expect(BookReference.directionString(.rightToLeft) == "rtl")
        #expect(BookReference.directionString(.leftToRight) == "ltr")
        #expect(BookReference.clampedStartPage(41, pageCount: 180) == 41)
        #expect(BookReference.clampedStartPage(500, pageCount: 180) == 179)
        #expect(BookReference.clampedStartPage(-3, pageCount: 180) == 0)
        #expect(BookReference.clampedStartPage(5, pageCount: 0) == 0)
    }

    @Test func writesWithOwnerOnlyPermissions() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let url = try store.write(sample(), origin: .local, libraryUUID: "LIB-1", bookID: 42)
        #expect(url.lastPathComponent == "本の題名.stacknestbook")
        #expect(url.deletingLastPathComponent().path
                == base.appendingPathComponent("ViewerHandoff/local/LIB-1/42").path)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let roomAttrs = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((roomAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let rootAttrs = try FileManager.default.attributesOfItem(atPath: store.root.path)
        #expect((rootAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for sub in ["ViewerHandoff/local", "ViewerHandoff/local/LIB-1"] {
            let a = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(sub).path)
            #expect((a[.posixPermissions] as? NSNumber)?.intValue == 0o700, "\(sub)")
        }
        #expect(try BookReference.decode(Data(contentsOf: url)) == sample())
    }

    @Test func overwritesAndKeepsOneFilePerBook() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        _ = try store.write(sample(title: "旧題"), origin: .local, libraryUUID: "LIB-1", bookID: 42)
        let url = try store.write(sample(title: "新題"), origin: .local, libraryUUID: "LIB-1", bookID: 42)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["新題.stacknestbook"])
    }

    @Test func titleIsMadeSafe() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        #expect(try store.write(sample(title: "a/b:c"), origin: .local, libraryUUID: "LIB-1", bookID: 1)
                    .lastPathComponent == "a-b-c.stacknestbook")
        #expect(try store.write(sample(title: ""), origin: .local, libraryUUID: "LIB-1", bookID: 2)
                    .lastPathComponent == "2.stacknestbook")
    }

    @Test func remoteOriginsAreSeparated() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let serverID = UUID()
        let url = try store.write(sample(), origin: .remote(serverID: serverID), libraryUUID: "LIB-1", bookID: 42)
        #expect(url.deletingLastPathComponent().path
                == base.appendingPathComponent("ViewerHandoff/remote-\(serverID.uuidString)/LIB-1/42").path)
    }

    @Test func rejectsUnsafeLibraryComponents() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        for bad in ["../x", "a/b", "", ".", "..", "lib name"] {
            #expect(throws: BookReferenceStore.WriteError.invalidLibraryUUID) {
                try store.write(sample(), origin: .local, libraryUUID: bad, bookID: 1)
            }
        }
    }

    @Test func pruneRemovesExpiredAndBrokenFiles() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keep = try store.write(sample(expiresAt: now.addingTimeInterval(3600)),
                                   origin: .local, libraryUUID: "LIB-1", bookID: 1)
        let gone = try store.write(sample(expiresAt: now.addingTimeInterval(-1)),
                                   origin: .local, libraryUUID: "LIB-1", bookID: 2)
        let brokenRoom = store.root.appendingPathComponent("local/LIB-2/3", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenRoom, withIntermediateDirectories: true)
        let broken = brokenRoom.appendingPathComponent("x.stacknestbook")
        try Data("not json".utf8).write(to: broken)

        #expect(store.pruneExpired(now: now) == 2)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: keep.path))
        #expect(!fm.fileExists(atPath: gone.path))
        #expect(!fm.fileExists(atPath: broken.path))
        #expect(!fm.fileExists(atPath: gone.deletingLastPathComponent().path), "空になった本の部屋も消す")
        #expect(!fm.fileExists(atPath: store.root.appendingPathComponent("local/LIB-2").path))
        #expect(fm.fileExists(atPath: store.root.path))
    }

    @Test func pruneRemovesOnlyStaleRegularTempFiles() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let fm = FileManager.default
        let now = Date()
        let room = store.root.appendingPathComponent("local/LIB-1/7")
        try fm.createDirectory(at: room, withIntermediateDirectories: true)
        let old = room.appendingPathComponent(".tmp-x")
        let fresh = room.appendingPathComponent(".tmp-y")
        try Data("t".utf8).write(to: old)
        try Data("t".utf8).write(to: fresh)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        let target = base.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: target.path)
        let link = room.appendingPathComponent(".tmp-z")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(store.pruneExpired(now: now) == 1)
        #expect(!fm.fileExists(atPath: old.path), "古い一時ファイルは消す")
        #expect(fm.fileExists(atPath: fresh.path), "新しい一時ファイルは書き込み中かもしれないので残す")
        #expect(fm.fileExists(atPath: target.path), "リンクは辿らず、リンク先は残す")
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func tightensPreExistingLooseDirectories() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let levels = [store.root,
                      store.root.appendingPathComponent("local"),
                      store.root.appendingPathComponent("local/LIB-1"),
                      store.root.appendingPathComponent("local/LIB-1/42")]
        try FileManager.default.createDirectory(at: levels[3], withIntermediateDirectories: true)
        for l in levels { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: l.path) }
        let url = try store.write(sample(), origin: .local, libraryUUID: "LIB-1", bookID: 42)
        for l in levels { #expect(try mode(l) == 0o700, "\(l.lastPathComponent)") }
        #expect(try mode(url) == 0o600)
    }

    @Test func leavesNoTemporaryFileBehind() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let url = try store.write(sample(), origin: .local, libraryUUID: "LIB-1", bookID: 42)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }

    @Test func symlinkedRoomIsReplacedWithoutTouchingTheTarget() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let victim = outside.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: victim)
        let lib = store.root.appendingPathComponent("local/LIB-1", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("42"), withDestinationURL: outside)

        let url = try store.write(sample(), origin: .local, libraryUUID: "LIB-1", bookID: 42)
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(try mode(outside) == 0o755)
        let type = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.type] as? FileAttributeType
        #expect(type == .typeDirectory)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    }

    @Test func pruneDoesNotFollowSymlinksOutOfTheRoot() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let outsideEmpty = base.appendingPathComponent("outside/empty", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideEmpty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.root.appendingPathComponent("link"),
            withDestinationURL: base.appendingPathComponent("outside"))
        store.pruneExpired()
        #expect(FileManager.default.fileExists(atPath: outsideEmpty.path))
    }

    @Test func descriptionsNeverShowTheToken() {
        #expect(!String(describing: sample()).contains("SECRET-TOKEN"))
        #expect(!String(reflecting: sample()).contains("SECRET-TOKEN"))
        #expect(!"\(sample())".contains("SECRET-TOKEN"))
    }
}
