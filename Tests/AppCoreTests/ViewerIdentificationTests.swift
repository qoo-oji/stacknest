// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G60 v3: 対応ビューアの名乗り（`X-StackNest-Viewer: <bundle id>/<版>; format=<版>`）の整え方と読み方。
@Suite("G60 v3: 対応ビューアの名乗り（X-StackNest-Viewer）")
struct ViewerIdentificationTests {
    @Test func sanitizeKeepsPrintableASCIIOnly() {
        #expect(ViewerIdentification.headerName == "X-StackNest-Viewer")
        #expect(ViewerIdentification.maxLength == 200)
        #expect(ViewerIdentification.sanitize(nil) == nil)
        #expect(ViewerIdentification.sanitize("") == nil)
        #expect(ViewerIdentification.sanitize("   ") == nil)
        #expect(ViewerIdentification.sanitize(" com.example.viewer/1.0; format=1 ") == "com.example.viewer/1.0; format=1")
        #expect(ViewerIdentification.sanitize("com.example\u{0}.viewer\r\n/1.0\u{7F}") == "com.example.viewer/1.0")
        #expect(ViewerIdentification.sanitize("ビューア/1.0") == "/1.0")
        #expect(ViewerIdentification.sanitize(String(repeating: "a", count: 1000))?.count == 200)
        #expect(ViewerIdentification.sanitize(String(repeating: "\u{1}", count: 1000)) == nil)
    }

