import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater — owns the `SPUStandardUpdaterController` and
/// exposes just what the menu bar / Settings need. Also acts as the user-driver delegate so that,
/// for this LSUIElement (accessory) app, Sparkle's update window/alert is brought to the front
/// instead of opening behind other apps. Instantiated once in main.swift alongside the other
/// global singletons (settings, switcher).
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    // MARK: SPUStandardUserDriverDelegate — bring the accessory app forward for update UI.
    // Jay has no Dock icon (LSUIElement), so Sparkle's window/alert can open BEHIND other apps and
    // never focus. Become a regular app + activate while update UI is showing, then revert to
    // accessory when the session finishes.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
    }
}
