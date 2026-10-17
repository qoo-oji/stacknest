// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G63 段 4（spec §11.2「作る側の互換」）: StackNest が書く参照ファイルのバイト列を凍結する。部品より前のビューア
/// （参照ファイルを自前で読む実装）は、このバイト列を読む。置き換えの前（G60 の `BookReference.encoded()`）と後
/// （StackNestViewerKit の `encodedJSON()`）で同じバイト列になることを、この 1 つの表で押さえる。
@Suite("G63: 参照ファイルのバイト列（golden）")
struct BookReferenceGoldenTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let title: String
        let book: String
        let token: String
        let expiresAt: Date
        let pageCount: Int
        let direction: String
        let startPage: Int
        let golden: String

        var testDescription: String { name }

        /// G60 の型（段 4 の Task 2 で消える）。
        func g60Reference() -> BookReference {
            BookReference(version: 1, title: title, book: book, token: token, expiresAt: expiresAt,
                          pageCount: pageCount, direction: direction, startPage: startPage)
        }

        func kitReference() throws -> StackNestBookReference {
            try StackNestBookReference(
                version: 1, title: title, bookURL: URL(string: book)!, token: token, expiresAt: expiresAt,
                pageCount: pageCount, direction: StackNestReadingDirection(rawValue: direction), startPage: startPage)
        }
    }

    /// 2099-12-31T00:00:00Z（部品の Documentation/Samples と同じ期限）。
    static let farFuture = Date(timeIntervalSince1970: 4_102_358_400)
    /// 2027-01-15T08:00:00Z。
    static let early2027 = Date(timeIntervalSince1970: 1_800_000_000)

    static let cases: [Case] = [
        Case(name: "ローカルの本（部品の reference-v1.stacknestbook と同じ 334 バイト）",
             title: "Example Book",
             book: BookReference.bookURL(serverBase: URL(string: "http://127.0.0.1:51234/")!,
                                         libraryUUID: "00000000-0000-4000-8000-000000000001", bookID: 42),
             token: "example-token-not-a-secret", expiresAt: farFuture, pageCount: 180, direction: "rtl",
             startPage: 41,
             golden: #"""
             {
               "book" : "http://127.0.0.1:51234/api/v1/libraries/00000000-0000-4000-8000-000000000001/books/42",
               "direction" : "rtl",
               "expiresAt" : "2099-12-31T00:00:00Z",
               "format" : "stacknest-book-reference",
               "pageCount" : 180,
               "startPage" : 41,
               "title" : "Example Book",
               "token" : "example-token-not-a-secret",
               "version" : 1
             }
             """#),
        Case(name: "中継の本（日本語の題名・スラッシュ・引用符・base64 の鍵）",
             title: "日本語の題名 / \"引用\"",
             book: BookReference.relayURL(localBase: URL(string: "http://127.0.0.1:4321/")!, relayID: "R-1"),
             token: "q8Zk3nJ0r4bW+sYt1uVw2xYz3aBcDeFgHiJkLmNoPq0=", expiresAt: early2027, pageCount: 20,
             direction: "ltr", startPage: 7,
             golden: #"""
             {
               "book" : "http://127.0.0.1:4321/api/v1/relay/R-1",
               "direction" : "ltr",
               "expiresAt" : "2027-01-15T08:00:00Z",
               "format" : "stacknest-book-reference",
               "pageCount" : 20,
               "startPage" : 7,
               "title" : "日本語の題名 / \"引用\"",
               "token" : "q8Zk3nJ0r4bW+sYt1uVw2xYz3aBcDeFgHiJkLmNoPq0=",
               "version" : 1
             }
             """#),
        Case(name: "IPv6 の区域 ID 付きの基点",
             title: "IPv6",
             book: BookReference.bookURL(serverBase: URL(string: "http://[fe80::1%25en0]:51234/")!,
                                         libraryUUID: "LIB-1", bookID: 7),
             token: "T0k3n", expiresAt: early2027, pageCount: 3, direction: "rtl", startPage: 0,
             golden: #"""
             {
               "book" : "http://[fe80::1%25en0]:51234/api/v1/libraries/LIB-1/books/7",
               "direction" : "rtl",
               "expiresAt" : "2027-01-15T08:00:00Z",
               "format" : "stacknest-book-reference",
               "pageCount" : 3,
               "startPage" : 0,
               "title" : "IPv6",
               "token" : "T0k3n",
               "version" : 1
             }
             """#),
    ]

    @Test("1 件目は部品の Documentation/Samples/reference-v1.stacknestbook と同じ大きさ")
    func firstCaseIsTheKitsSampleSize() {
        // 計画を書く段で、このバイト列と部品の reference-v1.stacknestbook の SHA-256 が一致することを確かめた。
        #expect(Data(Self.cases[0].golden.utf8).count == 334)
        #expect(Data(Self.cases[1].golden.utf8).count == 322)
        #expect(Data(Self.cases[2].golden.utf8).count == 276)
    }

    @Test("G60 の書き手のバイト列が golden と一致する", arguments: BookReferenceGoldenTests.cases)
    func g60EncoderMatchesGolden(_ c: Case) throws {
        #expect(try c.g60Reference().encoded() == Data(c.golden.utf8))
    }

    @Test("部品の書き手のバイト列が golden と一致し、部品の読み手が読み戻せる", arguments: BookReferenceGoldenTests.cases)
    func kitEncoderMatchesGolden(_ c: Case) throws {
        let reference = try c.kitReference()
        #expect(try reference.encodedJSON() == Data(c.golden.utf8))
        #expect(try StackNestBookReference.parse(Data(c.golden.utf8)) == reference)
    }

    /// ① 店（`BookReferenceStore`）が書いたファイルは golden のバイト列で、部品が読める。
    @Test("① 店が書いた参照ファイルは golden のバイト列で、部品が読める", arguments: BookReferenceGoldenTests.cases)
    func storeWritesGoldenBytesTheKitReads(_ c: Case) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("g63-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BookReferenceStore(baseDirectory: base)
        let url = try store.write(c.g60Reference(), origin: .local, libraryUUID: "LIB-1", bookID: 7)
        #expect(try Data(contentsOf: url) == Data(c.golden.utf8))
        #expect(try StackNestBookReference.load(contentsOf: url) == c.kitReference())
    }
}