    @Test func parsesTheDocumentedShape() {
        #expect(ViewerIdentification.parse("com.example.viewer/1.80; format=1")
                == ViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.80", format: 1))
        #expect(ViewerIdentification.parse("com.example.viewer")
                == ViewerIdentification(bundleIdentifier: "com.example.viewer", version: nil, format: nil))
        #expect(ViewerIdentification.parse("com.example.viewer/; FORMAT=2")
                == ViewerIdentification(bundleIdentifier: "com.example.viewer", version: nil, format: 2))
        #expect(ViewerIdentification.parse("com.example.viewer/2.0;format=x")?.format == nil)
        #expect(ViewerIdentification.parse("com.example.viewer/2.0 (beta); format=1")?.version == "2.0 (beta)")
        #expect(ViewerIdentification.parse("Com.Example-Viewer/3")?.bundleIdentifier == "Com.Example-Viewer")
    }

    /// 版は 64 文字で切る（送る側と同じ 1 つの定数。外から来る値を設定の行にそのまま長く出さない）。
    @Test func versionIsCutTo64Characters() {
        #expect(ViewerIdentification.maxComponentLength == 64)
        let long = "com.example.viewer/" + String(repeating: "9", count: 100) + "; format=1"
        let parsed = ViewerIdentification.parse(long)
        #expect(parsed?.version?.count == ViewerIdentification.maxComponentLength)
        #expect(parsed?.format == 1, "版を切っても format= は読む")
    }

    @Test func rejectsWhatIsNotABundleIdentifier() {
        #expect(ViewerIdentification.parse(nil) == nil)
        #expect(ViewerIdentification.parse("") == nil)
        #expect(ViewerIdentification.parse("/1.0; format=1") == nil)
        #expect(ViewerIdentification.parse("com example/1.0") == nil)
        #expect(ViewerIdentification.parse("ビューア/1.0") == nil, "整えると /1.0 になり、bundle id が空")
    }

    // MARK: - 送る側（G61 のフォーク・G63 の部品）と同じ文字種と長さ（G60 §5.9 の作業で直す不具合）

    /// 送る側の組み立て（G61 のフォークの `StackNestViewerIdentity.sanitized`・G63 の部品の `headerValue` と同じ規則:
    /// 文字種の外は `_` に替え、bundle id と版は 64 文字・部品の版は 16 文字で切り、引数は format → kit の順）。
    private static func clean(_ text: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars.prefix(max) {
            out.append(ViewerIdentification.isComponentCharacter(scalar) ? scalar : "_")
        }
        return String(out)
    }

    private static func senderHeader(bundle: String, version: String, format: Int, kit: String?) -> String {
        var value = "\(clean(bundle, max: 64))/\(clean(version, max: 64)); format=\(format)"
        if let kit { value += "; kit=\(clean(kit, max: 16))" }
        return value
    }

    /// 送る側が出す文字（`_`・`+`）の bundle id を読む（今まで nil になり、確認できた対応ビューアに版が入らなかった）。
    /// 64 文字までは読み、超えたら・ほかの文字を含んだら名乗りとみなさない。
    @Test func bundleIdentifiersWithUnderscoreAndPlusAreRead() {
        #expect(ViewerIdentification.parse("com.example.my_viewer+beta/1.0; format=1")
                == ViewerIdentification(bundleIdentifier: "com.example.my_viewer+beta", version: "1.0", format: 1))
        #expect(ViewerIdentification.isComponentCharacter("_") && ViewerIdentification.isComponentCharacter("+"))
        #expect(ViewerIdentification.isComponentCharacter("A") && ViewerIdentification.isComponentCharacter("z")
                && ViewerIdentification.isComponentCharacter("0") && ViewerIdentification.isComponentCharacter("-")
                && ViewerIdentification.isComponentCharacter("."))
        for scalar: Unicode.Scalar in [" ", "/", ";", "=", "!", "é", "ビ"] {
            #expect(!ViewerIdentification.isComponentCharacter(scalar), "\(scalar)")
        }
        let id64 = "com." + String(repeating: "a", count: 60)
        #expect(ViewerIdentification.parse(id64 + "/1")?.bundleIdentifier == id64)
        #expect(ViewerIdentification.parse(id64 + "a/1") == nil, "65 文字の bundle id は名乗りの形ではない")
        #expect(ViewerIdentification.parse("com.example.viewer!/1") == nil)
    }

    /// 往復: 送る側が組んだ名乗り（`_`・`+` を含む bundle id・64 文字の版・16 文字の部品の版）は、保存と同じ整え方を
    /// 通しても必ず読める。`kit=` の有無で bundle id・版・`format` は変わらない。
    @Test func senderHeadersRoundTripWithOrWithoutKit() throws {
        let cases: [(bundle: String, version: String, kit: String?)] = [
            ("com.example.viewer", "1.80", "0.1.0"),
            ("com.example.my_viewer+beta", String(repeating: "9", count: 80), "0.1.0-beta.1+build.7"),
            ("jp.example.ビューア", "2.0 (beta)", "1"),
            ("x." + String(repeating: "b", count: 70), "3", nil),
        ]
        for c in cases {
            let withKit = Self.senderHeader(bundle: c.bundle, version: c.version, format: 1, kit: c.kit)
            let withoutKit = Self.senderHeader(bundle: c.bundle, version: c.version, format: 1, kit: nil)
            let stored = try #require(ViewerIdentification.sanitize(withKit))
            #expect(stored == withKit, "送る側の最長も保存の 200 文字に収まる")
            let a = try #require(ViewerIdentification.parse(stored), "\(withKit)")
            let b = try #require(ViewerIdentification.parse(withoutKit), "\(withoutKit)")
            #expect(a.bundleIdentifier == Self.clean(c.bundle, max: 64))
            #expect(a.version == Self.clean(c.version, max: 64))
            #expect(a.format == 1)
            #expect(a.kitVersion == c.kit.map { Self.clean($0, max: 16) })
            #expect(b.kitVersion == nil)
            #expect(a.bundleIdentifier == b.bundleIdentifier && a.version == b.version && a.format == b.format,
                    "kit= の有無で同じ")
        }
    }

    /// 知らない引数・`=` の無い断片は読み飛ばす。キーの大文字・小文字は区別しない。`kit=` は 16 文字で切り、
    /// 文字種の外・空なら nil（ほかは変わらない）。
    @Test func unknownParametersAreIgnoredAndKitIsChecked() {
        let base = ViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.0", format: 1)
        let parsed = ViewerIdentification.parse("com.example.viewer/1.0; lang=ja; format=1; x; KIT=0.2.0")
        #expect(parsed == ViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.0", format: 1,
                                               kitVersion: "0.2.0"))
        #expect(ViewerIdentification.parse("com.example.viewer/1.0; kit=0.1 0; format=1")
                == base, "文字種の外の kit= は読まない（ほかは同じ）")
        #expect(ViewerIdentification.parse("com.example.viewer/1.0; format=1; kit=")?.kitVersion == nil)
        #expect(ViewerIdentification.parse("com.example.viewer/1.0; format=1; kit=" + String(repeating: "7", count: 30))?
                    .kitVersion == String(repeating: "7", count: 16))
    }
}
