import Foundation
import Sparkle

@main
struct UpdateSafetyTests {
    @MainActor
    static func main() async throws {
        let gate = AppUpdates()
        try gate.requireManualCheck(.updates)
        do {
            try gate.requireManualCheck(.updatesInBackground)
            preconditionFailure("Background checks must be rejected")
        } catch { }
        var busy = true
        gate.isBusy = { busy }
        do {
            try gate.requireManualCheck(.updates)
            preconditionFailure("Checks during an operation must be rejected")
        } catch { }
        var invoked = false
        gate.postponeInstallation { invoked = true }
        precondition(gate.installing && !invoked)
        await Task.yield()
        precondition(!invoked)
        busy = false
        try await Task.sleep(for: .milliseconds(250))
        precondition(invoked && gate.installing)
        gate.cancelInstallation()
        precondition(!gate.installing)
        busy = true
        invoked = false
        gate.postponeInstallation { invoked = true }
        gate.cancelInstallation()
        busy = false
        try await Task.sleep(for: .milliseconds(200))
        precondition(!invoked && !gate.installing)
        print("PASS: manual-only checks, busy rejection, operation drain, shutdown guard, cancellation")
    }
}
