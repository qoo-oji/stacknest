// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI
import RemoteClient

/// G60: 対応した外部ビューアへ、本を読むための口（参照ファイル `.stacknestbook`）を渡す（spec §5）。
///
/// ローカルの書庫の本は手元でトークンを出して 127.0.0.1 の口を指す（リモートの本は 6b で足す）。
/// 参照ファイルを書いて、画像の本の外部ビューアで開く。失敗したら理由（`Failure`）を返し、
/// 呼び出し側が従来の開き方に戻して理由を出す。
///
/// 依存はすべてプロパティにしてある。テストは UserDefaults.standard・実ポート・`LastReadTracker.shared` に
/// 触れずに差し替える（テストホストは本物のアプリと同じ defaults の領域を使うため）。
@MainActor
struct ExternalViewerHandoff {
    var tokens: ViewerTokenStore
    var references: BookReferenceStore
    var localPort: () -> Int
    var isLocalEndpointRunning: () -> Bool
    var recordLastRead: (LastReadBook) -> Void
    var now: () -> Date

    static var live: ExternalViewerHandoff {
        ExternalViewerHandoff(
            tokens: .shared,
            references: BookReferenceStore(),
            localPort: { ServerPreferences.localControlPort() },
            isLocalEndpointRunning: { LocalControlController.shared.isRunning },
            recordLastRead: { LastReadTracker.shared.record($0) },
            now: { Date() })
    }

    enum Failure: Error, Equatable {
        case localEndpointNotRunning
        case pageCountUnavailable
        case tokenUnavailable
        /// 旧サーバ（`POST …/viewer-token` のルートが無い＝404、または未実装の 501）。G60 より前と同じ挙動なので、
        /// 呼び出し側は理由を出さずに内蔵ビューアで開く。
        case unsupportedByServer
        case referenceNotWritten
        case launchFailed(String)
        /// このウィンドウが解錠していない（または解錠後に変えられた）ロックの書庫。何も開かない。
        case libraryLocked

        /// 画面に出す理由（「…ため、…で開きました（理由）」の括弧の中）。
        var reason: String {
            switch self {
            case .localEndpointNotRunning:
                return String(localized: "ローカルコントロールの受け口（127.0.0.1）が動いていません")
            case .pageCountUnavailable:
                return String(localized: "本のページ数を読めませんでした")
            case .tokenUnavailable, .unsupportedByServer:
                return String(localized: "トークンを発行できませんでした")
            case .referenceNotWritten:
                return String(localized: "参照ファイルを書き出せませんでした")
            case .launchFailed(let message):
                return message
            case .libraryLocked:
                return String(localized: "ライブラリのパスワードが変更されました。解錠し直してください。")
            }
        }
    }

    /// ローカルの書庫の本。127.0.0.1 の口で使えるトークンを手元で出す（HTTP を通さない・spec §5.2）。
    /// グラントに結び付けない（`issuedByGrantID` は nil）。本人の Mac の中だけの口なので。
    func openLocal(book: BookRow, libraryUUID: String, lockCredential: () -> String?, verifiedLockHash: () -> String?,
                   startPage: Int,
                   direction: PageDirection, settings: ViewerSettings) async -> Failure? {
        guard isLocalEndpointRunning() else { return .localEndpointNotRunning }
        guard let path = book.path, !path.isEmpty else { return .pageCountUnavailable }
        let pageCount: Int
        do {
            pageCount = try await BookContentFactory.make(for: book).pageCount
        } catch {
            return .pageCountUnavailable
        }
        guard pageCount > 0 else { return .pageCountUnavailable }
        // G25d: ロックの値は発行の直前に読み、「このウィンドウが検証したハッシュ」と一致するときだけ結び付ける
        // （ページ数の待ちの間に外部から施錠・変更されうる）。有って違うなら発行しない。
        let lock = lockCredential()
        if let lock, lock != verifiedLockHash() { return .libraryLocked }
        let issued = tokens.issue(libraryUUID: libraryUUID, bookID: book.id, issuer: .localEndpoint,
                                  lockCredential: lock, now: now())
        // ポートは参照ファイルを組む直前に読む（口がポート競合で取り直していても、その時点の値を使う。
        // `isLocalEndpointRunning` はバインド前から true なので、取り直しの最中に開くと古いポートを指しうる。
        // その場合は開き直せば直る＝許容）。
        guard let base = URL(string: "http://127.0.0.1:\(localPort())/") else { return .referenceNotWritten }
        let reference = BookReference(
            title: book.title,
            book: BookReference.bookURL(serverBase: base, libraryUUID: libraryUUID, bookID: book.id),
            token: issued.token,
            expiresAt: issued.record.expiresAt,
            pageCount: pageCount,
            direction: BookReference.directionString(direction),
            startPage: BookReference.clampedStartPage(startPage, pageCount: pageCount))
        return hand(reference, origin: .local, libraryUUID: libraryUUID, bookID: book.id,
                    category: HelperLauncher.referenceCategory(bookPath: path), settings: settings)
    }

    /// リモートの本。サーバに `POST …/viewer-token` で出してもらう（`issue`）。
    /// 基点は、このクライアントがサーバへ繋いでいる URL（ビューアは同じ Mac で動くので同じ道で届く）。
    /// `startPage` は呼び出し側が解決した続きのページ（内蔵と同じ `resolveResumePage`）。ここで範囲に収める。
    func openRemote(book: BookListItemDTO, manifest: ManifestDTO, serverID: UUID, serverBase: URL,
                    libraryUUID: String, startPage: Int, settings: ViewerSettings,
                    issue: () async throws -> ViewerTokenReply) async -> Failure? {
        let reply: ViewerTokenReply
        do {
            reply = try await issue()
        } catch RemoteClientError.notFound {
            return .unsupportedByServer
        } catch RemoteClientError.server(501) {
            return .unsupportedByServer
        } catch RemoteClientError.libraryLocked {
            // 施錠ゲートの 403（パスワード変更など）。呼び出し側は解錠へ戻し、何も開かない。
            return .libraryLocked
        } catch {
            return .tokenUnavailable
        }
        let reference = BookReference(
            title: book.title,
            book: BookReference.bookURL(serverBase: serverBase, libraryUUID: libraryUUID, bookID: book.id),
            token: reply.token,
            expiresAt: reply.expiresAt,
            pageCount: manifest.pageCount,
            direction: manifest.direction,
            startPage: BookReference.clampedStartPage(startPage, pageCount: manifest.pageCount))
        // リモートのフォルダの本は filename に拡張子が無いので、種類は manifest の format から決める。
        return hand(reference, origin: .remote(serverID: serverID), libraryUUID: libraryUUID, bookID: book.id,
                    category: HelperLauncher.referenceCategory(manifestFormat: manifest.format), settings: settings)
    }

    private func hand(_ reference: BookReference, origin: BookReferenceStore.Origin, libraryUUID: String,
                      bookID: Int, category: BookCategory, settings: ViewerSettings) -> Failure? {
        let url: URL
        do {
            url = try references.write(reference, origin: origin, libraryUUID: libraryUUID, bookID: bookID)
        } catch {
            return .referenceNotWritten
        }
        if let error = HelperLauncher.openReference(url, category: category, settings: settings) {
            return .launchFailed(error.localizedDescription)
        }
        return nil
    }
}
