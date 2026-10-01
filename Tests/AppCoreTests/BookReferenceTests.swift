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
        BookReference(title: title,
                      book: "http://192.168.1.10:51234/api/v1/libraries/LIB-1/books/42",
                      token: "SECRET-TOKEN", expiresAt: expiresAt,
                      pageCount: 180, direction: "rtl", startPage: 41)
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
}
