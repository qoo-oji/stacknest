// SPDX-License-Identifier: MIT
import Testing
@testable import WashiEPUBAdapter

/// G48-4: ページ送りは native のキー監視（`didReceiveNativeKey`）が WebView より先に横取りして持つ。
/// G49b（2026-09-08）で上流 1.16.1 の修正に伴い `handlesKeyboardNavigation` を既定（true）へ戻したが、
/// この写像は変わらない（Washi の JS が扱う集合は監視側がすべて先に消費するため二重には効かない）。
@Suite("G48-4: ナビゲーションキーの写像")
struct WashiNavigationKeyTests {
    @Test func arrowsAreVisual() {
        #expect(WashiReaderHost.navigationKey(for: 123, shift: false) == .left)
        #expect(WashiReaderHost.navigationKey(for: 124, shift: false) == .right)
    }
    @Test func logicalKeys() {
        #expect(WashiReaderHost.navigationKey(for: 49, shift: false) == .forward)     // Space
        #expect(WashiReaderHost.navigationKey(for: 49, shift: true) == .backward)     // Shift+Space
        #expect(WashiReaderHost.navigationKey(for: 121, shift: false) == .forward)    // PageDown
        #expect(WashiReaderHost.navigationKey(for: 116, shift: false) == .backward)   // PageUp
        #expect(WashiReaderHost.navigationKey(for: 125, shift: false) == .forward)    // ↓
        #expect(WashiReaderHost.navigationKey(for: 126, shift: false) == .backward)   // ↑
    }
    @Test func homeEnd() {
        #expect(WashiReaderHost.navigationKey(for: 115, shift: false) == .home)
        #expect(WashiReaderHost.navigationKey(for: 119, shift: false) == .end)
    }
    @Test("それ以外（`-`・Esc・文字キー）は nil＝扱わない") func othersAreNil() {
        for code: UInt16 in [27, 53, 41, 0, 24] { #expect(WashiReaderHost.navigationKey(for: code, shift: false) == nil) }
    }
}
