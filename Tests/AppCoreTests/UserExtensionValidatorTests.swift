// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

/// G64: 足す拡張子の正規化と検証（spec §6.1）。
@Suite("G64: 足す拡張子の検証")
struct UserExtensionValidatorTests {
    @Test("前後の空白・先頭の * と . を 1 つずつ除き、小文字にする",
          arguments: [("tgz", "tgz"), (".TGZ", "tgz"), ("*.tgz", "tgz"), ("  .Avif \n", "avif"), ("*tgz", "tgz")])
    func normalizes(raw: String, expected: String) {
        #expect(UserExtensionValidator.normalize(raw) == expected)
        #expect(UserExtensionValidator.validate(raw, existing: [:]) == .success(expected))
    }

    @Test("空になる入力は empty", arguments: ["", "   ", ".", "*", "*.", " . "])
    func emptyInputs(raw: String) {
        #expect(UserExtensionValidator.validate(raw, existing: [:]) == .failure(.empty))
    }

    @Test("形が合わない入力は invalidFormat",
          arguments: ["a.b", "tar.gz", "t gz", "ｔｇｚ", "拡張子", "-abc", "_abc", "..tgz", "**tgz", "a/b",
                      "abcdefghijklmnopq"])   // 最後は 17 文字
    func malformed(raw: String) {
        #expect(UserExtensionValidator.validate(raw, existing: [:]) == .failure(.invalidFormat))
    }

    @Test("16 文字までは通る・ハイフンとアンダースコアは 2 文字目から")
    func boundaries() {
        #expect(UserExtensionValidator.validate("abcdefghijklmnop", existing: [:]) == .success("abcdefghijklmnop"))
        #expect(UserExtensionValidator.validate("a-b_c", existing: [:]) == .success("a-b_c"))
        #expect(UserExtensionValidator.validate("3gp", existing: [:]) == .success("3gp"))
    }

    @Test("標準の拡張子は断る（大文字・epub・cbt・tar を含む）",
          arguments: [("zip", "zip"), ("JPG", "jpg"), ("epub", "epub"), ("cbt", "cbt"), ("tar", "tar"), (".PDF", "pdf")])
    func standardIsRejected(raw: String, ext: String) {
        #expect(UserExtensionValidator.validate(raw, existing: [:]) == .failure(.standard(ext)))
    }

    @Test("StackNest が使う拡張子は断る",
          arguments: ["stacknest", "stacknestbook", "part", "crdownload", "download", "tmp"])
    func reservedIsRejected(ext: String) {
        #expect(UserExtensionValidator.validate(ext.uppercased(), existing: [:]) == .failure(.reserved(ext)))
    }

    @Test("足し済みは断る（大文字でも同じ拡張子）")
    func duplicateIsRejected() {
        #expect(UserExtensionValidator.validate(".TGZ", existing: ["tgz": .archive]) == .failure(.alreadyAdded("tgz")))
    }

    @Test("100 個までは足せ、101 個目は断る")
    func limit() {
        var map: UserExtensionMap = [:]
        for i in 0..<99 { map["x\(i)"] = .archive }
        #expect(UserExtensionValidator.validate("y", existing: map) == .success("y"))
        map["x99"] = .archive
        #expect(map.count == UserExtensionValidator.maxCount)
        #expect(UserExtensionValidator.validate("y", existing: map) == .failure(.limitReached))
        // 足し済みの判定が上限より先（101 個目でも、同じ拡張子なら「もう追加されています」）。
        #expect(UserExtensionValidator.validate("x0", existing: map) == .failure(.alreadyAdded("x0")))
    }

    @Test("上限の値と振り分け先は作者の決定どおり")
    func decidedValues() {
        #expect(UserExtensionValidator.maxLength == 16)
        #expect(UserExtensionValidator.maxCount == 100)
        #expect(UserExtensionValidator.assignableCategories == [.archive, .image, .video, .text])
    }
}
