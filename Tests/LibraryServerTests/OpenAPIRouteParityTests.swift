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

    /// まだ openapi.yaml に書いていない操作（G65 Task 3〜5 が書いて削る。Task 5 で空にして消す）。
    static let undocumented: Set<String> = [
        // Task 4
        "POST /libraries/{lib}/integrity/full-scan", "POST /libraries/{lib}/duplicates/scan",
        "GET /libraries/{lib}/integrity/summary", "GET /libraries/{lib}/integrity/list", "POST /libraries/{lib}/integrity/scan",
        "GET /libraries/{lib}/integrity-check", "POST /libraries/{lib}/backup-now",
        "POST /libraries/{lib}/maintenance/complete-metadata", "POST /libraries/{lib}/maintenance/compress-covers",
        "POST /libraries/{lib}/maintenance/cancel", "GET /libraries/{lib}/maintenance/status",
        "GET /libraries/{lib}/watch-config", "PUT /libraries/{lib}/watch-config",
        "POST /libraries/{lib}/watch/scan-now", "POST /libraries/{lib}/watch/import-existing",
        "GET /libraries/{lib}/import-config", "PUT /libraries/{lib}/import-config",
        "GET /libraries/{lib}/general-settings", "PUT /libraries/{lib}/general-settings",
        "GET /import-config", "PUT /import-config",
        "GET /libraries/{lib}/presets", "PUT /libraries/{lib}/presets",
        "POST /libraries/{lib}/books/{id}/relink", "POST /libraries/{lib}/books/restore",
        "POST /libraries/{lib}/books/{id}/cover/regenerate", "PUT /libraries/{lib}/books/{id}/cover-image",
        // Task 5
        "POST /local/libraries/open", "POST /local/libraries/close",
        "GET /local/libraries/{uuid}/finder-tags", "PUT /local/libraries/{uuid}/finder-tags",
        "POST /local/libraries/{uuid}/finder-tags/resync", "POST /local/libraries/{uuid}/rename-files",
    ]

    @Test func undocumentedListShrinksAsOperationsAreWritten() {
        // 書いた操作を消すたびにこの数も直す（Task 1 で 50・Task 3 で 33。Task 5 でこの試験ごと消す）。
        #expect(Self.undocumented.count == 33)
    }

    @Test func everyRouteIsDocumentedAndEveryDocumentedOperationExists() throws {
        let ops = try OpenAPISpecReader.operations(in: OpenAPISpecReader.specText())
        let documented = Set(ops.map(\.key))
        #expect(documented.count == ops.count, "openapi.yaml に同じ操作が 2 回ある")
        let code = try G65ServerFixture.codeRoutes()
        let staleExclusions = Self.documentRoutes.subtracting(code)
        #expect(staleExclusions.isEmpty, "除外表にあってコードに無い:\n\(staleExclusions.sorted().joined(separator: "\n"))")
        let api = code.subtracting(Self.documentRoutes)
        let missing = api.subtracting(documented).subtracting(Self.undocumented)
        #expect(missing.isEmpty, "コードにあって openapi.yaml に無い:\n\(missing.sorted().joined(separator: "\n"))")
        let stale = documented.subtracting(api)
        #expect(stale.isEmpty, "openapi.yaml にあってコードに無い:\n\(stale.sorted().joined(separator: "\n"))")
        let nowDocumented = Self.undocumented.intersection(documented)
        #expect(nowDocumented.isEmpty, "書いたので undocumented から消す:\n\(nowDocumented.sorted().joined(separator: "\n"))")
        let notInCode = Self.undocumented.subtracting(api)
        #expect(notInCode.isEmpty, "undocumented にあってコードに無い（綴りの誤り）:\n\(notInCode.sorted().joined(separator: "\n"))")
    }
}
