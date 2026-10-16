// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import StackroomFormat
@testable import LibraryServer

/// G54-S3e（spec §2.4）: DTO が実際に出す JSON のキーが、openapi.yaml のそのスキーマの properties に全部あること。
/// S3d で Web が `filename` を使い始めたのに spec に無かった（食い違いが黙って育った）のを繰り返さない。
/// YAML のパーサは依存に無いので、`components.schemas.<名前>.properties` 直下（字下げ 8）のキーだけを拾う。
@Suite("G54-S3e: openapi.yaml と DTO の食い違い")
struct OpenAPIDTOParityTests {
    private func specText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LibraryServerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
            .appendingPathComponent("Sources/LibraryServer/Resources/openapi/openapi.yaml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `components.schemas.<schema>.properties` のキー（字下げ 8 の行）。スキーマが無ければ空。
    static func propertyNames(of schema: String, in yaml: String) -> Set<String> {
        var names: Set<String> = []
        var inSchema = false
        var inProperties = false
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if !inSchema {
                if line == "    \(schema):" { inSchema = true }
                continue
            }
            if indent <= 4 { break }                                   // 次のスキーマ
            if indent == 6 { inProperties = (trimmed == "properties:"); continue }
            if inProperties, indent == 8, let colon = trimmed.firstIndex(of: ":") {
                names.insert(String(trimmed[..<colon]))
            }
        }
        return names
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: e.encode(value)) as? [String: Any] ?? [:]
    }

    /// 省略できるフィールドを全部埋めた一覧の 1 件（nil のキーは JSON に出ないので、全部埋めないと検出できない）。
    private func fullListItem() -> BookListItemDTO {
        BookListItemDTO(
            id: 1, title: "t", author: "a", series: "s", volume: 1, rating: 3, unseen: true, bookType: 0,
            pages: 10, lastPage: 2, lastReadAt: Date(timeIntervalSince1970: 0), dateAdded: Date(timeIntervalSince1970: 0),
            hasCover: true, coverVersion: "v", genre: "g", neta: "n", keywordA: "ka", keywordB: "kb", keywordC: "kc",
            memo: "m", coverCropRectJSON: "{}", filename: "a.zip")
    }

    private func fullDetail() -> BookDetailDTO {
        BookDetailDTO(
            id: 1, title: "t", author: "a", genre: "g", path: "p",
            dateAdded: Date(timeIntervalSince1970: 0), playDate: Date(timeIntervalSince1970: 0),
            bookType: 0, fileType: 0, pages: 10, lastPage: 2,
            epubLocator: EPUBLocatorDTO(spine: 1, progress: 0.5, cfi: "c", engine: "washi"),
            rating: 3, unseen: true, keywordA: "ka", keywordB: "kb", keywordC: "kc",
            neta: "n", memo: "m", series: "s", volume: 1,
            coverImageName: "c.jpg", coverCropRectJSON: "{}", pageDirection: "rtl",
            fileExtension: "zip", filename: "a.zip", previous: fullPatch())
    }

    /// PATCH の応答の `previous` に入る、全項目を埋めた BookPatchDTO。
    private func fullPatch() -> BookPatchDTO {
        BookPatchDTO(
            title: "t", author: "a", genre: "g", neta: "n", memo: "m",
            keywordA: "ka", keywordB: "kb", keywordC: "kc", rating: 3, unseen: true,
            series: "s", volume: 1, bookType: 0, pageDirection: "rtl",
            clearSeries: true, clearVolume: true, clearPageDirection: true)
    }

    private func fullPreset() -> FilenameFormatPresetDTO {
        FilenameFormatPresetDTO(id: "p", name: "n", format: "@title")
    }

    private func expectKeys(_ keys: some Sequence<String>, in schema: String, spec: String) {
        let names = Self.propertyNames(of: schema, in: spec)
        #expect(!names.isEmpty, "openapi.yaml に \(schema) が見つからない（読み方が壊れている）")
        let missing = Set(keys).subtracting(names)
        #expect(missing.isEmpty, "openapi.yaml の \(schema) に無いキー: \(missing.sorted())")
    }

    /// 入れ子の値（オブジェクト 1 つ、またはオブジェクトの配列の先頭）のキーを、そのスキーマと比べる。
    /// 入れ子が空だと何も比べずに通ってしまうので、空なら落とす。さらに中を見るために、その値を返す。
    @discardableResult
    private func expectNestedKeys(_ parent: [String: Any], _ key: String, in schema: String, spec: String) -> [String: Any] {
        let value = parent[key] as? [String: Any] ?? (parent[key] as? [[String: Any]])?.first ?? [:]
        #expect(!value.isEmpty, "入れ子の \(key) が空（\(schema) の確かめが空振りする。全項目を埋めた値で作る）")
        expectKeys(value.keys, in: schema, spec: spec)
        return value
    }

    @Test func bookListItemKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(fullListItem()).keys, in: "BookListItemDTO", spec: spec)
    }

    @Test func bookDetailKeysAreInTheSpec() throws {
        let spec = try specText()
        let detail = try object(fullDetail())
        expectKeys(detail.keys, in: "BookDetailDTO", spec: spec)
        // G65: 入れ子（EPUB の読書位置・PATCH の応答の変更前の値）も見る。
        expectNestedKeys(detail, "epubLocator", in: "EPUBLocatorDTO", spec: spec)
        expectNestedKeys(detail, "previous", in: "BookPatchDTO", spec: spec)
    }

    /// G60: 本専用トークンの発行の応答（v3 で tokenID を足した）。
    @Test func viewerTokenReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(ViewerTokenReply(token: "t", expiresAt: Date(timeIntervalSince1970: 0), tokenID: "id")).keys,
                   in: "ViewerTokenReply", spec: spec)
    }

    /// G60 v3: 本専用トークンの使用の照会の応答。
    @Test func viewerTokenStatusReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(ViewerTokenStatusReply(firstUsedAt: Date(timeIntervalSince1970: 0), viewer: "v")).keys,
                   in: "ViewerTokenStatusReply", spec: spec)
    }

    @Test func bookPageKeysAreInTheSpec() throws {
        let spec = try specText()
        let page = try object(BookPageDTO(items: [fullListItem()], total: 1, page: 1, perPage: 50))
        expectKeys(page.keys, in: "BookPageDTO", spec: spec)
        let item = (page["items"] as? [[String: Any]])?.first ?? [:]
        expectKeys(item.keys, in: "BookListItemDTO", spec: spec)
    }

    @Test func adjacentVolumeKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = try object(AdjacentVolumeReply(book: fullListItem()))
        expectKeys(reply.keys, in: "AdjacentVolumeReply", spec: spec)
        expectKeys((reply["book"] as? [String: Any] ?? [:]).keys, in: "BookListItemDTO", spec: spec)
    }

    /// G65: /me の応答（role は tier から導く互換の値・scope は G23 から）。
    @Test func meReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(MeReply(tier: .edit, scope: .libraries(["u"]))).keys, in: "MeReply", spec: spec)
    }

    /// G65: DELETE book の応答（全項目を非 nil で入れて、すべてのキーを出す）。
    @Test func bookRestoreKeysAreInTheSpec() throws {
        let spec = try specText()
        let dto = BookRestoreDTO(
            id: 1, title: "t", author: "a", genre: "g", path: "/p",
            dateAdded: 1, playDate: 2, bookType: 0, fileType: 1, pages: 3,
            rating: 4, unseen: true, keywordA: "a", keywordB: "b", keywordC: "c",
            neta: "n", memo: "m", series: "s", volume: 1.5, coverImageName: "c.jpg",
            coverCropX: 0, coverCropY: 0, coverCropW: 1, coverCropH: 1,
            pageDirection: "rtl", contentHash: "h", fileSize: 10, fileMtime: 5, hasCover: true)
        expectKeys(try object(dto).keys, in: "BookRestoreDTO", spec: spec)
    }

    // MARK: - G65（spec §6.4）: 文書に載せた応答の DTO を 1 つずつ。optional は全部埋める（nil は JSON に出ず空振りする）。

    @Test func serverCapabilitiesKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(ServerCapabilities.inApp).keys, in: "ServerCapabilities", spec: spec)
    }

    @Test func libraryKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(LibraryDTO(id: "u", name: "n", locked: true, bookCount: 1)).keys, in: "LibraryDTO", spec: spec)
    }

    /// manifest は optional を 3 つ持つ（ページごとの上書き・破損の注意・EPUB の読書位置）。
    @Test func manifestKeysAreInTheSpec() throws {
        let spec = try specText()
        let manifest = try object(ManifestDTO(
            pageCount: 2, direction: "rtl", format: "archive", etag: "e",
            pageOverrides: ["0": 1], damageNote: "d",
            epubLocator: EPUBLocatorDTO(spine: 1, progress: 0.5, cfi: "c", engine: "washi")))
        expectKeys(manifest.keys, in: "ManifestDTO", spec: spec)
        expectNestedKeys(manifest, "epubLocator", in: "EPUBLocatorDTO", spec: spec)
    }

    @Test func unlockReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(UnlockReply(libraryToken: "t")).keys, in: "UnlockReply", spec: spec)
    }

    @Test func sessionReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(SessionReply(sessionToken: "s", expiresIn: 1800)).keys, in: "SessionReply", spec: spec)
    }

    @Test func shelfKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(ShelfDTO(id: 1, title: "t", kind: "playlist", isSmart: false, bookCount: 3)).keys,
                   in: "ShelfDTO", spec: spec)
    }

    @Test func stampDefinitionsKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(StampDefinitionsDTO(definitions: ["genre": ["a"]])).keys, in: "StampDefinitionsDTO", spec: spec)
    }

    @Test func stampApplyReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(StampApplyReply(updated: 1)).keys, in: "StampApplyReply", spec: spec)
    }

    @Test func coverCandidatesKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(CoverCandidatesDTO(entries: ["1.jpg"], current: "1.jpg")).keys, in: "CoverCandidatesDTO", spec: spec)
    }

    @Test func labelSettingsKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(LabelSettingsDTO(customFieldLabels: ["genre": "g"], customBookTypeLabels: ["0": "b"])).keys,
                   in: "LabelSettingsDTO", spec: spec)
    }

    @Test func addBooksReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(AddBooksReplyDTO(addedIDs: [1], alreadyPresent: ["a"], failed: ["b"])).keys,
                   in: "AddBooksReplyDTO", spec: spec)
    }

    /// スマートシェルフの条件 → ルール → 値の 3 段（`StackroomFormat` の型）。
    @Test func smartShelfConditionsKeysAreInTheSpec() throws {
        let spec = try specText()
        let rule = SmartShelfRule(id: UUID(), field: .title, op: .contains, value: .text("x"))
        let conditions = try object(SmartShelfConditions(version: 1, match: .all, rules: [rule]))
        expectKeys(conditions.keys, in: "SmartShelfConditions", spec: spec)
        let ruleObject = expectNestedKeys(conditions, "rules", in: "SmartShelfRule", spec: spec)
        expectNestedKeys(ruleObject, "value", in: "RuleValue", spec: spec)
    }

    /// 監視フォルダの設定。要素（フォルダ・プリセット）も全項目（`presetID` を含む）を埋めて中まで見る。
    @Test func watchConfigKeysAreInTheSpec() throws {
        let spec = try specText()
        let folder = WatchedFolderDTO(id: "f", path: "/w", enabled: true, presetID: "p",
                                      baseline: ["/w/a.zip"], subfolderMode: .archive)
        let config = try object(WatchConfigDTO(enabled: true, folders: [folder], presets: [fullPreset()]))
        expectKeys(config.keys, in: "WatchConfigDTO", spec: spec)
        expectNestedKeys(config, "folders", in: "WatchedFolderDTO", spec: spec)
        expectNestedKeys(config, "presets", in: "FilenameFormatPresetDTO", spec: spec)
    }

    /// ファイル名の書式のプリセットの集まり（要素は format まで埋める）。
    @Test func presetSetKeysAreInTheSpec() throws {
        let spec = try specText()
        let set = try object(PresetSetDTO(presets: [fullPreset()], defaultID: "p"))
        expectKeys(set.keys, in: "PresetSetDTO", spec: spec)
        expectNestedKeys(set, "presets", in: "FilenameFormatPresetDTO", spec: spec)
    }

    /// 書庫ごとの取り込みの設定（3 項目とも optional。全部埋める）。
    @Test func importConfigKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(ImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: 20, preferEPUBTitle: true)).keys,
                   in: "ImportConfigDTO", spec: spec)
    }

    @Test func globalImportConfigKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(GlobalImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: 20, preferEPUBTitle: true)).keys,
                   in: "GlobalImportConfigDTO", spec: spec)
    }

    @Test func generalSettingsKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(GeneralSettingsDTO(displayName: "n", backupEnabled: true, backupGenerations: 5)).keys,
                   in: "GeneralSettingsDTO", spec: spec)
    }

    /// 重複の検査 → 組 → 組の本（一覧の 1 件）の 3 段。
    @Test func duplicateScanKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = try object(DuplicateScanReply(
            exact: [DuplicateGroupDTO(kind: "exact", key: "h", members: [fullListItem()])],
            possible: [DuplicateGroupDTO(kind: "possibleSeriesVolume", key: "s", members: [fullListItem()])],
            candidateCount: 2, hashedCount: 1, missingCount: 0))
        expectKeys(reply.keys, in: "DuplicateScanReply", spec: spec)
        let group = expectNestedKeys(reply, "exact", in: "DuplicateGroupDTO", spec: spec)
        expectNestedKeys(reply, "possible", in: "DuplicateGroupDTO", spec: spec)
        expectNestedKeys(group, "members", in: "BookListItemDTO", spec: spec)
    }

    /// 整合性の集計。G64 で init の `unsupported:` に既定値が無くなったので明示する（nil だとキーが消えて空振りする）。
    @Test func integritySummaryKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = IntegritySummaryReply(checked: 1, unchecked: 2, damaged: 3, degraded: 4, unsupported: 5, lastScanAt: 6)
        expectKeys(try object(reply).keys, in: "IntegritySummaryReply", spec: spec)
    }

    @Test func integrityScanKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = IntegrityScanReply(scanned: 6, ok: 1, damaged: 1, empty: 1, missing: 1, unsupported: 1,
                                       pagesUpdated: 1, persistenceFailures: 1)
        expectKeys(try object(reply).keys, in: "IntegrityScanReply", spec: spec)
    }

    /// 整合性の記録の一覧。要素の optional（filename・entryCount）も埋める。
    @Test func integrityListKeysAreInTheSpec() throws {
        let spec = try specText()
        let item = IntegrityItemDTO(bookID: 1, title: "t", filename: "a.zip", status: "damaged",
                                    checkedAt: 1, entryCount: 3, badEntries: ["x.jpg"], degraded: true)
        let list = try object(IntegrityListReply(items: [item]))
        expectKeys(list.keys, in: "IntegrityListReply", spec: spec)
        expectNestedKeys(list, "items", in: "IntegrityItemDTO", spec: spec)
    }

    @Test func integrityCheckKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(IntegrityCheckDTO(healthy: true, rows: ["ok"])).keys, in: "IntegrityCheckDTO", spec: spec)
    }

    /// 保守のジョブの進み（走っている間だけ出る 4 項目も埋める）。
    @Test func maintenanceStatusKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = MaintenanceStatusReply(running: true, job: "full-scan", done: 1, total: 2, startedAt: 3)
        expectKeys(try object(reply).keys, in: "MaintenanceStatusReply", spec: spec)
    }

    /// グラント（scope は書庫を決めた形。scope の中身は oneOf の 1 行なので、名前の付いたスキーマとしては見ない）。
    @Test func grantKeysAreInTheSpec() throws {
        let spec = try specText()
        let grant = GrantDTO(id: "g", label: "l", token: "t", tier: .edit, scope: .libraries(["u"]))
        expectKeys(try object(grant).keys, in: "GrantDTO", spec: spec)
    }

    @Test func libraryCountsKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(LibraryCountsDTO(libraryTotal: 3, recentCount: 1, recentDays: 14)).keys,
                   in: "LibraryCountsDTO", spec: spec)
    }

    @Test func restoreResultKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(RestoreResultDTO(restored: 1, requested: 2, restoredIDs: [1])).keys,
                   in: "RestoreResultDTO", spec: spec)
    }

    @Test func openLibraryReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(OpenLibraryReply(uuid: "u")).keys, in: "OpenLibraryReply", spec: spec)
    }

    @Test func finderTagSyncStatusKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(FinderTagSyncStatusReply(field: "genre", running: true, locked: false)).keys,
                   in: "FinderTagSyncStatusReply", spec: spec)
    }

    /// Finder タグの再照合の結果（field・failure も埋める）。
    @Test func finderTagResyncKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = FinderTagResyncReply(status: "started", field: "genre", updatedInLibrary: 1, updatedInFinder: 1,
                                         skippedTags: ["a, b"], skippedBooks: ["b.zip"],
                                         indexingDisabledVolumes: ["V"], failure: "f")
        expectKeys(try object(reply).keys, in: "FinderTagResyncReply", spec: spec)
    }

    /// ファイル名の変更の結果。要素（1 冊分）の failure も埋めて中まで見る。
    @Test func renameFilesReplyKeysAreInTheSpec() throws {
        let spec = try specText()
        let row = RenamePlanRowDTO(id: 1, oldName: "a.zip", newName: "b.zip", status: "ok", failure: "f")
        let reply = try object(RenameFilesReply(status: "failed", applied: true, rows: [row], missingIDs: [2],
                                                renamed: 1, skipped: 1, failure: "f"))
        expectKeys(reply.keys, in: "RenameFilesReply", spec: spec)
        expectNestedKeys(reply, "rows", in: "RenamePlanRowDTO", spec: spec)
    }

    // MARK: - G65: 文書のスキーマが、どれもこの試験で確かめているか、理由付きで除いてあること

    /// 応答に出ない（要求の本文だけに使う）スキーマ。この試験は DTO が応答に出すキーを見るので対象外。
    static let requestBodyOnly = "要求の本文だけに使う（応答には出ない）"

    /// 確かめないスキーマ → 理由。新しい応答のスキーマを文書に足して試験を書かなければ、下の試験が落ちる。
    static let excludedSchemas: [String: String] = [
        "StampApplyRequest": requestBodyOnly,
        "CoverUpdateRequest": requestBodyOnly,
        "AddBooksRequestDTO": requestBodyOnly,
        "GrantCreateRequest": requestBodyOnly,
        "GrantUpdateRequest": requestBodyOnly,
        "ShelfCreateRequest": requestBodyOnly,
        "ShelfUpdateRequest": requestBodyOnly,
        "ShelfBooksRequest": requestBodyOnly,
        "LockRequest": requestBodyOnly,
        "LockRemoveRequest": requestBodyOnly,
        "FullScanStartRequest": requestBodyOnly,
        "ImportExistingRequest": requestBodyOnly,
        "RelinkRequest": requestBodyOnly,
        "OpenLibraryRequest": requestBodyOnly,
        "CloseLibraryRequest": requestBodyOnly,
        "FinderTagSyncFieldRequest": requestBodyOnly,
        "RenameFilesRequest": requestBodyOnly,
        "PageLayoutRequestBody": requestBodyOnly
            + "。Swift の型は LibraryServerCore.swift のファイルスコープの Decodable で、LibraryServerAPI に無く符号化もできない",
    ]

    /// `components.schemas` の直下（字下げ 4）の名前。
    static func schemaNames(in yaml: String) -> Set<String> {
        var names: Set<String> = []
        var inSchemas = false
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent <= 2 { inSchemas = (line == "  schemas:"); continue }
            if inSchemas, indent == 4, trimmed.hasSuffix(":") { names.insert(String(trimmed.dropLast())) }
        }
        return names
    }

    /// この試験のソースで `expectKeys`・`expectNestedKeys` に渡しているスキーマの名前（呼び出しの `in:` の文字列）。
    /// 手で書いた一覧と違い、試験を書かずに名前だけ足すことができない。
    private func schemasCheckedHere() throws -> Set<String> {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        return Set(source.components(separatedBy: "in: \"").dropFirst().map { String($0.prefix(while: { $0 != "\"" })) })
    }

    @Test func everySchemaIsCheckedOrExcludedWithAReason() throws {
        let documented = Self.schemaNames(in: try specText())
        let checked = try schemasCheckedHere()
        let excluded = Set(Self.excludedSchemas.keys)
        let unchecked = documented.subtracting(checked).subtracting(excluded)
        #expect(unchecked.isEmpty, "文書のスキーマに DTO の試験が無い（試験を足すか、理由を付けて除外表に足す）: \(unchecked.sorted())")
        let notInDocument = checked.union(excluded).subtracting(documented)
        #expect(notInDocument.isEmpty, "試験・除外表にあって文書に無いスキーマ: \(notInDocument.sorted())")
        let both = checked.intersection(excluded)
        #expect(both.isEmpty, "試験で確かめているのに除外表にもある（除外が古い）: \(both.sorted())")
    }

    /// 読み方そのものの確かめ（入れ子の properties・次のスキーマのキーを拾わない）。
    @Test func readerPicksOnlyTheSchemaOwnProperties() {
        let yaml = """
        components:
          schemas:
            A:
              type: object
              properties:
                x:
                  type: object
                  properties:
                    nested: { type: integer }
                y: { type: string }
              required: [x]
            B:
              properties:
                z: { type: integer }
        """
        #expect(Self.propertyNames(of: "A", in: yaml) == ["x", "y"])
        #expect(Self.propertyNames(of: "B", in: yaml) == ["z"])
        #expect(Self.propertyNames(of: "C", in: yaml).isEmpty)
        #expect(Self.schemaNames(in: yaml) == ["A", "B"])
    }
}
