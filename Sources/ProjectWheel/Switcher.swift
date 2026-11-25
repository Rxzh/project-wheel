import AppKit
import Foundation

/// Brings the place where a session lives to the front.
enum Switcher {
    static let tmuxPath: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func focus(_ s: SessionInfo) {
        DispatchQueue.global(qos: .userInitiated).async {
            if s.isLocal {
                focusLocal(s)
            } else {
                // Remote sessions are driven from Claude Desktop (remote control).
                open(["-a", "Claude"])
            }
        }
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
