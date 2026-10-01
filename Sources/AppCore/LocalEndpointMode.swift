// SPDX-License-Identifier: MIT
import Foundation

/// G60: この Mac の中だけの口（127.0.0.1）の動き方（spec §5.3）。
public enum LocalEndpointMode: Equatable, Sendable {
    /// 「ローカルコントロールを許可」が ON。CLI／MCP のトークン（全権）と本専用トークンの両方を受け付ける。
    case full
    /// 「ローカルコントロールを許可」が OFF で「StackNest と読書位置を同期する」が ON。
    /// 本専用トークンだけを受け付け、CLI／MCP のトークンも `/local/...` のルートも持たない。
    case viewerTokensOnly

    /// 設定から動き方を決める。nil なら口を起動しない。
    public static func decide(localAutomationEnabled: Bool, viewerSyncEnabled: Bool) -> LocalEndpointMode? {
        if localAutomationEnabled { return .full }
        return viewerSyncEnabled ? .viewerTokensOnly : nil
    }

    /// grant・CLI のトークンを受け付けるか（`LibraryServerConfig.acceptsPrincipalTokens`）。
    public var acceptsPrincipalTokens: Bool { self == .full }

    /// `/local/libraries/...` のルートを生やすか（`LibraryServerConfig.enableLocalLibraryControl`）。
    public var enablesLocalLibraryControl: Bool { self == .full }
}
