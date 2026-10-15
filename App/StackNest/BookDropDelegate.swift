// SPDX-License-Identifier: MIT
import SwiftUI
import UniformTypeIdentifiers
import AppCore  // BookCategory.registrableExtensions

struct BookDropDelegate: DropDelegate {
    /// Called synchronously when the drop is accepted; returns the handler for the loaded URLs.
    /// Anything the handler depends on (e.g. the target shelf) must be captured here, because
    /// the URLs load asynchronously and the UI may change before they arrive (PR #4 review).
    let makeHandler: () -> ([URL]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        let onDrop = makeHandler()
        // G64: 1 回のドロップは、落とした時点の 1 つの一覧で判定する。
        let userExtensions = UserExtensionStore.shared.snapshot
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let filtered = urls.filter { Self.isAcceptable(url: $0, userExtensions: userExtensions) }
            if !filtered.isEmpty {
                onDrop(filtered)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    /// 受け付けるか: ディレクトリは無条件、ファイルは標準（`cbt`・`tar` を含む 29 個）か足した拡張子（G64）。
    static func isAcceptable(url: URL, userExtensions: UserExtensionMap) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        if isDir.boolValue { return true }
        let ext = url.pathExtension.lowercased()
        return BookCategory.registrableExtensions(userExtensions: userExtensions).contains(ext)
    }
}

/// 読み込みのパネルの delegate（G64 スモークの修正）。パネルがドロップと同じ規則
/// （`BookDropDelegate.isAcceptable`）で選べるものを決める。`NSOpenPanel.delegate` は weak なので、
/// 呼び出し側が `runModal()` の間保持する。
final class AddPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let userExtensions: UserExtensionMap

    init(userExtensions: UserExtensionMap) {
        self.userExtensions = userExtensions
    }

    /// パネルの判断そのもの。テストから直接呼ぶ。
    static func shouldEnable(url: URL, userExtensions: UserExtensionMap) -> Bool {
        BookDropDelegate.isAcceptable(url: url, userExtensions: userExtensions)
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        Self.shouldEnable(url: url, userExtensions: userExtensions)
    }

    /// 選ばれた URL を同じ規則で絞る。
    func filter(_ urls: [URL]) -> [URL] {
        urls.filter { Self.shouldEnable(url: $0, userExtensions: userExtensions) }
    }
}
