import AppKit
import ApplicationServices

/// Private but stable since 10.x: the CGWindowID behind an AX window element.
/// Every window manager (yabai, Hammerspoon, AltTab…) relies on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// Private window-server calls (the ones window switchers rely on): bring one
// window of a process forward by id, even from another Space, where the
// accessibility window list does not show it.
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

/// Appends to ~/.project-wheel/app.log: what was attached, raised or dropped.
func wheelLog(_ message: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
    let url = AppConfig.dir.appendingPathComponent("app.log")
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        if ((try? h.seekToEnd()) ?? 0) > 1_000_000 { try? h.truncate(atOffset: 0) }
        h.write(line.data(using: .utf8)!)
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}

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
        wheelLog("attach \(w.app) #\(w.windowID) pid \(w.pid) -> \(project)")
    }

    func detach(_ w: CapturedWindow) {
        save(windows.filter { !($0.pid == w.pid && $0.windowID == w.windowID) })
    }

    func detachAll(project: String) {
        save(windows.filter { $0.project != project })
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
        wheelLog("focus \(project): \(snapshot.filter { $0.project == project }.count) attached, \(gone.count) gone, hideOthers \(hideOthers)")
        if !gone.isEmpty {
            wheelLog("dropping " + gone.map { "\($0.app) #\($0.windowID)" }.joined(separator: ", "))
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
            var viaAX = Set<CGWindowID>()
            for win in axWindows {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(win, &id) == .success, wanted.contains(id) else { continue }
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                viaAX.insert(id)
            }
            // AX raise orders a window within its app, and only sees windows of
            // the current Space. The window-server call brings each window above
            // the other apps, from any Space. The session comes last anyway.
            var psn = ProcessSerialNumber()
            let havePSN = GetProcessForPID(pid, &psn) == noErr
            for id in wanted {
                let r = havePSN ? _SLPSSetFrontProcessWithOptions(&psn, id, 0x200) : .failure
                wheelLog("raise #\(id) pid \(pid): ax \(viaAX.contains(id)), front \(r == .success)")
            }
            if !havePSN { AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
        }
    }

    // MARK: Layouts (~/.project-wheel/layouts.json)

    /// Position and size in global screen coordinates (origin top-left, as AX uses).
    struct Frame: Codable { var x, y, w, h: Double }

    /// project -> display configuration -> window key -> frame. The window key
    /// is "session" for the session's own window, "pid:windowID" otherwise.
    private var layouts: [String: [String: [String: Frame]]] = {
        guard let data = try? Data(contentsOf: WindowManager.layoutsURL),
              let l = try? JSONDecoder().decode([String: [String: [String: Frame]]].self, from: data) else { return [:] }
        return l
    }()
    private let layoutLock = NSLock()
    private static var layoutsURL: URL { AppConfig.dir.appendingPathComponent("layouts.json") }

    /// Identifies the set of connected screens, so that a layout saved with the
    /// external monitor is not applied on the laptop alone, and vice versa.
    static func displayKey() -> String {
        NSScreen.screens.map { s in
            "\(Int(s.frame.width))x\(Int(s.frame.height))@\(Int(s.frame.minX)),\(Int(s.frame.minY))"
        }.sorted().joined(separator: "|")
    }

    func hasLayout(project: String) -> Bool {
        layoutLock.lock(); defer { layoutLock.unlock() }
        return !(layouts[project]?[Self.displayKey()] ?? [:]).isEmpty
    }

    func forgetLayout(project: String) {
        layoutLock.lock()
        layouts[project]?[Self.displayKey()] = nil
        let copy = layouts
        layoutLock.unlock()
        writeLayouts(copy)
        wheelLog("layout forgotten for \(project)")
    }

    private func writeLayouts(_ l: [String: [String: [String: Frame]]]) {
        if let data = try? JSONEncoder().encode(l) { try? data.write(to: Self.layoutsURL, options: .atomic) }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    /// The project's windows as (key, pid, id): the session window, then the attached ones.
    private func layoutTargets(project: String, session: (pid_t, CGWindowID)?) -> [(String, pid_t, CGWindowID)] {
        var attached: [AttachedWindow] = []
        let read = { attached = self.windows.filter { $0.project == project } }
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
        var targets = attached.map { ("\($0.pid):\($0.windowID)", $0.pid, $0.windowID) }
        if let session { targets.insert(("session", session.0, session.1), at: 0) }
        return targets
    }

    private func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1)
        let wins: [AXUIElement] = Self.attribute(axApp, kAXWindowsAttribute) ?? []
        return wins.first { win in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(win, &wid) == .success && wid == id
        }
    }

    /// Off the main thread. Records where the project's windows are now, for the
    /// current screens. Windows on another Space are invisible to AX and skipped.
    @discardableResult
    func saveLayout(project: String, session: (pid_t, CGWindowID)?) -> Int {
        guard AXIsProcessTrusted() else { return 0 }
        var frames: [String: Frame] = [:]
        for (key, pid, id) in layoutTargets(project: project, session: session) {
            guard let win = axWindow(pid: pid, id: id) else { wheelLog("layout save: #\(id) not visible, skipped"); continue }
            var p: CFTypeRef?, s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            frames[key] = Frame(x: point.x, y: point.y, w: size.width, h: size.height)
        }
        layoutLock.lock()
        layouts[project, default: [:]][Self.displayKey()] = frames
        let copy = layouts
        layoutLock.unlock()
        writeLayouts(copy)
        wheelLog("layout saved for \(project) on \(Self.displayKey()): \(frames.count) windows")
        return frames.count
    }

    /// Off the main thread. Puts the project's windows back where they were saved
    /// for the current screens, if a layout exists.
    func applyLayout(project: String, session: (pid_t, CGWindowID)?) {
        guard AXIsProcessTrusted() else { return }
        layoutLock.lock()
        let frames = layouts[project]?[Self.displayKey()] ?? [:]
        layoutLock.unlock()
        guard !frames.isEmpty else { return }
        var moved = 0
        for (key, pid, id) in layoutTargets(project: project, session: session) {
            guard let f = frames[key], let win = axWindow(pid: pid, id: id) else { continue }
            var point = CGPoint(x: f.x, y: f.y), size = CGSize(width: f.w, height: f.h)
            guard let pv = AXValueCreate(.cgPoint, &point), let sv = AXValueCreate(.cgSize, &size) else { continue }
            // Size, position, size: a move across screens can clamp the first resize.
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
            moved += 1
        }
        wheelLog("layout applied for \(project): \(moved)/\(frames.count) windows")
    }

    /// The window an app currently treats as its main one.
    func mainWindowID(pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(ref as! AXUIElement, &id) == .success && id != 0 ? id : nil
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
