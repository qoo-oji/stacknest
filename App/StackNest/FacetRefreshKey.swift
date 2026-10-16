// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore

/// G62: ブラウザ区画（ファセット 3 列）の `refreshKey` を組む。
/// この文字列は 3 列の `.task(id:)` の id になる。中身が同じなのに文字列が変わると、3 列とも問い合わせをやり直す。
/// ローカル（`LibraryBrowserView`）は `local(_:settings:)`、リモート（`RemoteLibraryState.facetRefreshKey`）は
/// `filterPart(_:)` を使う。
enum FacetRefreshKey {
    /// フィルタの部分。中身が同じなら必ず同じ文字列にする。
    /// - `.sortedKeys` が要る。無いと `JSONEncoder` はキーを新しいハッシュ表の順に書き、Swift は表ごとに格納先の
    ///   番地から種を取るので、変えていない `FilterState` でも呼ぶたびに別の文字列になる（M0 では何も変えずに 803 通り）。
    /// - `Set` の要素も並べ替える。同じ中身でも値を作り直すと別の順に並ぶ（作り直した 300 個が `.sortedKeys` だけでは
    ///   299 通り）。`FilterState` の配列はすべて `Set<String>`／`Set<Int>` で、順に意味は無い。
    /// - 条件を手で並べずに JSON を経るのは、`FilterState` に条件が増えても鍵に自動で入るようにするため。
    static func filterPart(_ filter: FilterState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(filter),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        for (key, value) in object {
            if let strings = value as? [String] {
                object[key] = strings.sorted()
            } else if let numbers = value as? [Int] {
                object[key] = numbers.sorted()
            }
        }
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "" }
        return String(decoding: canonical, as: UTF8.self)
    }

    /// ローカルの書庫の鍵（区画の列・選択・検索・フィルタ・サイドバー・本の一覧の版）。
    @MainActor
    static func local(_ appState: AppState, settings: LibrarySettings) -> String {
        let s = settings.browserPaneState
        return "\(s.fields.map { $0?.sqlColumn ?? "" }.joined(separator: ","))|\(s.selections.map { $0 ?? "" }.joined(separator: ","))|\(appState.searchQuery)|\(filterPart(settings.filterState))|\(String(describing: appState.selectedSidebarItem))|\(appState.booksDataVersion)"
    }
}
