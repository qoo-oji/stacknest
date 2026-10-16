// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

/// G62（spec §6.1・§8）: 配信の一覧に載る値（表示名・共有・施錠）が変わった**後**にフックが呼ばれる。
@Suite("G62: onServedIdentityChange")
@MainActor
struct LibrarySettingsServedIdentityHookTests {
    /// フックが呼ばれた時点の値を記録する（「変わった後に」呼ばれたことを確かめる）。
    @MainActor final class Seen {
        var names: [String] = []
        var sharing: [Bool] = []
        var hashes: [String?] = []
    }

    private func make() throws -> (LibrarySettings, Database, Seen) {
        let db = try Database.openInMemory()
        try db.migrate()
        let settings = try LibrarySettings(database: db)
        let seen = Seen()
        settings.onServedIdentityChange = { [unowned settings] in
            seen.names.append(settings.displayName)
            seen.sharing.append(settings.remoteSharingEnabled)
            seen.hashes.append(settings.lockPasswordHash)
        }
        return (settings, db, seen)
    }

    @Test func displayName() throws {
        let (s, _, seen) = try make()
        s.displayName = "G62 名前"
        #expect(seen.names == ["G62 名前"])
    }

    @Test func remoteSharing() throws {
        let (s, _, seen) = try make()
        s.remoteSharingEnabled = true
        s.remoteSharingEnabled = false
        #expect(seen.sharing == [true, false])
    }

    @Test func setLockAndClearLock() throws {
        let (s, _, seen) = try make()
        #expect(try s.setLock(hash: "H1", salt: "S1", expectedHash: nil))
        #expect(seen.hashes.last == "H1")
        #expect(try s.clearLock(expectedHash: "H1"))
        #expect(seen.hashes.last == .some(nil))
    }

    @Test func reloadLockSettings() throws {
        let (s, db, seen) = try make()
        try db.setLibrarySettings(["lock_password_hash": "H2", "lock_password_salt": "S2"])
        s.reloadLockSettings()
        #expect(seen.hashes.last == "H2")
    }

    @Test func reloadGeneralSettings() throws {
        let (s, db, seen) = try make()
        try db.setLibrarySetting(key: "display_name", value: "外からの名前")
        s.reloadGeneralSettings()
        #expect(seen.names.contains("外からの名前"))
    }
}
