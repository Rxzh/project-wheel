import AppKit
import Foundation

/// Brings the place where a session lives to the front.
enum Switcher {
    static let tmuxPath: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Serial: two switches in a row must run one after the other, or the
    /// first one's hide/activate steps could land on top of the second.
    private static let queue = DispatchQueue(label: "ProjectWheel.switch", qos: .userInitiated)

    static func focus(_ s: SessionInfo) {
        if s.isFree {
            // A free project is only its windows. With none attached there is
            // nothing to show, and focus mode would hide every app.
            guard WindowManager.shared.count(for: s.projectKey) > 0 else { NSSound.beep(); return }
            queue.async {
                WindowManager.shared.focus(project: s.projectKey, keepApps: [])
                WindowManager.shared.applyLayout(project: s.projectKey, session: nil)
            }
            return
        }
        queue.async {
            // Hide the rest and raise the project's windows first, so the
            // session's own window, brought forward below, ends on top.
            WindowManager.shared.focus(project: s.projectKey, keepApps: keepApps(s))
            if s.isLocal {
                focusLocal(s)
            } else {
                // Remote sessions are driven from Claude Desktop (remote control).
                // Its claude://code/<session id> deep link targets one session;
                // without a remote-control id we can only bring the app forward.
                if s.bridgeId.isEmpty {
                    open(["-a", "Claude"])
                } else {
                    open(["claude://code/" + s.bridgeId])
                    open(["-a", "Claude"])
                }
                Thread.sleep(forTimeInterval: 0.4)  // let Claude come forward first
            }
            WindowManager.shared.applyLayout(project: s.projectKey, session: sessionWindow(s))
        }
    }

    /// Records where the project's windows are now (menu action).
    static func saveLayout(_ s: SessionInfo) {
        queue.async {
            WindowManager.shared.saveLayout(project: s.projectKey, session: s.isFree ? nil : sessionWindow(s))
        }
    }

    /// The window that shows the session: Claude Desktop's main window for a
    /// remote session, the Terminal window holding its tty for a local one.
    private static func sessionWindow(_ s: SessionInfo) -> (pid_t, CGWindowID)? {
        if s.isFree { return nil }
        if !s.isLocal {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first,
                  let id = WindowManager.shared.mainWindowID(pid: app.processIdentifier) else { return nil }
            return (app.processIdentifier, id)
        }
        guard let tty = sessionTTY(s),
              let term = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first
        else { return nil }
        var error: NSDictionary?
        // Terminal's scripting window id is the window-server id.
        let result = NSAppleScript(source: """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then return id of w
                end repeat
            end repeat
            return 0
        end tell
        """)?.executeAndReturnError(&error)
        guard let id = result?.int32Value, id > 0 else { return nil }
        return (term.processIdentifier, CGWindowID(id))
    }

    /// The terminal device showing the session, without changing anything.
    private static func sessionTTY(_ s: SessionInfo) -> String? {
        if !s.tmuxPane.isEmpty, let tmux = tmuxPath {
            let name = run(tmux, ["display-message", "-p", "-t", s.tmuxPane, "#{session_name}"])
            if !name.isEmpty,
               let tty = run(tmux, ["list-clients", "-t", name, "-F", "#{client_tty}"]).split(separator: "\n").first {
                return String(tty)
            }
        }
        if s.pid != 0 {
            let t = run("/bin/ps", ["-o", "tty=", "-p", String(s.pid)])
            if !t.isEmpty, t != "??" { return "/dev/" + t }
        }
        return nil
    }

    /// Apps focus mode must not hide: the one hosting the session. Terminal is
    /// always kept (focusLocal may open it); the real host is found by walking up
    /// the process tree from the session, or from its tmux client, to the first
    /// regular app (iTerm2, Ghostty, VS Code…).
    private static func keepApps(_ s: SessionInfo) -> Set<String> {
        guard s.isLocal else { return [claudeBundleID] }
        var keep: Set<String> = ["com.apple.Terminal"]
        var starts: [pid_t] = s.pid != 0 ? [s.pid] : []
        if !s.tmuxPane.isEmpty, let tmux = tmuxPath {
            // A tmux pane's parent is the tmux server, not the terminal: use the clients.
            let name = run(tmux, ["display-message", "-p", "-t", s.tmuxPane, "#{session_name}"])
            if !name.isEmpty {
                starts += run(tmux, ["list-clients", "-t", name, "-F", "#{client_pid}"])
                    .split(separator: "\n").compactMap { pid_t($0) }
            }
        }
        for start in starts {
            if let id = hostApp(of: start) { keep.insert(id) }
        }
        return keep
    }

    private static func hostApp(of start: pid_t) -> String? {
        var pid = start
        for _ in 0..<32 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app.bundleIdentifier
            }
            guard let parent = pid_t(run("/bin/ps", ["-o", "ppid=", "-p", String(pid)])) else { return nil }
            pid = parent
        }
        return nil
    }

    private static func focusLocal(_ s: SessionInfo) {
        var tty: String?
        if !s.tmuxPane.isEmpty, let tmux = tmuxPath {
            let name = run(tmux, ["display-message", "-p", "-t", s.tmuxPane, "#{session_name}"])
            if !name.isEmpty {
                _ = run(tmux, ["select-window", "-t", s.tmuxPane])
                _ = run(tmux, ["select-pane", "-t", s.tmuxPane])
                tty = run(tmux, ["list-clients", "-t", name, "-F", "#{client_tty}"])
                    .split(separator: "\n").first.map(String.init)
                if tty == nil {
                    // Detached session: attach it in a new Terminal window.
                    appleScript("tell application \"Terminal\"\nactivate\ndo script \"\(tmux) attach -t '\(name)'\"\nend tell")
                    return
                }
            }
        }
        if tty == nil, s.pid != 0 {
            let t = run("/bin/ps", ["-o", "tty=", "-p", String(s.pid)])
            if !t.isEmpty, t != "??" { tty = "/dev/" + t }
        }
        guard let tty else { open(["-a", "Terminal"]); return }
        appleScript("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    private static func appleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("ProjectWheel AppleScript error: %@", error) }
    }

    private static func open(_ args: [String]) { _ = run("/usr/bin/open", args) }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
