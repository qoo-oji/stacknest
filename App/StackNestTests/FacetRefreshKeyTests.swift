// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import RemoteClient
import StackroomFormat
@testable import StackNest

/// G62: ブラウザ区画の `refreshKey`（3 列の `.task(id:)` の id）は、中身が同じなら同じ文字列になる。
///
/// `JSONEncoder` は `.sortedKeys` が無いとキーを新しいハッシュ表の順に書き、Swift は表ごとに格納先の番地から
/// 種を取る。そのため変えていない `FilterState` でも呼ぶたびに別の文字列になり、本体の評価のたびに 3 列が
/// 問い合わせをやり直していた（M0 で 803 通りの鍵）。`Set` の要素の順も同じ理由で値を作り直すたびに変わる。
///
/// ループが小さいと、解放したばかりの同じ番地が返ってきて順が揃ってしまう。忙しいアプリのヒープを真似て、
/// 同じ大きさの 8 キーの辞書を生かしたまま鍵を組む（調査 `facet-key-probe.md` の T2）。
@Suite("G62: ブラウザ区画の鍵は中身が同じなら変わらない")
@MainActor
struct FacetRefreshKeyTests {
    /// 鍵を `count` 回組み、そのたびに 8 キーの辞書を 1 つ生かしておく。組めた鍵の種類を返す。
    private func distinctKeys(_ count: Int, _ build: () -> String) -> Set<String> {
        var retained: [[String: [Int]]] = []
        var keys = Set<String>()
        for i in 0..<count {
            var d: [String: [Int]] = [:]
            for k in 0..<8 { d["k\(k)_\(i)"] = [] }
            retained.append(d)
            keys.insert(build())
        }
        #expect(retained.count == count)
        return keys
    }

    /// 値の入った `Set` を 2 つ以上と、`Set` 以外の条件も持つフィルタ。
    /// `order` を変えると、同じ中身の `Set` を別の順に入れて作り直す。
    private func nonEmptyFilter(order: Int = 0) -> FilterState {
        func arranged<T>(_ values: [T]) -> [T] {
            let r = order % values.count
            return Array((values[r...] + values[..<r]).reversed())
        }
        var f = FilterState()
        f.genres = Set(arranged(["g0", "g1", "g2", "g3", "g4"]))
        f.authors = Set(arranged(["a0", "a1", "a2"]))
        f.keywordAs = Set(arranged(["k0", "k1", "k2", "k3"]))
        f.bookTypes = Set(arranged([0, 1, 3]))
        f.unseen = .unreadOnly
        f.dateAdded = .init(direction: .within, days: 7)
        return f
    }

    private func makeBook(id: Int) -> BookRecord {
        BookRecord(
            id: id, title: "t\(id)", author: "a\(id % 3)", genre: "g\(id % 2)",
            path: "/tmp/g62-facet-key-\(id).zip", dateAdded: Date(timeIntervalSince1970: TimeInterval(1_000 * id)),
            playDate: nil, bookType: 0, fileType: 2, pages: 10, myRate: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, series: "S", volume: Double(id))
    }

    /// 開いた書庫のうち鍵が読む部分（本物の LibrarySettings・サイドバーは書庫・リスト表示・一覧を 1 回読む）。
    private func makeLocal() throws -> (AppState, LibrarySettings, Database) {
        let db = try Database.openInMemory()
        try db.migrate()
        for i in 1...6 { try db.insertBook(makeBook(id: i)) }
        let state = AppState(bundleURL: URL(fileURLWithPath: "/tmp/g62-facet-key.stacknest"))
        state.database = db
        let settings = try LibrarySettings(database: db)
        state.librarySettings = settings
        state.viewMode = .list
        try state.refreshDisplayedBooks()
        return (state, settings, db)
    }

    /// 保存済みのブラウズ状態を読まない（新しい serverID）・ディスクを使わないリモートの窓の状態。
    private func makeRemote() -> RemoteLibraryState {
        RemoteLibraryState(
            client: RemoteLibraryClient(baseURL: URL(string: "http://127.0.0.1:1/")!, deviceToken: "device"),
            serverID: UUID(), libraryUUID: "LIB-\(UUID().uuidString)",
            libraryName: "G62", locked: false,
            coverCache: RemoteCoverCache(cache: nil, serverID: nil, libraryUUID: nil))
    }

    @Test func theLocalKeyIsTheSameForAnUnchangedEmptyFilter() throws {
        let (state, settings, _) = try makeLocal()
        let keys = distinctKeys(900) { FacetRefreshKey.local(state, settings: settings) }
        #expect(keys.count == 1, Comment(rawValue: "distinct=\(keys.count)"))
    }

