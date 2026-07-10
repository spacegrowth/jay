import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater — owns the `SPUStandardUpdaterController`
/// and exposes just what the menu bar / Settings need. Instantiated once in main.swift
/// alongside the other global singletons (settings, switcher).
final class UpdateController {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
}
