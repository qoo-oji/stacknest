// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

/// G65（spec §6.3 前半）: openapi.yaml の各操作が必要な項目を持つこと。
@Suite("G65: openapi.yaml の各操作の欠け")
struct OpenAPICompletenessTests {
    static let tiers: Set<String> = ["none", "read", "edit", "admin", "relay"]
    static let responseNames: Set<String> = ["Unauthorized", "Forbidden", "LibraryLocked", "ForbiddenOrLocked", "NotFound", "LibraryUnavailable"]

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
            // G62（spec §6.9・Q6）: 施錠を見る操作は、施錠の状態を読めないとき 503 を返す。
            if lockChecked, op.responses["503"] != "LibraryUnavailable" {
                problems.append("\(op.key): 施錠を見る操作は 503 に LibraryUnavailable を書く")
            }
            // `security:` の下の行（block の形）だけでなく、1 行の flow の形（`security: [{bearerAuth: []}]`）も見る。
            if !lockChecked, tier != "none", op.fields["security"] != nil {
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
        problems += OpenAPISpecReader.nullHandlingProblems(in: yaml)
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

    /// G62: 施錠を見る操作に 503 が無ければ報告する。
    @Test func lockCheckedOperationWithout503IsReported() throws {
        let yaml = """
        paths:
          /libraries/{lib}/x:
            get:
              summary: s
              tags: [T]
              operationId: x
              x-stacknest-tier: read
              security:
                - bearerAuth: []
                  libraryToken: []
                - bearerAuth: []
              responses:
                '401':
                  $ref: '#/components/responses/Unauthorized'
                '403':
                  $ref: '#/components/responses/LibraryLocked'
                '404':
                  $ref: '#/components/responses/NotFound'
        """ + "\n" + Self.badBase
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("503 に LibraryUnavailable") }, Comment(rawValue: problems.joined(separator: "\n")))
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

    /// 最上位の鍵が 2 回あると、YAML としては通るが後のブロックだけが配信され、前のブロックは丸ごと消える。
    /// ファイル末尾にブロックを足す書き方で起きやすいので、3 つの鍵それぞれで確かめる。
    @Test(arguments: [
        "components:\n  schemas:\n    NewThing:\n      type: object",
        "paths:\n  /new:\n    get:\n      summary: s",
        "tags:\n  - name: New",
    ])
    func topLevelKeyTwiceIsReported(appended: String) throws {
        let yaml = """
        openapi: 3.1.0
        paths:
          /a:
            get:
              summary: s
        """ + "\n" + Self.badBase + "\n" + appended
        let key = String(appended.prefix(while: { $0 != ":" }))
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("最上位の \(key) が 2 回ある") }, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// 鍵とコロンの間に空白があっても（`tags :`）、YAML では同じ `tags` の鍵なので、2 回目として報告する。
    @Test func topLevelKeyWithSpaceBeforeColonIsReported() throws {
        let yaml = """
        openapi: 3.1.0
        paths:
          /a:
            get:
              summary: s
        """ + "\n" + Self.badBase + "\n" + "tags :\n  - name: New"
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("最上位の tags が 2 回ある") }, Comment(rawValue: problems.joined(separator: "\n")))
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
          /free-block:
            get:
              summary: s
              tags: [T]
              operationId: freeBlock
              x-stacknest-tier: read
              security:
                - bearerAuth: []
              responses:
                '401':
                  $ref: '#/components/responses/Unauthorized'
          /free-flow:
            get:
              summary: s
              tags: [T]
              operationId: freeFlow
              x-stacknest-tier: read
              security: [{bearerAuth: []}]
              responses:
                '401':
                  $ref: '#/components/responses/Unauthorized'
          /none:
            get:
              summary: s
              tags: [T]
              operationId: noAuth
              x-stacknest-tier: none
              security: []
              responses:
                '200':
                  description: ok
        """ + "\n" + Self.badBase
        let problems = try Self.problems(in: yaml)
        #expect(problems.contains { $0.contains("tags は [X] の形で書く") })
        #expect(problems.contains { $0.contains("2 通りを並べる") })
        // 施錠を見ない操作の security は、block の形でも flow の形でも報告する。認証なしの `security: []` は通す。
        #expect(problems.contains { $0.contains("GET /free-block: 施錠を見ない操作は security を書かない") })
        #expect(problems.contains { $0.contains("GET /free-flow: 施錠を見ない操作は security を書かない") })
        #expect(!problems.contains { $0.hasPrefix("GET /none:") }, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// OpenAPI 3.1 では `nullable:` は効かない（3.0 の書き方）。block の形でも flow の形でも報告する。
    /// type の並びの裸の `null`（引用符なし）は YAML の null になり型の名前にならないので、これも報告する。
    /// 引用符付きの `'null'`・oneOf の `- type: 'null'`・enum の値としての null は通す。
    @Test func nullableAndBareNullTypeAreReported() throws {
        let yaml = """
        paths:
          /a:
            get:
              summary: s
              tags: [T]
              operationId: x
              x-stacknest-tier: read
              responses:
                '200':
                  description: ok
                  content:
                    application/json:
                      schema:
                        type: object
                        properties:
                          blockNullable:
                            type: string
                            nullable: true
                          flowNullable: { type: integer, nullable: true }
                          bareNullInUnion:
                            type: [string, null]
                          bareNullScalar: { type: null }
                          bareTilde: { type: [integer, ~] }
                          quotedUnion:
                            type: [string, 'null']
                            enum: [x, null]
                          refOrNull:
                            oneOf:
                              - $ref: '#/components/schemas/A'
                              - type: 'null'
                '401':
                  $ref: '#/components/responses/Unauthorized'
        """ + "\n" + Self.badBase
        let problems = try Self.problems(in: yaml)
        let all = Comment(rawValue: problems.joined(separator: "\n"))
        // 1 つの行に 1 つずつ。数で比べ、通すべき行（quotedUnion・refOrNull）が報告されていないことも確かめる。
        #expect(problems.filter { $0.contains("nullable は OpenAPI 3.1 では効かない") }.count == 2, all)
        #expect(problems.filter { $0.contains("type の null は 'null' と引用符で囲む") }.count == 3, all)
        // badBase に無い共通の応答の報告を除けば、この 5 つだけ。
        #expect(problems.filter { !$0.hasPrefix("components.responses に") }.count == 5, all)
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
