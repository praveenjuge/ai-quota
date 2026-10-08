import AppKit
import Sparkle
import OSLog

/// Sparkle owns verification, staging, replacement and relaunch. This object
/// only maps its lifecycle onto the status menu; it never handles credentials.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    private(set) var title = "Check for updates…"
    private(set) var enabled = true
    var onChange: (() -> Void)?
    private var updater: SPUUpdater!
    private var install: (() -> Void)?
    private var manual = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private let logger = Logger(subsystem: "com.praveenjuge.devbar", category: "updates")

    static var isAvailable: Bool {
        #if DEBUG
        false
        #else
        Bundle.main.bundleURL.pathExtension == "app"
            && !CommandLine.arguments.contains("--dump-usage")
        #endif
    }

    func start() {
        guard Self.isAvailable else { return }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
            updater.updateCheckInterval = 6 * 60 * 60
            updater.sendsSystemProfile = false
            updater.checkForUpdatesInBackground()
        } catch {
            set("Update failed — retry", enabled: true)
            logger.error("Updater startup: \(error.localizedDescription, privacy: .public)")
        }
    }

    func activate() {
        if let install {
            set("Installing update…", enabled: false)
            install()
        } else if updater?.canCheckForUpdates == true {
            manual = true
            set("Checking for updates…", enabled: false)
            // Background mode safely defers authorization until explicit install.
            updater.checkForUpdatesInBackground()
        }
    }

    private func set(_ title: String, enabled: Bool) {
        self.title = title
        self.enabled = enabled
        logger.info("\(title, privacy: .public)")
        onChange?()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        set("Checking for updates…", enabled: false)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        set("Downloading update…", enabled: false)
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        set("Preparing update…", enabled: false)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        install = immediateInstallationBlock
        set("Restart and update", enabled: true)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard install == nil else { return }
        if let error, ((error as NSError).domain != SUSparkleErrorDomain || (error as NSError).code != SUError.noUpdateError.rawValue) {
            logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
            set(manual ? "Update failed — retry" : "Check for updates…", enabled: true)
        } else {
            set(manual ? "You’re up to date" : "Check for updates…", enabled: true)
        }
        manual = false
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        set("Checking for updates…", enabled: false)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Automatic background updates reach this path when authorization is
        // required. Only the explicit menu action may advance to that prompt.
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            set("Update unavailable", enabled: true)
            return
        }
        install = { reply(.install) }
        set(state.stage == .notDownloaded ? "Download update…" : "Install update…", enabled: true)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        set(manual ? "You’re up to date" : "Check for updates…", enabled: true)
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        install = nil
        set(manual ? "Update failed — retry" : "Check for updates…", enabled: true)
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
        set("Downloading update…", enabled: false)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        let percent = min(100, Int(Double(received) / Double(expected) * 100))
        set("Downloading update… \(percent)%", enabled: false)
    }
    func showDownloadDidStartExtractingUpdate() { set("Preparing update…", enabled: false) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        install = { reply(.install) }
        set("Restart and update", enabled: true)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        set("Installing update…", enabled: false)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }
    func dismissUpdateInstallation() {
        install = nil
        // Keep the final result visible until the next check.
    }
}
