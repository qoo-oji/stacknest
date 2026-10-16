// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
@testable import LibraryServer

/// G65（spec §6.2）: コードに登録した道と openapi.yaml の操作を両方向で突き合わせる。
@Suite("G65: openapi.yaml と登録した道の突き合わせ")
struct OpenAPIRouteParityTests {
    /// 読み方そのものの確かめ（path・操作・項目・応答の $ref を拾い、操作でない鍵を数えない）。
    @Test func readerParsesPathsOperationsAndResponses() throws {
        let yaml = """
        openapi: 3.1.0
        paths:
          /a/{lib}:
            parameters:
              - name: lib
                in: path
            get:
              operationId: getA
              summary: x
              description: |
                get: これは本文で、操作ではない
              tags: [A]
              x-stacknest-tier: read
              responses:
                '200':
                  description: ok
                '401':
                  $ref: '#/components/responses/Unauthorized'
            delete:
              x-stacknest-tier: edit
              responses:
                '403':
                  $ref: '#/components/responses/Forbidden'
          /local/b:
            servers:
              - url: /
            post:
              x-stacknest-lock: none
        tags:
          - name: A
        """
        let ops = try OpenAPISpecReader.operations(in: yaml)
        #expect(ops.map(\.key) == ["GET /a/{lib}", "DELETE /a/{lib}", "POST /local/b"])
        #expect(ops[0].fields["operationId"] == "getA")
        #expect(ops[0].fields["x-stacknest-tier"] == "read")
        #expect(ops[0].responses == ["200": "", "401": "Unauthorized"])
        #expect(ops[1].responses == ["403": "Forbidden"])
        #expect(ops[2].fields["x-stacknest-lock"] == "none")
    }

    @Test func readerRejectsAnUnknownKeyUnderAPath() {
        let yaml = """
        paths:
          /a:
            head:
              responses: {}
        """
        #expect(throws: OpenAPISpecReader.UnknownKey.self) { try OpenAPISpecReader.operations(in: yaml) }
    }

    /// 操作が 3 字下げ（2 の倍数でない）だと、黙って消えずに投げる。
    @Test func readerRejectsAnOddIndentInsidePaths() {
        let yaml = """
        paths:
          /a:
           get:
              responses: {}
        """
        #expect(throws: OpenAPISpecReader.UnexpectedIndent.self) { try OpenAPISpecReader.operations(in: yaml) }
    }

    /// 文書そのものの配信。API ではないので突き合わせから除く（コードに実在することは確かめる）。
    static let documentRoutes: Set<String> = [
        "GET /openapi.yaml", "GET /docs", "GET /redoc.standalone.js", "GET /",
    ]

    @Test func everyRouteIsDocumentedAndEveryDocumentedOperationExists() throws {
        let ops = try OpenAPISpecReader.operations(in: OpenAPISpecReader.specText())
        let documented = Set(ops.map(\.key))
        #expect(documented.count == ops.count, "openapi.yaml に同じ操作が 2 回ある")
        let code = try G65ServerFixture.codeRoutes()
        let staleExclusions = Self.documentRoutes.subtracting(code)
        #expect(staleExclusions.isEmpty, "除外表にあってコードに無い:\n\(staleExclusions.sorted().joined(separator: "\n"))")
        let api = code.subtracting(Self.documentRoutes)
        let missing = api.subtracting(documented)
        #expect(missing.isEmpty, "コードにあって openapi.yaml に無い:\n\(missing.sorted().joined(separator: "\n"))")
        let stale = documented.subtracting(api)
        #expect(stale.isEmpty, "openapi.yaml にあってコードに無い:\n\(stale.sorted().joined(separator: "\n"))")
    }
}
