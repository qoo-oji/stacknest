// SPDX-License-Identifier: MIT
import Foundation
import Testing
import UniformTypeIdentifiers
import AppCore
@testable import StackNest

/// G64: ドロップと読み込みのパネルが受け付けるもの（spec §6.7）。一覧は引数で渡す（`shared` に触れない）。
@MainActor
@Suite("G64: ドロップと読み込みのパネル")
struct BookAddAcceptanceTests {
    private func file(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test("ドロップ: 何も足さずに cbt・tar が通り、足した tgz が通り、足していない djvu は弾く")
    func dropAcceptance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BookDropDelegate.isAcceptable(url: try file(dir, "a.cbt"), userExtensions: [:]))
        #expect(BookDropDelegate.isAcceptable(url: try file(dir, "a.TAR"), userExtensions: [:]))
        #expect(BookDropDelegate.isAcceptable(url: try file(dir, "a.zip"), userExtensions: [:]))
        let tgz = try file(dir, "a.tgz")
        #expect(!BookDropDelegate.isAcceptable(url: tgz, userExtensions: [:]))
        #expect(BookDropDelegate.isAcceptable(url: tgz, userExtensions: ["tgz": .archive]))
        #expect(!BookDropDelegate.isAcceptable(url: try file(dir, "a.djvu"), userExtensions: ["tgz": .archive]))
        #expect(BookDropDelegate.isAcceptable(url: dir, userExtensions: [:]), "ディレクトリは今どおり通す")
        #expect(!BookDropDelegate.isAcceptable(url: dir.appendingPathComponent("missing.cbt"), userExtensions: [:]))
    }

    @Test("読み込みのパネル: tar と cbt の型、足した拡張子の型が入る")
    func panelTypes() throws {
        let none = LibraryBrowserView.addPanelContentTypes(userExtensions: [:])
        let some = LibraryBrowserView.addPanelContentTypes(userExtensions: ["tgz": .archive, "djvu": .archive])
        let tar = try #require(UTType("public.tar-archive"))
        #expect(none.contains(tar))
        #expect(none.contains { $0.identifier == "app.shelfsmith.stacknest.cbt" || $0.preferredFilenameExtension == "cbt" })
        #expect(some.count == none.count + 2)
        #expect(some.contains(try #require(UTType(filenameExtension: "tgz"))))
        // どのアプリも宣言していない拡張子は動的な型になり、その拡張子を持つ。
        #expect(some.contains { $0.preferredFilenameExtension == "djvu" || $0.tags[.filenameExtension]?.contains("djvu") == true })
        // 存在しない型 ID の `?? .data` で「全部のファイル」を許さない（7z の ID は org.7-zip.7-zip-archive）。
        #expect(!none.contains { $0.identifier == "public.data" })
        let sevenZ = try #require(UTType(filenameExtension: "7z"))
        #expect(none.contains { sevenZ.conforms(to: $0) })
    }

    @Test("読み込みのパネルの delegate: ドロップと同じ規則で有効・無効を決める")
    func panelDelegateDecision() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tgz = try file(dir, "a.tgz"), djvu = try file(dir, "a.djvu"), avif = try file(dir, "a.avif")
        let gp3 = try file(dir, "a.3gp"), cbz = try file(dir, "a.cbz")
        let plain = AddPanelDelegate(userExtensions: [:])
        #expect(!plain.panel(NSObject(), shouldEnable: tgz))
        #expect(!plain.panel(NSObject(), shouldEnable: djvu))
        #expect(!plain.panel(NSObject(), shouldEnable: avif))
        #expect(!plain.panel(NSObject(), shouldEnable: gp3))
        #expect(plain.panel(NSObject(), shouldEnable: cbz))
        #expect(plain.panel(NSObject(), shouldEnable: dir), "ディレクトリは移動と選択のために有効")
        let added = AddPanelDelegate(userExtensions: ["tgz": .archive, "avif": .image])
        #expect(added.panel(NSObject(), shouldEnable: tgz))
        #expect(added.panel(NSObject(), shouldEnable: avif))
        #expect(!added.panel(NSObject(), shouldEnable: djvu))
        // パネルを抜けた後の絞り込みも同じ規則。
        #expect(plain.filter([tgz, djvu, cbz, dir]) == [cbz, dir])
    }
}
