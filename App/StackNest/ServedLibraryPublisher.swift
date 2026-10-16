// SPDX-License-Identifier: MIT
import Foundation
import LibraryServer

/// G62（spec §6.1）: 開いている書庫から、配信中の書庫の一覧（スナップショット）を作り直す。
/// 開く・閉じる・名前・共有・施錠が変わったときに、変化と同じ MainActor の turn の中で同期的に呼ぶ。
/// サーバのリクエストは `directory` を読むだけで MainActor を待たない（施錠の判定は DB を読む・§6.2）。
enum ServedLibraryPublisher {
    /// プロセスで 1 つ。ローカルコントロール（`AllOpenLibrariesDataSource`）と共有サーバ（`AppStateLibraryDataSource`）が同じものを読む。
    static let directory = ServedLibraryDirectory()

    /// テスト用: 差し替えた直後に、載せた書庫を渡す（本番は nil）。
    @MainActor static var didReplace: (@MainActor ([ServedLibrary]) -> Void)?

    /// `AppState.activeInstances` から一覧を組み直して丸ごと差し替える。閉じ始めた書庫（`isClosing`）は入れない。
    @MainActor
    static func republish() {
        let entries: [ServedLibraryDirectory.Entry] = AppState.activeInstances.allObjects.compactMap { state in
            guard !state.isClosing, let db = state.database, let settings = state.librarySettings else { return nil }
            // 無ければここで作って DB に書く（spec §6.1: UUID の生成は「最初のリクエスト」から「開いたとき」に移る）。
            let uuid = settings.ensureLibraryUUID()
            let library = ServedLibrary(
                uuid: uuid,
                name: settings.resolvedName(fallback: state.bundleURL.deletingPathExtension().lastPathComponent),
                bundleURL: state.bundleURL,
                db: db,
                isLocked: settings.lockPasswordHash != nil)
            return ServedLibraryDirectory.Entry(library: library, sharedRemotely: settings.remoteSharingEnabled)
        }
        directory.replace(entries)
        didReplace?(entries.map(\.library))
    }
}
