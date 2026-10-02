// SPDX-License-Identifier: MIT
import Foundation

/// G60 v3: 対応ビューアが本の API の要求に付ける名乗り（spec §5.7）。
/// 形は `X-StackNest-Viewer: <bundle id>/<ビューアの版>; format=<参照ファイルの版>`。
/// サーバは無くても拒まない（記録するだけ）。外から来る値なので、保存・表示の前に必ず `sanitize` を通す。
public struct ViewerIdentification: Sendable, Equatable {
    public static let headerName = "X-StackNest-Viewer"
    /// 保存する最長の文字数。
    public static let maxLength = 200
    /// 名乗りから読む版の最長の文字数（設定の行の見た目を保つ）。
    public static let maxVersionLength = 32

    public let bundleIdentifier: String
    public let version: String?
    public let format: Int?

    public init(bundleIdentifier: String, version: String?, format: Int?) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.format = format
    }

    /// 印字できる ASCII（0x20〜0x7E）だけを残し、前後の空白を落とし、`maxLength` 文字で切る。空なら nil。
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var kept = String.UnicodeScalarView()
        var count = 0
        for scalar in raw.unicodeScalars where scalar.value >= 0x20 && scalar.value <= 0x7E {
            kept.append(scalar)
            count += 1
            if count >= maxLength { break }
        }
        let text = String(kept).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// 整えた上で読む。bundle id（ASCII の英数字・`.`・`-`）が取れなければ nil。版と `format=` は無ければ nil。
    /// 版は `maxVersionLength` 文字で切る。
    public static func parse(_ value: String?) -> ViewerIdentification? {
        guard let text = sanitize(value) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let product = parts[0].trimmingCharacters(in: .whitespaces)
        let slash = product.firstIndex(of: "/")
        let bundle = slash.map { String(product[..<$0]) } ?? product
        guard !bundle.isEmpty, bundle.unicodeScalars.allSatisfy({
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "." || $0 == "-"
        }) else { return nil }
        var version = slash.map { String(product[product.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
        if version?.isEmpty == true { version = nil }
        version = version.map { String($0.prefix(maxVersionLength)) }
        var format: Int?
        for parameter in parts.dropFirst() {
            let pair = parameter.trimmingCharacters(in: .whitespaces)
            if pair.lowercased().hasPrefix("format=") {
                format = Int(pair.dropFirst("format=".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return ViewerIdentification(bundleIdentifier: bundle, version: version, format: format)
    }
}
