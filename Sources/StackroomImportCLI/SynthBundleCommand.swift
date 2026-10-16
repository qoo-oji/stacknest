// SPDX-License-Identifier: MIT
import AppCore
import ArgumentParser
import Foundation
import LibraryStore

/// G62（spec §7.1-1）: 計測用の合成の書庫（`.stacknest`）を作る。本のファイルは作らない（表紙は代わりの絵になる）。
/// 表示の設定は 2026-10-02 の事件の書庫と同じ形にする（リスト表示・7 列・追加日の降順・上ペインはブラウザ）。
/// ブラウザ区画の高さは書庫の設定に無い（窓の側の値）ので入れない。
public struct SynthBundleCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "synth-bundle",
        abstract: "Create a synthetic .stacknest bundle for the G62 burst benchmark (no book files)."
    )

    @Option(help: "Number of books.")
    public var count: Int = 12_441

    @Option(help: "Output bundle path; must not exist yet.")
    public var out: String

    @Option(help: "PRNG seed (the same seed gives the same library).")
    public var seed: UInt64 = 42

    public init() {}

    /// 事件の書庫の 7 列（読んだ日・評価・書名・未読・追加日・ジャンル・作者）。この順で左から並べる。
    public static let visibleColumns: [BookColumn] = [.playDate, .rating, .title, .unseen, .dateAdded, .genre, .author]

    public func run() throws {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        // ArgumentParser は main thread で run() を呼ぶ。LibrarySettings は @MainActor。
        // self を閉包に送らないよう（Swift 6 の SendingRisksDataRace）、値をローカルに写してから渡す。
        let count = count, seed = seed
        try MainActor.assumeIsolated { try Self.make(at: url, count: count, seed: seed) }
        print("created \(url.path) books=\(count)")
    }

    /// 書庫を作り、本を `count` 冊入れ、表示の設定を書く。`url` が既にあれば投げる（`createEmpty` の約束）。
    @MainActor
    public static func make(at url: URL, count: Int, seed: UInt64) throws {
        let bundle = try LibraryBundleCreator.createEmpty(at: url)
        let db = try Database.openExisting(at: bundle.databaseURL)
        defer { db.close() }
        try SyntheticLibrary.generate(into: db, count: count, seed: seed)
        let settings = try LibrarySettings(database: db)
        settings.viewMode = .list
        settings.listViewColumns = Set(visibleColumns)
        settings.listColumnOrder = visibleColumns + BookColumn.allCases.filter { !visibleColumns.contains($0) }
        settings.sortMode = .column
        settings.listViewSort = ColumnSort(column: .dateAdded, ascending: false)
        settings.topPaneMode = "browse"
        _ = settings.ensureLibraryUUID()
        settings.flushPendingWrites()
    }
}
