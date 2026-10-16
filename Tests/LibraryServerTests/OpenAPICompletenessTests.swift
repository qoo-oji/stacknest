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
        let problems = try Self.problems(in: OpenAPISpecReader.specText())
        #expect(problems.isEmpty, Comment(rawValue: "\n" + problems.joined(separator: "\n")))
    }

    /// 欠けの一覧（空なら良い）。試験から悪い YAML も渡せるよう、文字列を取る。
    static func problems(in yaml: String) throws -> [String] {
        let declaredTags = OpenAPISpecReader.declaredTags(in: yaml)
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
            if let tags = op.fields["tags"] {
                if !(tags.hasPrefix("[") && tags.hasSuffix("]")) { problems.append("\(op.key): tags は [X] の形で書く: \(tags)") }
                let names = tags.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for name in names where !declaredTags.contains(name) { problems.append("\(op.key): 宣言していないタグ \(name)") }
            }
            if ["{lib}", "{id}", "{uuid}", "{tokenID}"].contains(where: op.path.contains), op.responses["404"] != "NotFound" {
                problems.append("\(op.key): 404 に NotFound が無い")
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
            let lockChecked = (op.path.hasPrefix("/libraries/{lib}") || op.path.hasPrefix("/local/libraries/{uuid}"))
                && op.fields["x-stacknest-lock"] != "none"
            let twoAlternatives = ["- bearerAuth: []", "libraryToken: []", "- bearerAuth: []"]
            if lockChecked, op.securityLines != twoAlternatives {
                problems.append("\(op.key): 施錠を見る操作は security に bearerAuth+libraryToken と bearerAuth の 2 通りを並べる")
            }
            if !lockChecked, tier != "none", !op.securityLines.isEmpty {
                problems.append("\(op.key): 施錠を見ない操作は security を書かない（既定の bearerAuth）")
            }
            for name in op.responses.values where !name.isEmpty && !Self.responseNames.contains(name) {
                problems.append("\(op.key): 知らない共通の応答 \(name)")
            }
        }
        for name in Self.responseNames where !yaml.contains("\n    \(name):\n") {
            problems.append("components.responses に \(name) が無い")
        }
        problems += OpenAPISpecReader.unresolvedRefs(in: yaml)
        return problems
    }

    private static let badBase = """
    components:
      responses:
        Unauthorized:
          description: x
      schemas:
        A:
          type: object
    tags:
      - name: T
    """

    @Test func missing404IsReported() throws {
        let yaml = """
        paths:
          /libraries/{lib}/x:
            get:
              summary: s
              tags: [T]
              operationId: x
              x-stacknest-tier: read
              responses:
                '401':
                  $ref: '#/components/responses/Unauthorized'
        """ + "\n" + Self.badBase
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("404 に NotFound が無い") })
    }

    @Test func undeclaredTagAndDanglingRefsAreReported() throws {
        let yaml = """
        paths:
          /a:
            get:
              summary: s
              tags: [Nope]
              operationId: x
              x-stacknest-tier: read
              responses:
                '200':
                  content:
                    application/json:
                      schema:
                        $ref: '#/components/schemas/Missing'
                '401':
                  $ref: '#/components/responses/Unauthorized'
        """ + "\n" + Self.badBase
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("宣言していないタグ Nope") })
        #expect(problems.contains { $0.contains("schemas/Missing") })
    }

    @Test func duplicateComponentNameIsReported() {
        let yaml = """
        components:
          schemas:
            A:
              type: object
            A:
              type: string
        """
        #expect(OpenAPISpecReader.unresolvedRefs(in: yaml).contains { $0.contains("A が 2 回ある") })
    }

    @Test func securityAndTagShapesAreChecked() throws {
        let yaml = """
        paths:
          /libraries/{lib}/x:
            get:
              summary: s
              tags:
                - T
              operationId: x
              x-stacknest-tier: read
              responses:
                '401':
                  $ref: '#/components/responses/Unauthorized'
                '403':
                  $ref: '#/components/responses/LibraryLocked'
                '404':
                  $ref: '#/components/responses/NotFound'
        """ + "\n" + Self.badBase
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("tags は [X] の形で書く") })
        #expect(problems.contains { $0.contains("2 通りを並べる") })
    }

    @Test func responseRefIntoAnotherSectionThrows() {
        let yaml = """
        paths:
          /a:
            get:
              responses:
                '401':
                  $ref: '#/components/schemas/Unauthorized'
        """
        #expect(throws: OpenAPISpecReader.BadResponseRef.self) { try OpenAPISpecReader.operations(in: yaml) }
    }

    @Test func repeatedPathAndMisplacedMethodThrow() {
        let dup = """
        paths:
          /a:
            get:
              responses: {}
          /b:
            get:
              responses: {}
          /a:
            post:
              responses: {}
        """
        #expect(throws: OpenAPISpecReader.DuplicatePath.self) { try OpenAPISpecReader.operations(in: dup) }
        let misplaced = """
        paths:
          /a:
            get:
              responses: {}
              post:
                responses: {}
        """
        #expect(throws: OpenAPISpecReader.MisplacedMethod.self) { try OpenAPISpecReader.operations(in: misplaced) }
        let direct = """
        paths:
          /a:
              get:
                responses: {}
        """
        #expect(throws: OpenAPISpecReader.MisplacedMethod.self) { try OpenAPISpecReader.operations(in: direct) }
    }
}
