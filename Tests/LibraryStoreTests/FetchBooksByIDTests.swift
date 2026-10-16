// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G62（spec §6.3・§8）: 反映のときに本をまとめて読む。
@Suite("G62: fetchBooks(ids:)")
struct FetchBooksByIDTests {
    private func makeDB(count: Int) throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        try SyntheticLibrary.generate(into: db, count: count)
        return db
    }

    @Test func returnsTheAskedBooksInAnyOrderAndSkipsMissingOnes() throws {
        let db = try makeDB(count: 5)
        let found = try db.fetchBooks(ids: [5, 1, 99])
        #expect(Set(found.keys) == [1, 5])
        #expect(found[1] == (try db.fetchBook(id: 1)))
        #expect(found[5] == (try db.fetchBook(id: 5)))
    }

    @Test func readsALargeSetInChunks() throws {
        let db = try makeDB(count: 20)
        let found = try db.fetchBooks(ids: Array(1...20), chunkSize: 3)
        #expect(found.count == 20)
        for id in 1...20 { #expect(found[id] == (try db.fetchBook(id: id))) }
    }

    @Test func emptyRequestAndClosedDatabaseReturnNothing() throws {
        let db = try makeDB(count: 2)
        #expect(try db.fetchBooks(ids: [Int]()).isEmpty)
        db.close()
        #expect(try db.fetchBooks(ids: [1, 2]).isEmpty)   // fetchBook と同じく、閉じた DB では何も返さない
    }
}
