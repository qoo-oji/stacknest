// SPDX-License-Identifier: MIT
import Foundation
import Hummingbird
import AppCore
import LibraryServerAPI
@testable import LibraryServer

/// G65: 127.0.0.1 の口と同じ形（apiOnly・/local・中継あり）で、グラントのモードのサーバを組む。
/// グラントはメモリ上（実際の UserDefaults に触らない）、書庫は 1 つも配らない。
enum G65ServerFixture {
    /// どの試験でも配っていない書庫の UUID（tier の確かめで resolve を 404 にするため）。
    static let unservedUUID = "00000000-0000-4000-8000-000000000065"
    static let readToken = "G65-READ"
    static let editToken = "G65-EDIT"
    static let adminToken = "G65-ADMIN"

    /// read・edit・admin の 3 グラント（scope は全書庫）を持つ、メモリ上のグラントの置き場。
    static func makeRepo() -> InMemoryGrantRepository {
        let epoch = Date(timeIntervalSince1970: 0)
        return InMemoryGrantRepository(initial: [
            Grant(id: "g65-r", label: "r", token: readToken, tier: .read, scope: .all, createdAt: epoch),
            Grant(id: "g65-e", label: "e", token: editToken, tier: .edit, scope: .all, createdAt: epoch),
            Grant(id: "g65-a", label: "a", token: adminToken, tier: .admin, scope: .all, createdAt: epoch),
        ])
    }

    static func core(repo: InMemoryGrantRepository = makeRepo()) -> LibraryServerCore {
        LibraryServerCore(
            config: .init(port: 0, token: "G65-UNUSED", editToken: nil,
                          apiOnly: true, adminTier: false,
                          grantRepository: repo,
                          enableLocalLibraryControl: true,
                          // 省くと LibraryServerCore.init の precondition でプロセスが落ちる。
                          viewerTokenIssuer: .localEndpoint,
                          viewerRelay: ViewerRelayConfig(registry: ViewerRelayRegistry())),
            dataSource: StaticLibraryDataSource(libraries: []))
    }

    /// コードに登録した道（"METHOD path"）。`/api/v1` は外し、`/local` はそのまま。
    static func codeRoutes() throws -> Set<String> {
        let router = core().buildRouter()
        try router.validate()
        return Set(router.routes.map { route in
            var path = route.path.description
            if path.hasPrefix("/api/v1/") { path = String(path.dropFirst("/api/v1".count)) }
            return "\(route.method.rawValue) \(path)"
        })
    }

    /// 文書の path を、呼べる URI にする（捕捉は仮の値）。
    static func uri(for path: String) -> String {
        let filled = path
            .replacingOccurrences(of: "{lib}", with: unservedUUID)
            .replacingOccurrences(of: "{uuid}", with: unservedUUID)
            .replacingOccurrences(of: "{id}", with: "1")
            .replacingOccurrences(of: "{n}", with: "1")
            .replacingOccurrences(of: "{field}", with: "series")
            .replacingOccurrences(of: "{tokenID}", with: "g65")
            .replacingOccurrences(of: "{relayID}", with: "g65")
        return filled.hasPrefix("/local/") ? filled : "/api/v1" + filled
    }
}
