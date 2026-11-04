import DigUpKit
import Foundation
import Observation

@Observable
final class IntegrationConnectionModel {
    var configuration: MCPDiagnostics.Configuration?
    var configurationCheckedAt: Date?
    var checkingConfiguration = false
    var test: MCPDiagnostics.TestReport?
    var testedAt: Date?
    var testing = false

    var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup-mcp") }

    func refresh() async {
        guard !checkingConfiguration else { return }
        checkingConfiguration = true
        defer { checkingConfiguration = false }
        let helper = helper
        let value = await Task.detached(priority: .userInitiated) {
            MCPDiagnostics.checkConfiguration(expectedHelper: helper)
        }.value
        guard !Task.isCancelled else { return }
        configuration = value
        configurationCheckedAt = Date()
    }

    func testConnection() async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        let helper = helper
        let value = await Task.detached(priority: .userInitiated) {
            MCPDiagnostics.testLocalServer(helper: helper)
        }.value
        guard !Task.isCancelled else { return }
        test = value
        testedAt = Date()
    }
}
