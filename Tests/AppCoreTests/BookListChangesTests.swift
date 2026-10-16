// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

/// G62（spec §6.4・§8）: 行の信号。
@Suite("G62: BookListChanges")
struct BookListChangesTests {
    @Test func changedSinceReturnsOnlyLaterChanges() {
        var c = BookListChanges()
        c.markContent([1, 2])
        let v1 = c.contentVersion
        c.markContent([3])
        #expect(c.changed(since: 0) == [1, 2, 3])
        #expect(c.changed(since: v1) == [3])
        #expect(c.changed(since: c.contentVersion).isEmpty)
    }

    @Test func markingTheSameBookTwiceCountsOnce() {
        var c = BookListChanges()
        c.markContent([5])
        c.markContent([5])
        #expect(c.changed(since: 0) == [5])
        #expect(c.contentVersion == 2)
    }

    /// 構造の変化で空にしても版は戻さない（戻すと、表が前に見た版より小さい版が来て変化を見落とす）。
    @Test func resetEmptiesButKeepsTheVersionMovingForward() {
        var c = BookListChanges()
        c.markContent([1])
        let v = c.contentVersion
        c.reset()
        #expect(c.changed(since: 0).isEmpty)
        #expect(c.contentVersion == v)
        c.markContent([2])
        #expect(c.contentVersion == v + 1)
        #expect(c.changed(since: v) == [2])
    }

    @Test func markingNothingDoesNotMoveTheVersion() {
        var c = BookListChanges()
        c.markContent([])
        #expect(c.contentVersion == 0)
    }
}
