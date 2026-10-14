import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var installing = false
    private var installationTask: Task<Void, Never>?
    private var installInvoked = false
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    var isBusy: () -> Bool = { false }

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireManualCheck(updateCheck)
    }
    func requireManualCheck(_ updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates, !isBusy(), !installing else {
            throw NSError(domain: "AppUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose Check for Updates after ongoing operations finish."])
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(installHandler)
        return true
    }
    func postponeInstallation(_ installHandler: @escaping () -> Void) {
        guard installationTask == nil else { return }
        installing = true
        installationTask = Task { @MainActor in
            while isBusy() {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            installInvoked = true
            installHandler()
        }
    }
    func cancelInstallation() {
        installationTask?.cancel()
        installationTask = nil
        installInvoked = false
        installing = false
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { cancelInstallation() }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        if error != nil || !installInvoked { cancelInstallation() }
    }
}

struct UpdateCommands: Commands {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
    }
}
