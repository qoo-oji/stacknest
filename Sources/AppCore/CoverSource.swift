// SPDX-License-Identifier: MIT
import Foundation

/// 表紙ソースの識別。coverImageName の意味: nil=自動(先頭ページ) / "<entry>"=アーカイブ内ページ /
/// "@external"=外部画像 / "@t=<秒>"=動画で手動選択した場面（G50）。
/// 外部表紙は Thumbnails/<bookID>/thumbnail.jpg が外部画像そのもの（アーカイブ再抽出で上書きしない）。
public enum CoverSource {
    public static let externalSentinel = "@external"
    public static func isExternal(_ coverImageName: String?) -> Bool { coverImageName == externalSentinel }

    /// G50: 動画で手動選択した場面の時刻。`"@t=12.500"`（秒・小数 3 桁・ロケール非依存）。
    /// `@external` と違い、この本は「表紙を再生成」で**同じ場面**を作り直せる。
    public static let videoTimePrefix = "@t="

    public static func videoTimeSentinel(forSeconds seconds: Double) -> String {
        videoTimePrefix + String(format: "%.3f", locale: nil, max(0, seconds))
    }

    public static func videoTime(from coverImageName: String?) -> Double? {
        guard let name = coverImageName, name.hasPrefix(videoTimePrefix) else { return nil }
        let raw = String(name.dropFirst(videoTimePrefix.count))
        guard !raw.isEmpty, let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }
}
