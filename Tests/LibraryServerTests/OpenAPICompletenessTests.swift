// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

/// G65（spec §6.3 前半）: openapi.yaml の各操作が必要な項目を持つこと。
@Suite("G65: openapi.yaml の各操作の欠け")
struct OpenAPICompletenessTests {
    static let tiers: Set<String> = ["none", "read", "edit", "admin", "relay"]
    static let responseNames: Set<String> = ["Unauthorized", "Forbidden", "LibraryLocked", "ForbiddenOrLocked", "NotFound"]

    @Test func everyOperationCarriesTheRequiredItems() throws {
        let yaml = try OpenAPISpecReader.specText()
        let ops = try OpenAPISpecReader.operations(in: yaml)
        var problems: [String] = []
        var ids: [String: String] = [:]
        for op in ops {
            for item in ["operationId", "summary", "tags", "x-stacknest-tier", "responses"] where op.fields[item] == nil {
                problems.append("\(op.key): \(item) が無い")
            }
            if let id = op.fields["operationId"] {
                if let other = ids[id] { problems.append("operationId \(id) が重複: \(other) と \(op.key)") }
                ids[id] = op.key
            }
            let tier = op.fields["x-stacknest-tier"] ?? ""
            if !Self.tiers.contains(tier) { problems.append("\(op.key): x-stacknest-tier の値が不正: \(tier)") }
            if (tier == "none") != (op.fields["security"] == "[]") {
                problems.append("\(op.key): x-stacknest-tier: none と security: [] は対で付ける")
            }
            if let lock = op.fields["x-stacknest-lock"], lock != "none" {
                problems.append("\(op.key): x-stacknest-lock の値は none だけ: \(lock)")
            }
            if tier != "none", op.responses["401"] != "Unauthorized" {
                problems.append("\(op.key): 401 に Unauthorized が無い")
            }
            let forbidden = op.responses["403"] ?? "-"
            if ["edit", "admin", "relay"].contains(tier), !["Forbidden", "ForbiddenOrLocked"].contains(forbidden) {
                problems.append("\(op.key): 403 に Forbidden か ForbiddenOrLocked が無い")
            }
            let lockScoped = op.path.hasPrefix("/libraries/{lib}") || op.path.hasPrefix("/local/libraries/{uuid}")
            if lockScoped, op.fields["x-stacknest-lock"] != "none", !["LibraryLocked", "ForbiddenOrLocked"].contains(forbidden) {
                problems.append("\(op.key): 403 に LibraryLocked か ForbiddenOrLocked が無い（施錠を見ないなら x-stacknest-lock: none）")
            }
            for name in op.responses.values where !name.isEmpty && !Self.responseNames.contains(name) {
                problems.append("\(op.key): 知らない共通の応答 \(name)")
            }
        }
        for name in Self.responseNames where !yaml.contains("\n    \(name):\n") {
            problems.append("components.responses に \(name) が無い")
        }
        #expect(problems.isEmpty, Comment(rawValue: "\n" + problems.joined(separator: "\n")))
    }
}
