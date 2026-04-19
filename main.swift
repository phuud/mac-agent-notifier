import AppKit
import ApplicationServices
import UserNotifications
import Foundation

// AgentNotifier — LSUIElement macOS app that posts UserNotifications and,
// when launched with a Claude PID, exposes an "Allow" button that injects
// "1<CR>" into the terminal window hosting that Claude session.
//
// argv (send mode):
//   argv[1] title
//   argv[2] subtitle
//   argv[3] body
//   argv[4] sound name (e.g. "Glass")
//   argv[5] target bundle ID (click-body → activate this app)
//   argv[6] claude PID (if > 0, notification gets the Allow button)
//
// argv (click relaunch): empty — NSApplication delivers the response via
// UNUserNotificationCenter delegate.

let PERMISSION_CATEGORY = "agent-notifier.permission"

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let args = CommandLine.arguments
    var isSendMode: Bool { args.count > 1 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let category = UNNotificationCategory(
            identifier: PERMISSION_CATEGORY,
            actions: [allow],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard let self = self else { return }
            if self.isSendMode {
                guard granted else { exit(0) }
                DispatchQueue.main.async { self.postNotification() }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { exit(0) }
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        if args.count > 1, !args[1].isEmpty { content.title = args[1] }
        if args.count > 2, !args[2].isEmpty { content.subtitle = args[2] }
        if args.count > 3, !args[3].isEmpty { content.body = args[3] }
        if args.count > 4, !args[4].isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(args[4]))
        } else {
            content.sound = .default
        }

        var userInfo: [String: Any] = [:]
        if args.count > 5, !args[5].isEmpty {
            userInfo["targetBundleID"] = args[5]
        }
        if args.count > 6, let pid = Int(args[6]), pid > 0 {
            userInfo["claudePID"] = pid
            content.categoryIdentifier = PERMISSION_CATEGORY
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let bundleID = (info["targetBundleID"] as? String) ?? ""
        let claudePID = (info["claudePID"] as? Int) ?? 0

        switch response.actionIdentifier {
        case "allow":
            injectAnswer("1", claudePID: claudePID, fallbackBundle: bundleID)
        default:
            activate(bundleID: bundleID)
        }
        completion()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    private func activate(bundleID: String) {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    private func injectAnswer(_ char: String, claudePID: Int, fallbackBundle: String) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        var targetPID: pid_t = 0

        if claudePID > 0, let found = findTerminalAncestorWithWindows(startPID: pid_t(claudePID)) {
            targetPID = found
            raiseWindow(forPID: found)
        } else if !fallbackBundle.isEmpty,
                  let fallbackApp = NSRunningApplication.runningApplications(withBundleIdentifier: fallbackBundle).first {
            targetPID = fallbackApp.processIdentifier
            fallbackApp.activate(options: [.activateIgnoringOtherApps])
        } else {
            return
        }

        usleep(300_000)
        sendString(char)
        sendReturn()

        usleep(200_000)
        if let prev = previousApp, prev.processIdentifier != targetPID {
            prev.activate(options: [])
        }
    }

    private func findTerminalAncestorWithWindows(startPID: pid_t) -> pid_t? {
        var pid = startPID
        var hops = 0
        while pid > 1, hops < 25 {
            if looksLikeTerminalProcess(pid: pid) && hasAXWindows(pid: pid) {
                return pid
            }
            guard let parent = ppidOf(pid), parent != pid else { break }
            pid = parent
            hops += 1
        }
        return nil
    }

    private func looksLikeTerminalProcess(pid: pid_t) -> Bool {
        let comm = processComm(pid)
        let leaf = comm.components(separatedBy: "/").last ?? comm
        for needle in ["Cursor", "iTerm2", "iTermServer", "ghostty", "Ghostty",
                       "Terminal", "Code", "Visual Studio Code"] {
            if leaf.hasPrefix(needle) { return true }
        }
        return false
    }

    private func hasAXWindows(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return false }
        return !windows.isEmpty
    }

    private func raiseWindow(forPID pid: pid_t) {
        if let nsApp = NSRunningApplication(processIdentifier: pid) {
            nsApp.activate(options: [.activateIgnoringOtherApps])
        }
        let axApp = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard let windows = value as? [AXUIElement], let first = windows.first else { return }
        AXUIElementPerformAction(first, kAXRaiseAction as CFString)
    }

    private func runPS(_ arguments: [String]) -> String {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func processComm(_ pid: pid_t) -> String {
        return runPS(["-o", "comm=", "-p", String(pid)])
    }

    private func ppidOf(_ pid: pid_t) -> pid_t? {
        let raw = runPS(["-o", "ppid=", "-p", String(pid)])
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Int32(trimmed) else { return nil }
        return pid_t(value)
    }

    private func sendString(_ str: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        let utf16 = Array(str.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func sendReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let kVK_Return: CGKeyCode = 0x24
        CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
