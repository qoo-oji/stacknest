// SPDX-License-Identifier: MIT
import Foundation
import LibraryServer

/// 開いている全ライブラリを配信する（共有 ON 不問）。ローカル制御エンドポイント用。
/// G62（spec §6.1）: スナップショットを読むだけ（MainActor を待たない）。
struct AllOpenLibrariesDataSource: LibraryServerDataSource {
    let directory: ServedLibraryDirectory

    init(directory: ServedLibraryDirectory = ServedLibraryPublisher.directory) {
        self.directory = directory
    }

    func servedLibraries() async -> [ServedLibrary] {
        directory.libraries(sharedRemotelyOnly: false)
    }
}
