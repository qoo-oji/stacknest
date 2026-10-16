// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import AppCore
@testable import LibraryServer

/// G65（spec §6.3 後半）: 文書の x-stacknest-tier がコードの tier と一致すること。
/// - 下向き（edit・admin）: 一段低い鍵で 403（施錠の 403 ではない）、ちょうどの鍵で 403 でない。
/// - 上向き（read）: read の鍵で 403 でない（文書は read・コードは edit 以上、の食い違いを落とす）。
/// 書庫は配っていない UUID（resolve が tier より先にある handler なら 404 になり、順番の誤りも見える）・本文は空なので、何も書かれない。
@Suite("G65: 文書の tier とコードの tier")
struct OpenAPITierProbeTests {
    private static let lockedHeader = HTTPField.Name("X-Library-Locked")!

    /// 操作の確かめ方。
    enum Probe: Equatable {
        /// edit・admin: 一段低い鍵とちょうどの鍵で呼ぶ。
        case downward
        /// read: read の鍵で呼ぶ。
        case upward
        /// 呼ばない（理由付き）。
        case skipped(String)
    }

    /// tier では決まらず、操作を名指しして呼ばないもの → 理由。
    static let notProbed: [String: String] = [
        "GET /events": "SSE の流れは心拍で続き切れないので、.router の試験では応答が終わらない",
    ]

    /// 文書の操作 1 つをどう確かめるか。tier が知らない値なら nil（下の試験が落とす）。
    static func probe(for op: OpenAPIOperation) -> Probe? {
        if let reason = notProbed[op.key] { return .skipped(reason) }
        switch op.fields["x-stacknest-tier"] ?? "" {
        case "edit", "admin": return .downward
        case "read": return .upward
        case "none": return .skipped("鍵が要らない（tier の段が無い）")
        case "relay": return .skipped("中継の鍵だけが通る道（read・edit・admin の段の外）")
        default: return nil
        }
    }

    private func call(_ client: some TestClientProtocol, _ method: String, _ uri: String, token: String) async throws -> (HTTPResponse.Status, Bool) {
        try await client.execute(uri: uri, method: HTTPRequest.Method(rawValue: method)!,
                                 headers: [.authorization: "Bearer \(token)"]) { r in
            (r.status, r.headers[Self.lockedHeader] != nil)
        }
    }

    /// どの操作も、下向き・上向きのどちらかで確かめるか、理由を付けて呼ばないかのどれかに入ること。
    /// 操作の数は数えない（道を足しても、文書を書けばこの試験は直さなくてよい）。
    @Test func everyOperationIsProbedOrSkippedWithAReason() throws {
        let ops = try OpenAPISpecReader.operations(in: OpenAPISpecReader.specText())
        let unclassified = ops.filter { Self.probe(for: $0) == nil }.map(\.key)
        #expect(unclassified.isEmpty, "tier の確かめ方が決まらない操作（x-stacknest-tier の値を見る）: \(unclassified)")
        let stale = Set(Self.notProbed.keys).subtracting(ops.map(\.key))
        #expect(stale.isEmpty, "呼ばない操作の表にあって文書に無い（表が古い）: \(stale.sorted())")
        // 読み方が壊れて全部が「呼ばない」に落ちれば、下の 2 つの試験は何も呼ばずに通ってしまう。
        #expect(ops.contains { Self.probe(for: $0) == .downward }, "下向きに確かめる操作が 1 つも無い")
        #expect(ops.contains { Self.probe(for: $0) == .upward }, "上向きに確かめる操作が 1 つも無い")
    }

