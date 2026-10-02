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

    /// 版は 32 文字で切る（外から来る値を設定の行にそのまま長く出さない）。
    @Test func versionIsCutTo32Characters() {
        #expect(ViewerIdentification.maxVersionLength == 32)
        let long = "com.example.viewer/" + String(repeating: "9", count: 100) + "; format=1"
        let parsed = ViewerIdentification.parse(long)
        #expect(parsed?.version?.count == ViewerIdentification.maxVersionLength)
        #expect(parsed?.format == 1, "版を切っても format= は読む")
    }

    @Test func rejectsWhatIsNotABundleIdentifier() {
        #expect(ViewerIdentification.parse(nil) == nil)
        #expect(ViewerIdentification.parse("") == nil)
        #expect(ViewerIdentification.parse("/1.0; format=1") == nil)
        #expect(ViewerIdentification.parse("com example/1.0") == nil)
        #expect(ViewerIdentification.parse("ビューア/1.0") == nil, "整えると /1.0 になり、bundle id が空")
    }
}
