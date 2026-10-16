// SPDX-License-Identifier: MIT
import Foundation

/// openapi.yaml の操作 1 つ（G65）。
struct OpenAPIOperation: Equatable {
    /// "GET" など大文字。
    let method: String
    /// "/libraries/{lib}/books"・"/local/libraries/open" など（全体の server `/api/v1` を除いた形）。
    let path: String
    /// 字下げ 6 の `key: value`（値が無い行は ""）。
    var fields: [String: String] = [:]
    /// 応答の状態コード → `$ref` の `components.responses` の名前（`$ref` でなければ ""）。
    var responses: [String: String] = [:]
    var key: String { "\(method) \(path)" }
}

/// G65（spec §6）: openapi.yaml の `paths:` を字下げで読む（YAML のパーサは依存に無い）。
/// 字下げ 2 が path、4 が操作か操作でない鍵、6 が操作の項目、8 が応答の状態コード、10 がその `$ref`。
/// `paths:` の区画は次の字下げ 0 の行で終わる。字下げ 4 に知らない鍵があれば投げる。
enum OpenAPISpecReader {
    static let methods: Set<String> = ["get", "post", "put", "patch", "delete"]
    static let pathItemKeys: Set<String> = ["summary", "description", "servers", "parameters"]

    struct UnknownKey: Error, CustomStringConvertible {
        let line: Int
        let text: String
        var description: String { "openapi.yaml l.\(line): paths の字下げ 4 に知らない鍵: \(text)" }
    }

    static func specText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LibraryServerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
            .appendingPathComponent("Sources/LibraryServer/Resources/openapi/openapi.yaml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func operations(in yaml: String) throws -> [OpenAPIOperation] {
        var ops: [OpenAPIOperation] = []
        var inPaths = false
        var path: String?
        var current: OpenAPIOperation?
        var inResponses = false
        var status: String?
        func flush() {
            if let c = current { ops.append(c) }
            current = nil; inResponses = false; status = nil
        }
        func unquote(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        for (index, raw) in yaml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                if inPaths { flush(); break }
                inPaths = (trimmed == "paths:")
                continue
            }
            guard inPaths else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch indent {
            case 2:
                flush(); path = key
            case 4:
                flush()
                if methods.contains(key), let path {
                    current = OpenAPIOperation(method: key.uppercased(), path: path)
                } else if !pathItemKeys.contains(key) {
                    throw UnknownKey(line: index + 1, text: trimmed)
                }
            case 6:
                guard current != nil else { continue }
                current?.fields[key] = value
                inResponses = (key == "responses"); status = nil
            case 8 where inResponses:
                let code = unquote(key)
                status = code
                current?.responses[code] = ""
            case 10 where inResponses && key == "$ref":
                if let status { current?.responses[status] = unquote(value).components(separatedBy: "/").last ?? "" }
            default:
                continue
            }
        }
        flush()
        return ops
    }
}
