import Foundation
import SwiftUI

enum SessionStatus: Int {
    case needsPermission = 0  // blocked on an approval
    case waiting = 1          // turn finished, your move
    case failed = 2           // turn ended on an API error
    case running = 3          // working on its own

    var needsYou: Bool { self != .running }

    var label: String {
        switch self {
        case .needsPermission: return "Permission demandée"
        case .waiting: return "À toi"
        case .failed: return "Erreur"
        case .running: return "Tourne"
        }
    }

    var color: Color {
        switch self {
        case .needsPermission: return .red
        case .waiting: return .orange
        case .failed: return .purple
        case .running: return .green
        }
    }
}

struct SessionInfo: Identifiable {
    let id: String
    var host: String
    var isLocal: Bool
    var cwd: String = ""
    var status: SessionStatus = .waiting
    var statusSince: Date = Date()
    var lastEventAt: Date = .distantPast
    var hasHookEvents = false
    var sawPermissionRequest = false
    var lastPrompt: String = ""
    var lastMessage: String = ""
    var permissionTool: String = ""
    var backgroundTasks = 0     // still running when the last turn ended
    var tmuxPane: String = ""   // e.g. "%0"
    var pid: Int32 = 0          // local sessions only (from the registry)
    var title: String = ""

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "?" : name
    }

    /// Stable per-project hue so a project always has the same colour.
    var projectColor: Color {
        var h: UInt32 = 2166136261
        for b in (host + cwd).utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Color(hue: Double(h % 360) / 360.0, saturation: 0.55, brightness: 0.85)
    }

    /// The one line that best reminds you what is pending.
    var reminder: String {
        switch status {
        case .needsPermission:
            return permissionTool.isEmpty ? "Attend une autorisation" : "Veut utiliser : \(permissionTool)"
        case .running:
            return lastPrompt.isEmpty ? lastMessage : "› " + lastPrompt
        default:
            let text = lastMessage.isEmpty ? (lastPrompt.isEmpty ? "" : "› " + lastPrompt) : lastMessage
            return backgroundTasks > 0 ? "⏳ tâches de fond en cours · " + text : text
        }
    }
}

struct AppConfig: Codable {
    var remotes: [String] = []

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".project-wheel")
    static var url: URL { dir.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return cfg
    }
}

final class Store: ObservableObject {
    @Published private(set) var sessions: [String: SessionInfo] = [:]
    @Published var remoteConnected: [String: Bool] = [:]

    /// Sessions with no registry entry (remote, Desktop…) are dropped after this much silence.
    private let staleAfter: TimeInterval = 12 * 3600

    var sorted: [SessionInfo] {
        sessions.values.sorted {
            if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
            return $0.statusSince > $1.statusSince
        }
    }

    var needsYouCount: Int { sessions.values.filter { $0.status.needsYou }.count }

    // MARK: Hook events

    func apply(line: String, isLocal: Bool) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let sid = payload["session_id"] as? String,
              let event = payload["hook_event_name"] as? String else { return }
        let when = Date(timeIntervalSince1970: (obj["ts"] as? Double) ?? Date().timeIntervalSince1970)
        let host = (obj["host"] as? String) ?? "?"

        if event == "SessionEnd" {
            sessions[sid] = nil
            return
        }
        var s = sessions[sid] ?? SessionInfo(id: sid, host: host, isLocal: isLocal)
        guard when >= s.lastEventAt else { return }  // replayed or out-of-order line
        s.lastEventAt = when
        s.hasHookEvents = true
        if let cwd = payload["cwd"] as? String, s.cwd.isEmpty || event == "SessionStart" { s.cwd = cwd }
        if let pane = obj["tmux"] as? String, !pane.isEmpty { s.tmuxPane = pane }
        if let t = payload["session_title"] as? String, !t.isEmpty { s.title = t }

        func set(_ st: SessionStatus) {
            if s.status != st || s.statusSince == .distantPast { s.status = st; s.statusSince = when }
        }
        switch event {
        case "SessionStart":
            // A compaction restarts the session mid-turn: it is still working.
            if (payload["source"] as? String) != "compact" { set(.waiting) }
        case "UserPromptSubmit":
            if let p = payload["prompt"] as? String { s.lastPrompt = Self.oneLine(p) }
            s.backgroundTasks = 0
            set(.running)
        case "PostToolUse":
            set(.running)
        case "PermissionRequest":
            s.permissionTool = (payload["tool_name"] as? String) ?? ""
            s.sawPermissionRequest = true
            set(.needsPermission)
        case "Notification":
            switch payload["notification_type"] as? String {
            // Arrives seconds after PermissionRequest, possibly after the approval:
            // only trust it on versions that never send PermissionRequest.
            case "permission_prompt": if !s.sawPermissionRequest { set(.needsPermission) }
            case "idle_prompt", "agent_needs_input", "elicitation_dialog": if s.status == .running { set(.waiting) }
            default: break
            }
        case "Stop":
            if let m = payload["last_assistant_message"] as? String { s.lastMessage = Self.oneLine(m) }
            s.backgroundTasks = (payload["bg"] as? Int) ?? 0
            set(.waiting)
        case "StopFailure":
            set(.failed)
        default:
            break
        }
        sessions[sid] = s
    }

    // MARK: Local registry (~/.claude/sessions/<pid>.json)

    /// The registry tells us which local sessions are alive, their tmux pane and
    /// pid, and a coarse busy/idle status for sessions that predate the hooks.
    func refreshRegistry() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        var alive = Set<String>()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = o["sessionId"] as? String,
                  let pid = o["pid"] as? Int,
                  (o["kind"] as? String ?? "interactive") == "interactive",
                  kill(Int32(pid), 0) == 0 else { continue }
            alive.insert(sid)
            var s = sessions[sid] ?? SessionInfo(id: sid, host: Host.current().localizedName ?? "local", isLocal: true)
            s.pid = Int32(pid)
            // The launch directory identifies the project; hook cwd can drift with `cd`.
            if let cwd = o["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
            if let t = o["tmux"] as? String, let pane = t.split(separator: ".").last { s.tmuxPane = String(pane) }
            if s.title.isEmpty { s.title = (o["name"] as? String) ?? "" }
            // Registry status: "busy", "idle", or "waiting" (blocked on a permission).
            let reg = o["status"] as? String
            let regStatus: SessionStatus = reg == "busy" ? .running : (reg == "waiting" ? .needsPermission : .waiting)
            let since = Date(timeIntervalSince1970: ((o["statusUpdatedAt"] as? Double) ?? 0) / 1000)
            if !s.hasHookEvents {
                if s.status != regStatus || s.statusSince != since { s.status = regStatus; s.statusSince = since }
            } else if since.timeIntervalSince(s.lastEventAt) > 1.5, (regStatus == .running) != (s.status == .running) {
                // The registry moved after the last hook event. Hooks miss some
                // transitions: Escape fires no Stop, and nothing fires between an
                // approval and the end of a long tool call.
                s.status = regStatus
                s.statusSince = since
            }
            sessions[sid] = s
        }
        let now = Date()
        for (sid, s) in sessions {
            if s.isLocal && s.pid != 0 && !alive.contains(sid) {
                sessions[sid] = nil  // process gone without a SessionEnd
            } else if s.pid == 0 && now.timeIntervalSince(s.lastEventAt) > staleAfter {
                sessions[sid] = nil
            }
        }
    }

    static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 400 ? String(flat.prefix(400)) + "…" : flat
    }
}
