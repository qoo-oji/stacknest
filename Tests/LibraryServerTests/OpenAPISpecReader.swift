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
    /// `security:` の下の行（字下げを除いた形。例: `- bearerAuth: []`・`libraryToken: []`）。
    var securityLines: [String] = []
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

    /// 字下げ 2・4 以外の浅い字下げ（1・3・5）。操作が 3 字下げになっているなど、黙って読み飛ばすと操作が消える。
    struct UnexpectedIndent: Error, CustomStringConvertible {
        let line: Int
        let indent: Int
        let text: String
        var description: String { "openapi.yaml l.\(line): paths の字下げ \(indent) は読めない（2 の倍数で書く）: \(text)" }
    }

    /// 同じ path のキーが 2 回ある。YAML としては通るが、後のものが前のものを黙って消す。
    struct DuplicatePath: Error, CustomStringConvertible {
        let line: Int
        let path: String
        var description: String { "openapi.yaml l.\(line): path \(path) が 2 回ある（既にある path には、そのブロックの下に method を足す）" }
    }

    /// 操作の中（字下げ 6）に method の名前の鍵がある。操作の入れ子の誤り。
    struct MisplacedMethod: Error, CustomStringConvertible {
        let line: Int
        let text: String
        var description: String { "openapi.yaml l.\(line): method が path の直下（字下げ 4）でなく 6 にある: \(text)" }
    }

    /// 応答の `$ref` が `#/components/responses/` で始まらない。
    struct BadResponseRef: Error, CustomStringConvertible {
        let line: Int
        let ref: String
        var description: String { "openapi.yaml l.\(line): 応答の $ref は #/components/responses/ で始める: \(ref)" }
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
        var inSecurity = false
        var seenPaths: Set<String> = []
        func flush() {
            if let c = current { ops.append(c) }
            current = nil; inResponses = false; status = nil; inSecurity = false
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
                if !seenPaths.insert(key).inserted { throw DuplicatePath(line: index + 1, path: key) }
            case 4:
                flush()
                if methods.contains(key), let path {
                    current = OpenAPIOperation(method: key.uppercased(), path: path)
                } else if !pathItemKeys.contains(key) {
                    throw UnknownKey(line: index + 1, text: trimmed)
                }
            case 6:
                // path 直下の parameters の項目（`- name:`）は 6 に来るので、操作が無くても投げない。method の鍵だけ弾く。
                if methods.contains(key) { throw MisplacedMethod(line: index + 1, text: trimmed) }
                guard current != nil else { continue }
                current?.fields[key] = value
                inResponses = (key == "responses"); status = nil; inSecurity = (key == "security")
            case 8 where inResponses:
                let code = unquote(key)
                status = code
                current?.responses[code] = ""
            case 10 where inResponses && key == "$ref":
                let ref = unquote(value)
                if !ref.hasPrefix("#/components/responses/") { throw BadResponseRef(line: index + 1, ref: ref) }
                if let status { current?.responses[status] = ref.components(separatedBy: "/").last ?? "" }
            default:
                // 6 以上の深い行（本文・パラメータ・スキーマの中）は読み飛ばしてよい。
                // 浅い奇数の字下げ（1・3・5）は、操作や path が黙って消えるので投げる。
                if indent < 6 { throw UnexpectedIndent(line: index + 1, indent: indent, text: trimmed) }
                if inSecurity, !inResponses { current?.securityLines.append(trimmed) }
                continue
            }
        }
        flush()
        return ops
    }

    /// ファイル中のすべての `$ref: '#/components/<節>/<名前>'` のうち、その節に定義が無いもの。
    /// 定義は `components:` の下の節（字下げ 2）の直下の名前（字下げ 4）。
    /// あわせて、2 回ある最上位の鍵（`components:`・`paths:`・`tags:` など）と、2 回ある `components` の名前も返す（先頭に並べる）。
    /// どちらも YAML としては通るが、後のものだけが配信され前のものが黙って消える。
    static func unresolvedRefs(in yaml: String) -> [String] {
        var defined: [String: Set<String>] = [:]
        var refs: [(line: Int, section: String, name: String)] = []
        var inComponents = false
        var section: String?
        var duplicates: [String] = []
        var topLevelKeys: Set<String> = []
        for (index, raw) in yaml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inComponents = (trimmed == "components:"); section = nil
                // 字下げ 0 の列の項目（`- …`）は鍵ではないので数えない。
                if !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colon])
                    if !topLevelKeys.insert(key).inserted {
                        duplicates.append("l.\(index + 1): 最上位の \(key) が 2 回ある（後のものだけが配信され、前のブロックは丸ごと消える。既にあるブロックの中に足す）")
                    }
                }
            }
            if inComponents {
                if indent == 2 { section = String(trimmed.dropLast(trimmed.hasSuffix(":") ? 1 : 0)) }
                else if indent == 4, let section, trimmed.hasSuffix(":") {
                    let name = String(trimmed.dropLast())
                    if !defined[section, default: []].insert(name).inserted {
                        duplicates.append("l.\(index + 1): components.\(section) の \(name) が 2 回ある（後のものだけが配信される）")
                    }
                }
            }
            if let r = trimmed.range(of: "$ref:") {
                let value = trimmed[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                guard value.hasPrefix("#/components/") else { continue }
                let parts = value.dropFirst("#/components/".count).split(separator: "/")
                if parts.count == 2 { refs.append((index + 1, String(parts[0]), String(parts[1]))) }
                else { refs.append((index + 1, "?", value)) }
            }
        }
        return duplicates + refs.filter { defined[$0.section]?.contains($0.name) != true }
            .map { "l.\($0.line): $ref の先が無い: \($0.section)/\($0.name)" }
    }

    /// 最上位 `tags:` に宣言した名前。
    static func declaredTags(in yaml: String) -> Set<String> {
        var inTags = false
        var names: Set<String> = []
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("tags:") { inTags = true; continue }
            if inTags, !line.hasPrefix(" "), !line.isEmpty { inTags = false }
            if inTags, line.hasPrefix("  - name:") {
                names.insert(line.dropFirst("  - name:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return names
    }
}
