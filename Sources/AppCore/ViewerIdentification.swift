// SPDX-License-Identifier: MIT
import Foundation

/// G60 v3: 対応ビューアが本の API の要求に付ける名乗り（spec §5.7）。
/// 形は `X-StackNest-Viewer: <bundle id>/<ビューアの版>; format=<参照ファイルの版>`。G63 の部品は `; kit=<部品の版>` を足す。
/// サーバは無くても拒まない（記録するだけ）。外から来る値なので、保存・表示の前に必ず `sanitize` を通す。
///
/// G60 §5.9 の作業で直した（G63 spec §6.1）: 文字種と長さを送る側（G61 のフォーク・G63 の部品）と同じ 1 つの定義にする。
public struct ViewerIdentification: Sendable, Equatable {
    public static let headerName = "X-StackNest-Viewer"
    /// 保存する最長の文字数。
    public static let maxLength = 200
    /// bundle id とビューアの版の最長の文字数（送る側と同じ）。bundle id はこれを超えたら名乗りとみなさない。版はこれで切る。
    public static let maxComponentLength = 64
    /// `kit=`（G63 の部品の版）の最長の文字数。これで切る。
    public static let maxKitVersionLength = 16

    public let bundleIdentifier: String
    public let version: String?
    public let format: Int?
    /// G63 の部品の版（`kit=`）。無ければ nil。bundle id・版・`format` の読み方には影響しない。
    public let kitVersion: String?

    public init(bundleIdentifier: String, version: String?, format: Int?, kitVersion: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.format = format
        self.kitVersion = kitVersion
    }

    /// 送る側が bundle id・版・部品の版に使う文字（ASCII の英数字と `.`・`_`・`+`・`-`＝`[A-Za-z0-9._+-]`）。
    public static func isComponentCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "+", "-":
            return true
        default:
            return false
        }
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

    /// 整えた上で読む。bundle id（`isComponentCharacter` の文字だけ・1〜64 文字）が取れなければ nil。
    /// 版は 64 文字で切る（文字種は見ない＝部品を使わないビューアの版もそのまま読む）。
    /// 引数は `;` で区切った `key=value`（キーは大文字・小文字を区別しない）。`format`（整数）と `kit`（部品の版・
    /// `isComponentCharacter` だけ・16 文字で切る）を読み、ほかの引数は読み飛ばす。`kit=` の有無で bundle id・版・`format` は変わらない。
    public static func parse(_ value: String?) -> ViewerIdentification? {
        guard let text = sanitize(value) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let product = parts[0].trimmingCharacters(in: .whitespaces)
        let slash = product.firstIndex(of: "/")
        let bundle = slash.map { String(product[..<$0]) } ?? product
        guard !bundle.isEmpty, bundle.unicodeScalars.count <= maxComponentLength,
              bundle.unicodeScalars.allSatisfy({ isComponentCharacter($0) }) else { return nil }
        var version = slash.map { String(product[product.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
        if version?.isEmpty == true { version = nil }
        version = version.map { String($0.prefix(maxComponentLength)) }
        var format: Int?
        var kitVersion: String?
        for parameter in parts.dropFirst() {
            let pair = parameter.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "=") else { continue }   // `=` の無い断片は読み飛ばす
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "format":
                format = Int(raw)
            case "kit":
                let cut = String(raw.prefix(maxKitVersionLength))
                kitVersion = !cut.isEmpty && cut.unicodeScalars.allSatisfy({ isComponentCharacter($0) }) ? cut : nil
            default:
                continue   // 知らない引数は読み飛ばす
            }
        }
        return ViewerIdentification(bundleIdentifier: bundle, version: version, format: format, kitVersion: kitVersion)
    }
}
