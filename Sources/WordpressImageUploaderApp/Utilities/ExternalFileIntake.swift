import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ExternalFileIntake {
    static let shared = ExternalFileIntake()

    private(set) var sequence = 0
    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingURLs.append(contentsOf: urls)
        sequence += 1
    }

    func drain() -> [URL] {
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }
}

final class DockFileOpenDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            ExternalFileIntake.shared.enqueue(urls)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            ExternalFileIntake.shared.enqueue([URL(fileURLWithPath: filename)])
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            ExternalFileIntake.shared.enqueue(urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.windows.forEach { $0.tabbingMode = .disallowed }

        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                window.tabbingMode = .disallowed
            }
        }
    }

    deinit {
        if let mainWindowObserver {
            NotificationCenter.default.removeObserver(mainWindowObserver)
        }
    }
}
