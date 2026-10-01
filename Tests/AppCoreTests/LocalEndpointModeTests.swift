// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

@Suite("G60: 127.0.0.1 の口の動き方と同期の設定")
struct LocalEndpointModeTests {
    @Test func automationOnIsFullRegardlessOfSync() {
        #expect(LocalEndpointMode.decide(localAutomationEnabled: true, viewerSyncEnabled: false) == .full)
        #expect(LocalEndpointMode.decide(localAutomationEnabled: true, viewerSyncEnabled: true) == .full)
    }

    @Test func syncAloneStartsViewerOnly() {
        #expect(LocalEndpointMode.decide(localAutomationEnabled: false, viewerSyncEnabled: true) == .viewerTokensOnly)
    }

    @Test func bothOffStaysStopped() {
        #expect(LocalEndpointMode.decide(localAutomationEnabled: false, viewerSyncEnabled: false) == nil)
    }

    @Test func viewerOnlyRejectsPrincipalsAndHasNoLocalControlRoutes() {
        #expect(LocalEndpointMode.viewerTokensOnly.acceptsPrincipalTokens == false)
        #expect(LocalEndpointMode.viewerTokensOnly.enablesLocalLibraryControl == false)
        #expect(LocalEndpointMode.full.acceptsPrincipalTokens == true)
        #expect(LocalEndpointMode.full.enablesLocalLibraryControl == true)
    }

    @Test @MainActor func syncSettingDefaultsOffAndPersists() {
        let name = "g60-sync-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        #expect(s.syncsReadingPositionWithExternalViewer == false)
        s.syncsReadingPositionWithExternalViewer = true
        #expect(suite.bool(forKey: "externalViewerSyncsReadingPosition") == true)
        #expect(ViewerSettings(defaults: suite).syncsReadingPositionWithExternalViewer == true)
    }
}
