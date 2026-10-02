// SPDX-License-Identifier: MIT
import Foundation

/// G60 v3: 実際に参照ファイルの本を読んだことを確認できた対応ビューア（spec §5.7）。
public struct ConfirmedViewer: Codable, Sendable, Equatable {
    /// 渡した先のアプリの `CFBundleIdentifier`（無ければ名乗りの bundle id）。
    public let bundleIdentifier: String
    /// 名乗り（`X-StackNest-Viewer`）のビューアの版。名乗りが無ければ nil。
    public let viewerVersion: String?
    /// 名乗りの `format=`。無ければ nil。
    public let formatVersion: Int?
    /// 初めて読まれた日時（トークンの `firstUsedAt`）。
    public let confirmedAt: Date

    public init(bundleIdentifier: String, viewerVersion: String?, formatVersion: Int?, confirmedAt: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.viewerVersion = viewerVersion
        self.formatVersion = formatVersion
        self.confirmedAt = confirmedAt
    }
}

/// G60 v3: 確認できた対応ビューアの記録。UserDefaults のキー `externalViewerConfirmedViewers` に、
/// bundle id（小文字）ごとに最新の 1 件を JSON で置く。読み書きは毎回 defaults を通す（インスタンスを跨いでも同じ値）。
/// `@unchecked Sendable`: 読んで書き戻す間を `NSLock` で直列化している。`UserDefaults` はスレッドセーフ。
public final class ConfirmedViewerStore: @unchecked Sendable {
    public static let defaultsKey = "externalViewerConfirmedViewers"
    public static let shared = ConfirmedViewerStore()

    private let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 記録する。鍵は渡した先のアプリの bundle id、無ければ名乗りの bundle id（どちらも無ければ記録しない）。
    /// 版は名乗りから取る。既にある記録より古い日時なら上書きしない。記録の後に残っている 1 件を返す。
    /// 記録を変えたときだけ `.confirmedViewersDidChange` を投げる（設定の状態の行が開いたまま更新される）。
    /// App は確認の Task（MainActor）から呼ぶので、知らせもメインスレッドで届く。
    @discardableResult
    public func record(appBundleIdentifier: String?, viewer: String?, at date: Date) -> ConfirmedViewer? {
        let identification = ViewerIdentification.parse(viewer)
        guard let bundleID = appBundleIdentifier ?? identification?.bundleIdentifier else { return nil }
        let entry = ConfirmedViewer(bundleIdentifier: bundleID, viewerVersion: identification?.version,
                                    formatVersion: identification?.format, confirmedAt: date)
        let (kept, changed): (ConfirmedViewer, Bool) = lock.withLock {
            var all = loadLocked()
            let key = bundleID.lowercased()
            if let existing = all[key], existing.confirmedAt > date { return (existing, false) }
            all[key] = entry
            if let data = try? JSONEncoder().encode(all) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
            return (entry, true)
        }
        if changed {
            NotificationCenter.default.post(name: .confirmedViewersDidChange, object: self)
        }
        return kept
    }

    public func confirmed(bundleIdentifier: String) -> ConfirmedViewer? {
        lock.withLock { loadLocked()[bundleIdentifier.lowercased()] }
    }

    /// `lock` を握った状態で呼ぶこと。
    private func loadLocked() -> [String: ConfirmedViewer] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ConfirmedViewer].self, from: data) else { return [:] }
        return decoded
    }
}

public extension Notification.Name {
    /// G60 v3: 確認できた対応ビューアの記録が変わった（`ConfirmedViewerStore.record`）。設定の状態の行が計算し直す。
    static let confirmedViewersDidChange = Notification.Name("app.shelfsmith.stacknest.confirmedViewersDidChange")
}

/// G60 v3: 設定の「外部ビューア」の節に出す、画像の本の外部ビューアの対応の状態（spec §5.7）。
public enum ExternalViewerSupportStatus: Sendable, Equatable {
    /// 外部ビューアが未設定・見つからない。行を出さない。
    case none
    /// `StackNestViewerSupport` が無い・共通の版が無い・Info.plist を読めない。参照ファイルを渡さない。
    case unsupported(appName: String)
    /// 対応を宣言しているが、まだ読まれたことを確認していない。
    case declared(appName: String)
    /// 対応を宣言し、実際に読まれたことを確認した。
    case confirmed(appName: String, at: Date, viewerVersion: String?)

    /// 判定は宣言が先（記録があっても、今の宣言が無ければ未対応）。
    public static func make(appPath: String?, confirmed store: ConfirmedViewerStore) -> ExternalViewerSupportStatus {
        guard let appPath, !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) else { return .none }
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        guard let declaration = ViewerSupportDeclaration.read(appURL: appURL) else {
            return .unsupported(appName: appURL.deletingPathExtension().lastPathComponent)
        }
        guard declaration.chosenFormatVersion != nil else { return .unsupported(appName: declaration.displayName) }
        // `CFBundleIdentifier` の無いアプリは「対応を確認」にならない（`record` は名乗りの bundle id に倒すが、
        // ここはアプリの宣言でしか引かない）。実在のアプリには必ずあるので扱わない。
        if let bundleID = declaration.bundleIdentifier, let seen = store.confirmed(bundleIdentifier: bundleID) {
            return .confirmed(appName: declaration.displayName, at: seen.confirmedAt, viewerVersion: seen.viewerVersion)
        }
        return .declared(appName: declaration.displayName)
    }
}
