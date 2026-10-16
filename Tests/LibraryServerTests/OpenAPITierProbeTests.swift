// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
@testable import LibraryServer

/// G65（spec §6.3 後半）: 文書の x-stacknest-tier がコードの tier と一致すること。
/// 一段低い鍵で 403（施錠の 403 ではない）、ちょうどの鍵で 403 でない。書庫は配っていない UUID
/// （resolve が tier より先にある handler なら 404 になり、順番の誤りも見える）・本文は空なので、何も書かれない。
@Suite("G65: 文書の tier とコードの tier")
struct OpenAPITierProbeTests {
    private static let lockedHeader = HTTPField.Name("X-Library-Locked")!

    private func call(_ client: some TestClientProtocol, _ method: String, _ uri: String, token: String) async throws -> (HTTPResponse.Status, Bool) {
        try await client.execute(uri: uri, method: HTTPRequest.Method(rawValue: method)!,
                                 headers: [.authorization: "Bearer \(token)"]) { r in
            (r.status, r.headers[Self.lockedHeader] != nil)
        }
    }

    @Test func documentedTierMatchesTheCode() async throws {
        let ops = try OpenAPISpecReader.operations(in: OpenAPISpecReader.specText())
        let probed = ops.filter { ["edit", "admin"].contains($0.fields["x-stacknest-tier"] ?? "") }
        #expect(probed.count == 46, "edit・admin の操作の数が変わった（今は 46）。増えたなら期待を直す")
        let repo = G65ServerFixture.makeRepo()
        try await G65ServerFixture.core(repo: repo).buildApplication().test(.router) { client in
            for op in probed {
                let tier = op.fields["x-stacknest-tier"]!
                let lower = tier == "admin" ? G65ServerFixture.editToken : G65ServerFixture.readToken
                let exact = tier == "admin" ? G65ServerFixture.adminToken : G65ServerFixture.editToken
                let uri = G65ServerFixture.uri(for: op.path)
                let (low, lowLocked) = try await call(client, op.method, uri, token: lower)
                #expect(low == .forbidden, "\(op.key): 文書は \(tier) だが、一段低い鍵で \(low.code)")
                #expect(!lowLocked, "\(op.key): 一段低い鍵で施錠の 403 が出た（tier の確認より施錠が先）")
                let (ok, _) = try await call(client, op.method, uri, token: exact)
                #expect(ok != .forbidden, "\(op.key): 文書は \(tier) だが、\(tier) の鍵で 403（文書の tier が低すぎる）")
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
}
