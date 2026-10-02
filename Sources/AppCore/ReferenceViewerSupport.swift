// SPDX-License-Identifier: MIT
import Foundation

/// G60 v2: 外部ビューアのアプリが、参照ファイル（`.stacknestbook`）を開けると**宣言しているか**。
/// StackNest は宣言したアプリにだけ参照ファイルを渡す（それ以外のアプリは従来どおりの開き方）。
///
/// `Contents/Info.plist` の `CFBundleDocumentTypes` に、次のどちらかを持つ項目があれば対応とみなす。
/// - `LSItemContentTypes` に `BookReference.typeIdentifier`（UTType は大文字小文字を区別しない）
/// - `CFBundleTypeExtensions` に `BookReference.fileExtension`（大文字小文字は区別しない）
///
/// plist は `PropertyListSerialization` で直接読む（`Bundle(url:)` はキャッシュするので使わない。
/// LaunchServices への登録にも頼らない）。plist が無い・読めない・形が違うときは「対応していない」。
public func appDeclaresBookReferenceSupport(appURL: URL) -> Bool {
    let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any],
          let documentTypes = plist["CFBundleDocumentTypes"] as? [Any]
    else { return false }

    let wantedType = BookReference.typeIdentifier.lowercased()
    let wantedExtension = BookReference.fileExtension.lowercased()
    for case let entry as [String: Any] in documentTypes {
        if let types = entry["LSItemContentTypes"] as? [Any],
           types.contains(where: { ($0 as? String)?.lowercased() == wantedType }) {
            return true
        }
        if let extensions = entry["CFBundleTypeExtensions"] as? [Any],
           extensions.contains(where: { ($0 as? String)?.lowercased() == wantedExtension }) {
            return true
        }
    }
    return false
}
