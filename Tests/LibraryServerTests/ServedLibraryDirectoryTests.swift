// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

/// G62（spec §6.1・§8）: 配信中の書庫のスナップショット。
@Suite("G62: ServedLibraryDirectory")
struct ServedLibraryDirectoryTests {
    @Test func replaceReadAndFilterBySharing() throws {
        let a = try TestLibraryFixture(name: "A", bookCount: 0); defer { a.cleanup() }
        let b = try TestLibraryFixture(name: "B", bookCount: 0); defer { b.cleanup() }
        let dir = ServedLibraryDirectory()
        #expect(dir.current().isEmpty)

        dir.replace([.init(library: a.servedLibrary(), sharedRemotely: true),
                     .init(library: b.servedLibrary(), sharedRemotely: false)])
        #expect(dir.current().map(\.library.name) == ["A", "B"])
        // ローカルコントロールは全部、共有サーバは共有を許した書庫だけ。
        #expect(dir.libraries(sharedRemotelyOnly: false).map(\.name) == ["A", "B"])
        #expect(dir.libraries(sharedRemotelyOnly: true).map(\.name) == ["A"])

        dir.replace([])
        #expect(dir.current().isEmpty)
    }

    /// 読み出しと差し替えを並行に繰り返しても、途中の状態（壊れた配列）が見えない。
    @Test func concurrentReadsAndReplacesSeeWholeSnapshots() async throws {
        let a = try TestLibraryFixture(name: "A", bookCount: 0); defer { a.cleanup() }
        let b = try TestLibraryFixture(name: "B", bookCount: 0); defer { b.cleanup() }
        let one: [ServedLibraryDirectory.Entry] = [.init(library: a.servedLibrary(), sharedRemotely: true)]
        let two: [ServedLibraryDirectory.Entry] = one + [.init(library: b.servedLibrary(), sharedRemotely: false)]
        let dir = ServedLibraryDirectory()
        dir.replace(one)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for i in 0..<2_000 { dir.replace(i.isMultiple(of: 2) ? two : one) } }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<2_000 {
                        let names = dir.current().map(\.library.name)
                        #expect(names == ["A"] || names == ["A", "B"])
                    }
                }
            }
        }
    }
}
