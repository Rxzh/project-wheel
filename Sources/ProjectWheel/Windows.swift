import AppKit
import ApplicationServices

/// Private but stable since 10.x: the CGWindowID behind an AX window element.
/// Every window manager (yabai, Hammerspoon, AltTab…) relies on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A window the user attached to a project by hand.
struct AttachedWindow: Codable, Equatable {
    var pid: pid_t
    var windowID: CGWindowID
    var app: String
    var title: String
    var project: String  // SessionInfo.projectKey
}

/// The frontmost window, captured when the attach gesture starts.
struct CapturedWindow {
    let pid: pid_t
    let windowID: CGWindowID
    let app: String
    let title: String
}

/// Manual window attachment and focus mode. Needs the Accessibility permission
/// to read and raise windows; without it, switching behaves as before.
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    /// Read and written on the main thread only (focus() snapshots it from there).
    @Published private(set) var windows: [AttachedWindow] = []
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published var focusMode: Bool {
        didSet { UserDefaults.standard.set(focusMode, forKey: Self.focusModeKey) }
    }

    private static let focusModeKey = "focusMode"
    private var url: URL { AppConfig.dir.appendingPathComponent("windows.json") }
    private var prompted = false

    private init() {
        let d = UserDefaults.standard
        focusMode = d.object(forKey: Self.focusModeKey) == nil ? true : d.bool(forKey: Self.focusModeKey)
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([AttachedWindow].self, from: data) {
            windows = list
        }
    }

    func count(for project: String) -> Int { windows.filter { $0.project == project }.count }

    func project(of w: CapturedWindow) -> String? {
        windows.first { $0.pid == w.pid && $0.windowID == w.windowID }?.project
    }

    // MARK: Permission

    /// Cheap; called on the app's 1 s tick so the popover hint disappears once granted.
    func refreshTrust() {
        let t = AXIsProcessTrusted()
        if t != trusted { trusted = t }
    }

    /// Asks for the permission (system dialog) once per launch; later calls only check.
    /// An ad-hoc signed rebuild loses the grant, hence per launch rather than forever.
    @discardableResult
    func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { refreshTrust(); return true }
        if !prompted {
            prompted = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        refreshTrust()
        return false
    }

    func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Capture and attach

    /// The focused window of the frontmost app, or nil (no permission, no window,
    /// or the frontmost app is Project Wheel itself).
    func frontmostWindow() -> CapturedWindow? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Runs on the main thread from the hotkey: a hung app must not freeze the wheel.
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let win: AXUIElement = Self.attribute(axApp, kAXFocusedWindowAttribute) else { return nil }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(win, &id) == .success, id != 0 else { return nil }
        let title: String = Self.attribute(win, kAXTitleAttribute) ?? ""
        return CapturedWindow(pid: app.processIdentifier, windowID: id, app: app.localizedName ?? "?", title: title)
    }

    /// A window belongs to at most one project; attaching it elsewhere moves it.
    func attach(_ w: CapturedWindow, to project: String) {
        var list = windows.filter { !($0.pid == w.pid && $0.windowID == w.windowID) }
        list.append(AttachedWindow(pid: w.pid, windowID: w.windowID, app: w.app, title: w.title, project: project))
        save(list)
    }

    func detach(_ w: CapturedWindow) {
        save(windows.filter { !($0.pid == w.pid && $0.windowID == w.windowID) })
    }

    private func save(_ list: [AttachedWindow]) {
        windows = list
        try? FileManager.default.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Focus

    /// Off the main thread. Hides the apps outside the project (focus mode), then
    /// raises the project's attached windows. The caller brings the session's own
    /// window forward afterwards so that it ends on top. Does nothing without the
    /// permission (no prompt here: switching must keep working as before).
    func focus(project: String, keepApps: Set<String>) {
        guard AXIsProcessTrusted() else { return }
        var snapshot: [AttachedWindow] = []
        var hideOthers = false
        let read = { snapshot = self.windows; hideOthers = self.focusMode }
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }

        // "Gone" is decided without AX (which also misses windows on other
        // Spaces): the process must live and the window server must still list
        // the window under that pid. A relaunched app or a reboot reuses neither.
        // An empty or failed window list (window server not ready) proves
        // nothing: then only a dead process counts, so attachments survive.
        let owners = Self.windowOwners()
        let gone = snapshot.filter { w in
            kill(w.pid, 0) != 0 || owners.map { $0[w.windowID] != w.pid } ?? false
        }
        if !gone.isEmpty {
            DispatchQueue.main.async {
                self.save(self.windows.filter { w in !gone.contains(w) })
            }
        }
        let mine = snapshot.filter { $0.project == project && !gone.contains($0) }
        let pids = Set(mine.map(\.pid))

        if hideOthers {
            let me = getpid()
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && !app.isHidden
                && app.processIdentifier != me && !pids.contains(app.processIdentifier)
                && !keepApps.contains(app.bundleIdentifier ?? "") {
                app.hide()
            }
        }

        for pid in pids {
            NSRunningApplication(processIdentifier: pid)?.unhide()
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 1)
            let axWindows: [AXUIElement] = Self.attribute(axApp, kAXWindowsAttribute) ?? []
            let wanted = Set(mine.filter { $0.pid == pid }.map(\.windowID))
            var raised = false
            for win in axWindows {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(win, &id) == .success, wanted.contains(id) else { continue }
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                raised = true
            }
            // Raise alone orders the window within its app; bringing the app
            // forward puts it above the others. The session comes last anyway.
            if raised { AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
        }
    }

    /// Window id -> owner pid for every window, including minimized, hidden and
    /// other-Space ones (.optionAll). Needs no permission for ids and pids.
    /// Nil when the list is unavailable or empty.
    private static func windowOwners() -> [CGWindowID: pid_t]? {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              !info.isEmpty else { return nil }
        var map: [CGWindowID: pid_t] = [:]
        for w in info {
            if let id = w[kCGWindowNumber as String] as? Int, let pid = w[kCGWindowOwnerPID as String] as? Int {
                map[CGWindowID(id)] = pid_t(pid)
            }
        }
        return map.isEmpty ? nil : map
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
