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
                        expiresAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws -> StackNestBookReference {
        try StackNestBookReference(version: 1, title: title,
                                   bookURL: URL(string: "http://192.168.1.10:51234/api/v1/libraries/LIB-1/books/42")!,
                                   token: "SECRET-TOKEN", expiresAt: expiresAt,
                                   pageCount: 180, direction: .rightToLeft, startPage: 41)
    }

    /// G63 段 4: 部品の型は、部品が読めない版では作れない（作った参照ファイルが必ず読める）。StackNest が書ける版は
    /// 部品が読める版に含まれる（`ViewerKitContractTests`）ので、ビューアの宣言から選んだ版はいつも作れる。
    @Test func aVersionTheKitCannotReadIsRefused() {
        #expect(throws: StackNestViewerError(.unsupportedVersion, formatVersion: 2)) {
            try StackNestBookReference(version: 2, title: "本の題名",
                                       bookURL: URL(string: "http://h:1/api/v1/libraries/L/books/1")!,
                                       token: "T", expiresAt: Date(timeIntervalSince1970: 1_790_000_000),
                                       pageCount: 1, direction: .rightToLeft, startPage: 0)
        }
    }

    @Test func encodesTheVersionOneFields() throws {
        let ref = try sample()
        let data = try ref.encodedJSON()
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
        var obj = try #require(try JSONSerialization.jsonObject(with: sample().encodedJSON()) as? [String: Any])
        obj["somethingNew"] = "x"
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(try StackNestBookReference.parse(data) == sample())
    }

    @Test func helpers() {
        #expect(BookReferences.bookURL(serverBase: URL(string: "http://127.0.0.1:4321/")!, libraryUUID: "LIB-1", bookID: 7)
                .absoluteString == "http://127.0.0.1:4321/api/v1/libraries/LIB-1/books/7")
        #expect(BookReferences.bookURL(serverBase: URL(string: "http://h:8080")!, libraryUUID: "LIB-1", bookID: 7)
                .absoluteString == "http://h:8080/api/v1/libraries/LIB-1/books/7")
        #expect(BookReferences.direction(.rightToLeft) == .rightToLeft)
        #expect(BookReferences.direction(.leftToRight) == .leftToRight)
        #expect(StackNestBookReference.clampedStartPage(41, pageCount: 180) == 41)
        #expect(StackNestBookReference.clampedStartPage(500, pageCount: 180) == 179)
        #expect(StackNestBookReference.clampedStartPage(-3, pageCount: 180) == 0)
        #expect(StackNestBookReference.clampedStartPage(5, pageCount: 0) == 0)
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
        #expect(try StackNestBookReference.load(contentsOf: url) == sample())
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

    /// Codex P2（5 回目）: 起動時の掃除（別の Task・別のインスタンス）と同じ本の渡しが重なっても、書いたばかりの参照
    /// ファイルを消さない。掃除が消す相手を決めた直後に、別のインスタンスが同じ本（同じ名前）を書きに来る場面を作る。
    /// 書き込みと掃除が並ぶ作りなら、書き込みは掃除が終わるまで待ち、新しいファイルが残る。
    @Test func pruneDoesNotDeleteAReferenceWrittenWhileItRuns() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let writer = BookReferenceStore(baseDirectory: base)
        let now = Date()
        _ = try writer.write(sample(expiresAt: now.addingTimeInterval(-1)), origin: .local, libraryUUID: "LIB-1", bookID: 5)
        let fresh = try sample(expiresAt: now.addingTimeInterval(3600))
        let written = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: Result<URL, any Error>? }
        let box = Box()
        // 差し込みはこの掃除の店だけ（ほかのテストの掃除からは呼ばれない）。
        let pruner = BookReferenceStore(baseDirectory: base, pruneHookBeforeDeletes: {
            // 書き手は専用のスレッドで走らせる。global キューに投げると、並列に走るほかのテストでスレッドが埋まった
            // ときに何秒も始まらず、時間の待ちに間に合わない（CI と負荷をかけた手元で再現した）。
            Thread {
                box.result = Result { try writer.write(fresh, origin: .local, libraryUUID: "LIB-1", bookID: 5) }
                written.signal()
            }.start()
            // 書き込みが掃除と並ばない作りなら、ここで書き終わる。並ぶ作りなら掃除が終わるまで待たされる。
            if written.wait(timeout: .now() + 0.5) == .success { written.signal() }
        })

        pruner.pruneExpired(now: now)
        // 書き終わりの合図を待つ（時間は上限としてだけ使う）。合図の後に読むので、書き手の結果を確かに見る。
        let finished = written.wait(timeout: .now() + 60)
        #expect(finished == .success, "書き手が 60 秒たっても終わらない")

        let url = try #require(try box.result?.get())
        #expect(FileManager.default.fileExists(atPath: url.path), "書いたばかりの参照ファイルが残る")
        let kept = try StackNestBookReference.load(contentsOf: url)
        #expect(kept.expiresAt > now)
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

    /// G63 段 4: 置き換えの前（G60 の書き手）に書かれたファイルも、掃除は今までどおりに扱う。期限の前なら残し、
    /// 期限を過ぎていれば消す。読めないファイルは消す（部品の読み手は G60 より厳しいが、G60 が書いたファイルは読める）。
    @Test func pruneTreatsFilesWrittenBeforeTheAdoptionTheSame() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let fm = FileManager.default
        let golden = Data(BookReferenceGoldenTests.cases[0].golden.utf8)   // G60 が書いていたバイト列（期限 2099 年）
        var files: [URL] = []
        for (index, contents) in [golden, golden, Data(#"{"format":"stacknest-book-reference","version":1}"#.utf8)]
            .enumerated() {
            let room = store.root.appendingPathComponent("local/LIB-9/\(index)", isDirectory: true)
            try fm.createDirectory(at: room, withIntermediateDirectories: true)
            let file = room.appendingPathComponent("Example Book.stacknestbook")
            try contents.write(to: file)
            files.append(file)
        }
        let beforeExpiry = Date(timeIntervalSince1970: 4_102_358_399)
        let atExpiry = Date(timeIntervalSince1970: 4_102_358_400)
        #expect(store.pruneExpired(now: beforeExpiry) == 1, "期限の前の G60 のファイルは残し、項目の欠けたファイルは消す")
        #expect(fm.fileExists(atPath: files[0].path) && fm.fileExists(atPath: files[1].path))
        #expect(!fm.fileExists(atPath: files[2].path))
        #expect(store.pruneExpired(now: atExpiry) == 2, "期限の時刻ちょうどから切れている（今の `expiresAt > now` と同じ）")
        #expect(!fm.fileExists(atPath: files[0].path) && !fm.fileExists(atPath: files[1].path))
    }

    @Test func descriptionsNeverShowTheToken() throws {
        #expect(try !String(describing: sample()).contains("SECRET-TOKEN"))
        #expect(try !String(reflecting: sample()).contains("SECRET-TOKEN"))
        #expect(try !"\(sample())".contains("SECRET-TOKEN"))
    }
}