    @Test func documentedTierMatchesTheCode() async throws {
        let ops = try OpenAPISpecReader.operations(in: OpenAPISpecReader.specText())
        let probed = ops.filter { Self.probe(for: $0) == .downward }
        let repo = G65ServerFixture.makeRepo()
        try await G65ServerFixture.core(repo: repo).buildApplication().test(.router) { client in
            for op in probed {
                let tier = op.fields["x-stacknest-tier"]!
                let lower = tier == "admin" ? G65ServerFixture.editToken : G65ServerFixture.readToken
                let exact = tier == "admin" ? G65ServerFixture.adminToken : G65ServerFixture.editToken
                let uri = G65ServerFixture.uri(for: op.path)
                let (low, lowLocked) = try await call(client, op.method, uri, token: lower)
                #expect(low == .forbidden, "\(op.key): 文書は \(tier) だが、一段低い鍵で \(low.code)")
                // 書庫を配っていないので、この fixture では出ない（X-Library-Locked は書庫が解決した後にだけ付く）。
                // 「tier の確認より施錠が先」を確かめてはいない。将来 fixture に施錠した書庫を足したときの備え。
                #expect(!lowLocked, "\(op.key): 一段低い鍵で施錠の 403 が出た（tier の確認より施錠が先）")
                let (ok, _) = try await call(client, op.method, uri, token: exact)
                #expect(ok != .forbidden, "\(op.key): 文書は \(tier) だが、\(tier) の鍵で 403（文書の tier が低すぎる）")
                #expect(ok != .unauthorized, "\(op.key): \(tier) の鍵が通らない（tier を確かめていない）")
                // GET 以外のちょうどの鍵の呼び出しが成功（2xx）したら、何かを書いたかもしれない。
                // 書庫の道は 404、/local は 501 で止まる。書庫も closure も持たない `PUT /import-config`（全体の取り込みの既定）は、
                // 本文が空で `GlobalImportConfigDTO` の decode が 400 を返すことだけが、実際の UserDefaults.standard への
                // 書き込みを止めている（decoder に既定値が入るとここで落ちる）。
                // 前後の値の比べ合いにしないのは、ImportConfigEndpointTests が同じ鍵を並行して書き戻すため（比べると揺れる）。
                if op.method != "GET" {
                    #expect(!(200..<300).contains(ok.code), "\(op.key): ちょうどの鍵の空の呼び出しが \(ok.code) で通った（何か書いたかもしれない）")
                }
            }
            // 問い合わせで tier が変わる唯一の操作（x-stacknest-tier-note）。
            let trash = G65ServerFixture.uri(for: "/libraries/{lib}/books/{id}") + "?trash=true"
            let (e, _) = try await call(client, "DELETE", trash, token: G65ServerFixture.editToken)
            #expect(e == .forbidden, "DELETE ?trash=true: edit の鍵で \(e.code)")
            let (a, _) = try await call(client, "DELETE", trash, token: G65ServerFixture.adminToken)
            #expect(a != .forbidden, "DELETE ?trash=true: admin の鍵で 403")
        }
        // ちょうどの鍵の呼び出しは、本文が空・書庫が無い・closure が無いので書き込む前に失敗するはず。それが崩れていないこと。
        #expect(repo.all().map(\.id).sorted() == ["g65-a", "g65-e", "g65-r"], "tier の確かめがグラントを書き換えた")
    }

    /// 文書が read の操作を read の鍵で呼んで 403 でないこと（文書は read・コードは edit 以上、を落とす）。
    /// `{lib}` を持つ道は配っていない書庫で 404 になる。持たない道は読むだけか（`GET /libraries`・`GET /me`・
    /// `GET /import-config`・`GET /viewer-tokens/{tokenID}`）、メモリ上のセッションの鍵を 1 つ出すだけ（`POST /session`）。
    @Test func readOperationsAcceptTheReadKey() async throws {
        let ops = try OpenAPISpecReader.operations(in: OpenAPISpecReader.specText())
        let probed = ops.filter { Self.probe(for: $0) == .upward }
        let repo = G65ServerFixture.makeRepo()
        // 本専用の鍵の置き場は、使い捨ての UserDefaults の区画で作る（読むだけで、発行は書庫が無いので起きない）。
        // 置き場が無いと viewer-token の 2 つの道は tier を見る前に 501 で止まり、確かめにならない。
        let suite = "g65-tier-probe-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = G65ServerFixture.core(repo: repo, viewerTokens: ViewerTokenStore(defaults: defaults))
        try await core.buildApplication().test(.router) { client in
            for op in probed {
                let (status, _) = try await call(client, op.method, G65ServerFixture.uri(for: op.path),
                                                 token: G65ServerFixture.readToken)
                #expect(status != .forbidden, "\(op.key): 文書は read だが、read の鍵で 403（コードは edit 以上を求めている）")
                // 401・501 は、handler が tier を見る前に止まったか鍵が通らなかった印で、確かめになっていない。
                #expect(status != .unauthorized, "\(op.key): read の鍵が通らない（tier を確かめていない）")
                #expect(status != .notImplemented, "\(op.key): fixture に足りない設定があり、tier を見る前に 501 で止まった")
            }
        }
        #expect(repo.all().map(\.id).sorted() == ["g65-a", "g65-e", "g65-r"], "read の確かめがグラントを書き換えた")
    }
}
