// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryStore
import os
import StackNestViewerKitCore

/// 外部ビューアからの「この本をもう一度渡して」（`stacknest://viewer/reopen?…`。StackNestViewerKit の
/// `StackNestReopenRequest`・形式の文書「本をもう一度渡してもらう」）。
///
/// 参照ファイルは残しても後から開き直せない（鍵の期限・ポートと中継の id が渡すたびに変わる・StackNest が動いていない
/// こともある）ので、外部ビューアは履歴や保存データから本を開き直すとき、この URL を開く。StackNest は動いていなければ
/// macOS が起動する。頼みにはライブラリの UUID・本の番号・本の同一性（manifest の `bookIdentity`）が入り、鍵は入らない。
///
/// 渡すのは次のときだけ（どれかに外れたら渡さず、知らせるか黙る）:
/// - 頼んだアプリが、今その本を渡す外部ビューア（`referenceViewer(for:)` のアプリ）である。どのアプリでも URL は開けるので、
///   頼みの Apple Event の送り手で確かめる。送り手が分からなければ渡さない。
/// - ライブラリが開いている、または外部ビューアへ本を渡したことがあって場所を覚えている（`ViewerReopenLibraries`）。
///   開いていなければ開く。施錠していれば解錠を待つ（解錠の画面が出る。⌘⇧O の続きから開くのと同じ規則）。
/// - 番号の本が今もあり、同一性が同じ（本の番号は使い回されるので、別の本を開かない）。
/// 渡し方はライブラリの窓で選んで開いたときと同じ（`openInExternalViewerSyncing`。開くページは保存済みの読書位置）。
@MainActor
enum ViewerReopen {
    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ViewerReopen")

    /// 頼みの URL か（`application(_:open:)` が振り分ける）。
    static func isRequestURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == StackNestReopenRequest.scheme
    }

    /// 頼みを受ける。ライブラリの窓を開く（開いている窓へ渡す）ことになったら true（起動時の題名の画面を出さない判断に使う）。
    @discardableResult
    static func handle(_ url: URL, sender: URL?) -> Bool {
        guard let request = StackNestReopenRequest(url: url) else {
            logger.info("reopen: ignored a malformed request")
            return false
        }
        guard let sender else {
            // 送り手の分からない頼みは渡さない（どのアプリでも URL は開ける）。
            logger.info("reopen: refused a request without a sender")
            return false
        }
        if let state = AppState.activeInstances.allObjects.first(where: {
            $0.librarySettings?.libraryUUID?.lowercased() == request.libraryUUID
        }) {
            state.handleViewerReopen(request, sender: sender)
            return true
        }
        guard let bundlePath = ViewerReopenLibraries.shared.bundlePath(for: request.libraryUUID),
              FileManager.default.fileExists(atPath: bundlePath)
        else {
            presentAlert(String(localized: "外部ビューアから頼まれた本のライブラリが見つかりません。StackNest でライブラリを開いてから、もう一度開いてください。"))
            return false
        }
        // ライブラリを開き、読み終えたところで渡す（AppState が `take(bundlePath:)` で受け取る）。
        pending = (bundlePath, request, sender)
        URLOpener.shared.enqueue(URL(fileURLWithPath: bundlePath))
        return true
    }

    /// 開き終えたライブラリの窓が、自分宛ての頼みを受け取る（1 回だけ）。
    static func take(bundlePath: String) -> (request: StackNestReopenRequest, sender: URL)? {
        guard let waiting = pending, waiting.bundlePath == bundlePath else { return nil }
        pending = nil
        return (waiting.request, waiting.sender)
    }

    /// ライブラリを開くのを待っている頼み（後から来た頼みが前のものを置き換える）。
    private static var pending: (bundlePath: String, request: StackNestReopenRequest, sender: URL)?

    /// 頼みの Apple Event の送り手のアプリ（`application(_:open:)` の中で呼ぶ。分からなければ nil）。
    static func senderOfCurrentEvent() -> URL? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid > 0,
              let app = NSRunningApplication(processIdentifier: pid_t(pid))
        else { return nil }
        return app.bundleURL
    }

    static func presentAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "外部ビューアの本を開けません")
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// 外部ビューアへ本を渡したことのあるライブラリの場所（UUID → パッケージのパス）。外部ビューアが閉じたライブラリの本を
/// 頼んだとき（`ViewerReopen`）に開くため。渡すたびに覚え直す（ライブラリを動かしても、次に渡したときに追いつく）。
/// 新しい順に `maxCount` 件まで。
@MainActor
final class ViewerReopenLibraries {
    static let shared = ViewerReopenLibraries(defaults: .standard)
    static let defaultsKey = "viewerReopenLibraryPaths"
    static let maxCount = 64

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 覚えている場所（UUID は小文字にそろえて引く）。
    func bundlePath(for libraryUUID: String) -> String? {
        entries().first { $0.uuid == libraryUUID.lowercased() }?.path
    }

    /// 本を渡したライブラリの場所を覚える（いちばん新しくする）。
    func record(libraryUUID: String, bundlePath: String) {
        let uuid = libraryUUID.lowercased()
        var list = entries().filter { $0.uuid != uuid && $0.path != bundlePath }
        list.insert((uuid, bundlePath), at: 0)
        defaults.set(list.prefix(Self.maxCount).map { ["uuid": $0.uuid, "path": $0.path] }, forKey: Self.defaultsKey)
    }

    private func entries() -> [(uuid: String, path: String)] {
        (defaults.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []).compactMap { item in
            guard let uuid = item["uuid"], let path = item["path"] else { return nil }
            return (uuid, path)
        }
    }
}

extension AppState {
    /// 外部ビューアからの頼みでこのライブラリの本を渡す（`ViewerReopen`）。施錠していて未解錠なら、解錠に成功したときに
    /// 渡す（`consumePendingViewerReopen`）。
    func handleViewerReopen(_ request: StackNestReopenRequest, sender: URL) {
        if needsUnlock {
            pendingViewerReopen = (request, sender)
            return
        }
        guard let book = try? database?.fetchBook(id: request.bookID),
              let uuid = librarySettings?.libraryUUID,
              ViewerBookIdentity.value(libraryUUID: uuid, bookID: book.id, dateAdded: book.dateAdded)
                  == request.bookIdentity
        else {
            watchNotice.present(Notice(kind: .warning, text: String(localized: "外部ビューアから頼まれた本は、このライブラリにありません。")))
            return
        }
        // 頼んだアプリが、今この本を渡す外部ビューアであるときだけ渡す（ほかのアプリの頼みで、設定していないアプリへ渡さない）。
        guard let viewer = referenceViewerForReopen(book),
              viewer.appURL.standardizedFileURL.path == sender.standardizedFileURL.path
        else {
            ViewerReopen.logger.info("reopen: the sender is not the external viewer for this book")
            watchNotice.present(Notice(kind: .warning, text: String(localized: "外部ビューアの設定が変わったため、頼まれた本を渡せませんでした。")))
            return
        }
        Task { @MainActor in await self.openInExternalViewerSyncing([book]) }
    }

    /// 解錠に成功したときに、待たせていた頼みを渡す（1 回だけ）。
    func consumePendingViewerReopen() {
        guard isUnlocked, let pending = pendingViewerReopen else { return }
        pendingViewerReopen = nil
        handleViewerReopen(pending.request, sender: pending.sender)
    }
}