    @Test func theLocalKeyIsTheSameForAnUnchangedNonEmptyFilter() throws {
        let (state, settings, _) = try makeLocal()
        settings.filterState = nonEmptyFilter()
        let keys = distinctKeys(900) { FacetRefreshKey.local(state, settings: settings) }
        #expect(keys.count == 1, Comment(rawValue: "distinct=\(keys.count)"))
    }

    @Test func theRemoteKeyIsTheSameForAnUnchangedEmptyFilter() {
        let remote = makeRemote()
        let keys = distinctKeys(900) { remote.facetRefreshKey }
        #expect(keys.count == 1, Comment(rawValue: "distinct=\(keys.count)"))
    }

    @Test func theRemoteKeyIsTheSameForAnUnchangedNonEmptyFilter() {
        let remote = makeRemote()
        remote.filterState = nonEmptyFilter()
        let keys = distinctKeys(900) { remote.facetRefreshKey }
        #expect(keys.count == 1, Comment(rawValue: "distinct=\(keys.count)"))
    }

    /// 同じ中身のフィルタを `Set` から作り直しても（別の格納先・別の入れた順）、フィルタの部分は同じ。
    /// `.sortedKeys` だけでは `Set` の要素の順が作り直すたびに変わる。
    @Test func anEqualFilterRebuiltFromFreshSetsGivesTheSameFilterPart() {
        var rebuilt: [FilterState] = []
        let parts = distinctKeys(300) {
            let f = nonEmptyFilter(order: rebuilt.count)
            rebuilt.append(f)   // 作り直した値を生かしておく（格納先が使い回されないように）
            return FacetRefreshKey.filterPart(f)
        }
        #expect(Set(rebuilt.map { $0 == nonEmptyFilter() }) == [true])
        #expect(parts.count == 1, Comment(rawValue: "distinct=\(parts.count)"))
    }

    /// 鍵を揃えすぎていないこと。条件が 1 つでも違えばフィルタの部分も違う（違わないと列が古い値のまま残る）。
    @Test func differentFiltersGiveDifferentFilterParts() {
        func with(_ edit: (inout FilterState) -> Void) -> FilterState {
            var f = FilterState()
            edit(&f)
            return f
        }
        let variants: [FilterState] = [
            FilterState(),
            with { $0.genres = ["x"] },
            with { $0.genres = ["y"] },
            with { $0.genres = ["x", "y"] },
            with { $0.serieses = ["x"] },
            with { $0.authors = ["x"] },
            with { $0.netas = ["x"] },
            with { $0.keywordAs = ["x"] },
            with { $0.keywordBs = ["x"] },
            with { $0.keywordCs = ["x"] },
            with { $0.bookTypes = [1] },
            with { $0.bookTypes = [2] },
            with { $0.bookTypes = [1, 2] },
            with { $0.unseen = .unreadOnly },
            with { $0.unseen = .readOnly },
            with { $0.ratingMin = 3 },
            with { $0.ratingMin = 4 },
            with { $0.dateAdded = .init(direction: .within, days: 7) },
            with { $0.dateAdded = .init(direction: .olderThan, days: 7) },
            with { $0.dateAdded = .init(direction: .within, days: 8) },
            with { $0.playDate = .init(direction: .within, days: 7) },
        ]
        let parts = variants.map(FacetRefreshKey.filterPart)
        #expect(!parts.contains(""))
        #expect(Set(parts).count == variants.count, Comment(rawValue: parts.joined(separator: "\n")))
    }

    /// 本だけの外部の変更（サーバ経由の PATCH が `ExternalChangeCoalescer.deliver` で届く形）は、
    /// 鍵も一覧の版も変えない。変えると 3 列の問い合わせと表の全体の作り直しが書き込みのたびに走る（M0）。
    @Test func aBookOnlyExternalChangeKeepsTheKeyAndBothVersions() throws {
        let (state, settings, db) = try makeLocal()
        let key = FacetRefreshKey.local(state, settings: settings)
        let dataVersion = state.booksDataVersion
        let sortedVersion = state.sortedDisplayedBooksVersion

        var patch = BookPatch()
        patch.series = "G62 外部"
        try db.updateBook(id: 2, patch: patch)
        state.applyExternalChanges(bookIDs: [2], structureChanged: false)

        // 変更は一覧に届いている（試験が空振りしていない）。
        #expect(state.sortedDisplayedBooks.first { $0.id == 2 }?.series == "G62 外部")
        #expect(state.booksDataVersion == dataVersion)
        #expect(state.sortedDisplayedBooksVersion == sortedVersion)
        let after = distinctKeys(300) { FacetRefreshKey.local(state, settings: settings) }
        #expect(after == [key], Comment(rawValue: "distinct=\(after.count)"))
    }
}
