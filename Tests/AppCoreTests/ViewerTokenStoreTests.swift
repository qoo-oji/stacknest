// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

@Suite("G60: 本専用の読み取りトークンの保存")
struct ViewerTokenStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func freshDefaults() -> (UserDefaults, String) {
        let name = "g60-tokens-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// `.valid` の中身を ID で確かめる（Date の往復誤差に左右されないため）。
    private func validRecord(_ lookup: ViewerTokenLookup) -> ViewerTokenRecord? {
        if case .valid(let r) = lookup { return r }
        return nil
    }

    @Test func issuedTokenIsValidForItsBookAndIssuer() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let issued = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer,
                                 lockCredential: nil, now: t0)
        #expect(issued.token.count == 43)
        #expect(issued.record.libraryUUID == "LIB-1")
        #expect(issued.record.bookID == 7)
        #expect(issued.record.issuer == .sharedServer)
        #expect(issued.record.issuedAt == t0)
        #expect(issued.record.expiresAt == t0.addingTimeInterval(30 * day))
        #expect(issued.record.lockFingerprint == nil)
        #expect(validRecord(store.lookup(token: issued.token, issuer: .sharedServer, now: t0))?.id == issued.record.id)
    }

    @Test func onlyTheHashIsStored() throws {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let issued = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer,
                                 lockCredential: nil, now: t0)
        #expect(issued.record.tokenHash == ViewerTokenStore.hash(issued.token))
        #expect(issued.record.tokenHash != issued.token)
        let raw = try #require(d.data(forKey: ViewerTokenStore.defaultsKey))
        let text = try #require(String(data: raw, encoding: .utf8))
        #expect(!text.contains(issued.token), "平文のトークンを保存してはいけない")
        #expect(text.contains(issued.record.tokenHash))
    }

    @Test func anotherIssuerCannotUseTheToken() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let issued = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .localEndpoint,
                                 lockCredential: nil, now: t0)
        #expect(store.lookup(token: issued.token, issuer: .sharedServer, now: t0) == .unknown)
        #expect(validRecord(store.lookup(token: issued.token, issuer: .localEndpoint, now: t0)) != nil)
    }

    @Test func expiredTokenIsReportedAsExpired() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let issued = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer,
                                 lockCredential: nil, now: t0)
        let justBefore = t0.addingTimeInterval(30 * day - 1)
        #expect(validRecord(store.lookup(token: issued.token, issuer: .sharedServer, now: justBefore)) != nil)
        #expect(store.lookup(token: issued.token, issuer: .sharedServer, now: t0.addingTimeInterval(30 * day)) == .expired)
    }

    @Test func unknownTokenIsUnknown() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        #expect(store.lookup(token: "not-issued", issuer: .sharedServer, now: t0) == .unknown)
    }

    @Test func tokensSurviveARestart() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let issued = ViewerTokenStore(defaults: d)
            .issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer, lockCredential: nil, now: t0)
        let reopened = ViewerTokenStore(defaults: d)
        #expect(validRecord(reopened.lookup(token: issued.token, issuer: .sharedServer, now: t0))?.id == issued.record.id)
    }

    @Test func reopeningIssuesANewTokenAndKeepsTheOld() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let a = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer, lockCredential: nil, now: t0)
        let b = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer, lockCredential: nil, now: t0)
        #expect(a.token != b.token)
        #expect(validRecord(store.lookup(token: a.token, issuer: .sharedServer, now: t0)) != nil)
        #expect(validRecord(store.lookup(token: b.token, issuer: .sharedServer, now: t0)) != nil)
    }

    @Test func pruneDropsOnlyExpiredAndPersists() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let old = store.issue(libraryUUID: "LIB-1", bookID: 1, issuer: .sharedServer, lockCredential: nil, now: t0)
        let fresh = store.issue(libraryUUID: "LIB-1", bookID: 2, issuer: .sharedServer, lockCredential: nil,
                                now: t0.addingTimeInterval(10 * day))
        #expect(store.pruneExpired(now: t0.addingTimeInterval(35 * day)) == 1)
        #expect(store.allRecords().map(\.id) == [fresh.record.id])
        #expect(ViewerTokenStore(defaults: d).allRecords().map(\.id) == [fresh.record.id])
        #expect(store.lookup(token: old.token, issuer: .sharedServer, now: t0) == .unknown)
    }

    @Test func issuingAlsoDropsExpired() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        _ = store.issue(libraryUUID: "LIB-1", bookID: 1, issuer: .sharedServer, lockCredential: nil, now: t0)
        let later = store.issue(libraryUUID: "LIB-1", bookID: 2, issuer: .sharedServer, lockCredential: nil,
                                now: t0.addingTimeInterval(31 * day))
        #expect(store.allRecords().map(\.id) == [later.record.id])
    }

    /// I-3: 共有サーバで発行したトークンは発行元のグラントを覚える。アプリが手元で出したものは nil。
    @Test func recordsTheIssuingGrant() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        let store = ViewerTokenStore(defaults: d)
        let byGrant = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer,
                                  lockCredential: nil, issuedByGrantID: "grant-1", now: t0)
        let local = store.issue(libraryUUID: "LIB-1", bookID: 7, issuer: .localEndpoint,
                                lockCredential: nil, now: t0)
        #expect(byGrant.record.issuedByGrantID == "grant-1")
        #expect(local.record.issuedByGrantID == nil)
        let reopened = ViewerTokenStore(defaults: d).allRecords()
        #expect(reopened.first { $0.id == byGrant.record.id }?.issuedByGrantID == "grant-1")
    }

    @Test func lockFingerprintFollowsTheCredential() {
        let (d, n) = freshDefaults(); defer { d.removePersistentDomain(forName: n) }
        #expect(ViewerTokenStore.lockFingerprint(for: nil) == nil)
        let a = ViewerTokenStore.lockFingerprint(for: "hash-1")
        #expect(a != nil)
        #expect(a == ViewerTokenStore.lockFingerprint(for: "hash-1"))
        #expect(a != ViewerTokenStore.lockFingerprint(for: "hash-2"))
        #expect(a != "hash-1", "ロックのハッシュそのものを写して保存しない")
        let issued = ViewerTokenStore(defaults: d)
            .issue(libraryUUID: "LIB-1", bookID: 7, issuer: .sharedServer, lockCredential: "hash-1", now: t0)
        #expect(issued.record.lockFingerprint == a)
    }
}
