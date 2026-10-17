// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G63 段 4（Task 3）: 名乗りの整え方と読み方を部品の `StackNestViewerIdentification` に替えても、
/// G60 が保存した値（UserDefaults の `viewer_tokens` の `viewer`・`externalViewerConfirmedViewers`）が同じに読め、
/// 受ける側の記録が変わらないこと。消した `ViewerIdentificationTests` のうち、部品の試験と契約の試験が
/// 押さえていない受ける側の場合（`=` の無い断片・大文字の `KIT=`・整えると空になる値・非 ASCII だけの bundle id）もここで持つ。
@Suite("G63: 名乗りの置き換えと保存済みの値")
struct ViewerIdentificationAdoptionTests {
    /// 2026-06-17 08:53:20 UTC（`JSONEncoder` の既定の Date は 2001-01-01 からの秒＝800,000,000）。
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let name = "g63-identification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    /// G60 の `ViewerTokenStore` が書いた形の `viewer_tokens`（手で書いた JSON）。3 件目は v2 の記録
    /// （`firstUsedAt`・`viewer` が無い）。鍵の平文は持たない（`tokenHash` は架空の値）。
    private static let g60TokensJSON = #"""
    [
      {"id":"tok-kit","tokenHash":"0000000000000000000000000000000000000000000000000000000000000001",
       "libraryUUID":"LIB-1","bookID":7,"issuer":"sharedServer","issuedAt":800000000,"expiresAt":802592000,
       "firstUsedAt":800000005,"viewer":"com.example.my_viewer+beta/2.0-beta+7; format=1; kit=0.1.0"},
      {"id":"tok-messy","tokenHash":"0000000000000000000000000000000000000000000000000000000000000002",
       "libraryUUID":"LIB-1","bookID":8,"issuer":"localEndpoint","issuedAt":800000000,"expiresAt":802592000,
       "bookStamp":"added:1781686400","firstUsedAt":800000006,
       "viewer":"com.example.viewer/1.0 (beta); lang=ja; x; FORMAT=1; KIT=0.2.0"},
      {"id":"tok-v2","tokenHash":"0000000000000000000000000000000000000000000000000000000000000003",
       "libraryUUID":"LIB-1","bookID":9,"issuer":"sharedServer","issuedAt":800000000,"expiresAt":802592000}
    ]
    """#

    /// G60 の `ConfirmedViewerStore` が書いた形の `externalViewerConfirmedViewers`（鍵は小文字の bundle id）。
    private static let g60ConfirmedJSON = #"""
    {"com.example.app":{"bundleIdentifier":"com.example.App","viewerVersion":"1.80","formatVersion":1,
                        "confirmedAt":800000000}}
    """#

    /// G60 が保存した鍵の記録は、置き換えの後も同じに読め、その `viewer` から確認できた対応ビューアを記録すると
    /// G60 と同じ bundle id・版・`format=` になる（`ExternalViewerHandoff` が `record.viewer` を渡す道）。
    @Test func tokensStoredByG60ReadAndRecordTheSame() throws {
        let (defaults, done) = freshDefaults()
        defer { done() }
        defaults.set(Data(Self.g60TokensJSON.utf8), forKey: ViewerTokenStore.defaultsKey)
        let tokens = ViewerTokenStore(defaults: defaults)
        #expect(tokens.allRecords().count == 3)

        let kit = try #require(tokens.record(id: "tok-kit"))
        #expect(kit.viewer == "com.example.my_viewer+beta/2.0-beta+7; format=1; kit=0.1.0")
        #expect(kit.firstUsedAt == t0.addingTimeInterval(5))
        let messy = try #require(tokens.record(id: "tok-messy"))
        #expect(messy.viewer == "com.example.viewer/1.0 (beta); lang=ja; x; FORMAT=1; KIT=0.2.0")
        let v2 = try #require(tokens.record(id: "tok-v2"))
        #expect(v2.viewer == nil && v2.firstUsedAt == nil, "v2 の記録は今までどおり未使用")

        let confirmed = ConfirmedViewerStore(defaults: defaults)
        #expect(confirmed.record(appBundleIdentifier: "com.example.KitApp", viewer: kit.viewer, at: t0)
                == ConfirmedViewer(bundleIdentifier: "com.example.KitApp", viewerVersion: "2.0-beta+7",
                                   formatVersion: 1, confirmedAt: t0))
        // `=` の無い断片（x）と知らない引数（lang=）は読み飛ばし、`FORMAT=` は大文字でも読む。
        #expect(confirmed.record(appBundleIdentifier: nil, viewer: messy.viewer, at: t0)
                == ConfirmedViewer(bundleIdentifier: "com.example.viewer", viewerVersion: "1.0 (beta)",
                                   formatVersion: 1, confirmedAt: t0))
        // 再起動の後（新しいインスタンス）も同じ。
        #expect(ConfirmedViewerStore(defaults: defaults).confirmed(bundleIdentifier: "com.example.viewer")?.viewerVersion
                == "1.0 (beta)")
    }

    /// G60 が書いた確認できた対応ビューアの記録は、置き換えの後も同じに読め、古い日時では上書きされない。
    @Test func confirmedViewersStoredByG60ReadTheSame() {
        let (defaults, done) = freshDefaults()
        defer { done() }
        defaults.set(Data(Self.g60ConfirmedJSON.utf8), forKey: ConfirmedViewerStore.defaultsKey)
        let store = ConfirmedViewerStore(defaults: defaults)
        let expected = ConfirmedViewer(bundleIdentifier: "com.example.App", viewerVersion: "1.80", formatVersion: 1,
                                       confirmedAt: t0)
        #expect(store.confirmed(bundleIdentifier: "COM.EXAMPLE.APP") == expected)
        #expect(store.record(appBundleIdentifier: "com.example.App", viewer: "com.example.viewer/1.70; format=1",
                             at: t0.addingTimeInterval(-1)) == expected, "古い日時では上書きしない")
        #expect(store.record(appBundleIdentifier: "com.example.App", viewer: "com.example.viewer/1.90; format=1; kit=0.1.0",
                             at: t0.addingTimeInterval(1))
                == ConfirmedViewer(bundleIdentifier: "com.example.App", viewerVersion: "1.90", formatVersion: 1,
                                   confirmedAt: t0.addingTimeInterval(1)))
    }

    /// 鍵の記録に保存する名乗りの形（`recordFirstUse` の整え方）が G60 と同じ。部品の試験に無い入力も含む。
    @Test func firstUseStoresTheSameStringAsG60() {
        let (defaults, done) = freshDefaults()
        defer { done() }
        let store = ViewerTokenStore(defaults: defaults)
        let cases: [(raw: String?, stored: String?)] = [
            (" com.example.viewer\r\n/1.0 (beta); lang=ja; x; FORMAT=1; KIT=0.2.0 ",
             "com.example.viewer/1.0 (beta); lang=ja; x; FORMAT=1; KIT=0.2.0"),
            ("ビューア/1.0", "/1.0"),
            (String(repeating: "\u{1}", count: 1000), nil),
            (String(repeating: "a", count: 250) + "/1; format=1", String(repeating: "a", count: 200)),
            (nil, nil),
        ]
        for (i, c) in cases.enumerated() {
            let issued = store.issue(libraryUUID: "LIB-1", bookID: i + 1, issuer: .sharedServer, lockCredential: nil,
                                     now: t0)
            #expect(store.recordFirstUse(id: issued.record.id, viewer: c.raw, now: t0))
            #expect(store.record(id: issued.record.id)?.viewer == c.stored, "case \(i)")
            #expect(ViewerTokenStore(defaults: defaults).record(id: issued.record.id)?.viewer == c.stored,
                    "読み直しても同じ（case \(i)）")
        }
    }

    /// 受ける側の読み方のうち、部品の試験が別の入力でしか押さえていないもの（G60 の `ViewerIdentificationTests` から）。
    @Test func receiverParsingEdgesStayTheSame() {
        typealias ID = StackNestViewerIdentification
        #expect(ID.parse("com.example.viewer/1.0; lang=ja; format=1; x; KIT=0.2.0")
                == ID(bundleIdentifier: "com.example.viewer", version: "1.0", format: 1, kitVersion: "0.2.0"),
                "`=` の無い断片は読み飛ばし、キーは大文字でも読む")
        #expect(ID.parse("a.b/2.0 (beta); format=1; kit=1")?.version == "2.0 (beta)", "kit= があっても版は変わらない")
        #expect(ID.parse("/1.0") == nil, "G60 が非 ASCII の bundle id から保存した値は名乗りの形ではない")
        #expect(ID.parse(String(repeating: "a", count: 200)) == nil, "200 文字に切った長い bundle id は名乗りの形ではない")
        #expect(ID.parse("jp.example.____/2.0__beta_; format=1; kit=1")
                == ID(bundleIdentifier: "jp.example.____", version: "2.0__beta_", format: 1, kitVersion: "1"))
    }
}
