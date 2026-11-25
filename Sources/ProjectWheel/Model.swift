import Foundation
import SwiftUI

enum SessionStatus: Int {
    case needsPermission = 0  // blocked on an approval
    case waiting = 1          // turn finished, your move
    case failed = 2           // turn ended on an API error
    case running = 3          // working on its own
    case background = 4       // turn ended, but its background tasks (workflow, shells) still run
    case free = 5             // free project: windows only, no session behind it

    var needsYou: Bool { self != .running && self != .background && self != .free }

    var label: String {
        switch self {
        case .needsPermission: return "Permission demandée"
        case .waiting: return "À toi"
        case .failed: return "Erreur"
        case .running: return "Tourne"
        case .background: return "Tourne en fond"
        case .free: return "Projet libre"
        }
    }

    var color: Color {
        switch self {
        case .needsPermission: return .red
        case .waiting: return .orange
        case .failed: return .purple
        case .running: return .green
        case .background: return .mint
        case .free: return .gray
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
    var registered = false      // present in its machine's session registry
    var registryHost = ""
    var bridgeId = ""           // remote-control session id ("session_…"), if any
    var title: String = ""
    var isFree = false          // created by hand in the menu; id is "free:<uuid>"
    var customName = ""         // user-chosen display name, if any

    var projectName: String {
        if !customName.isEmpty { return customName }
        // Windows hosts report paths with backslashes.
        let name = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return name.isEmpty ? "?" : name
    }

    /// What attached windows hang on. Not keyed on the host name: hook events
    /// and the registry spell the same host differently.
    var projectKey: String { isFree ? id : (isLocal ? "local:" : "remote:") + cwd }

    /// Stable per-project hue so a project always has the same colour.
    var projectColor: Color {
        var h: UInt32 = 2166136261
        for b in (isFree ? id : host + cwd).utf8 { h = (h ^ UInt32(b)) &* 16777619 }
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
            return status == .background ? "⏳ tâches de fond en cours · " + text : text
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

    /// Everything the list and the wheel show: sessions first (those that need
    /// you on top), then free projects, with user-chosen names applied.
    var sorted: [SessionInfo] {
        let live = sessions.values.sorted {
            if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
            return $0.statusSince > $1.statusSince
        }.map { s -> SessionInfo in
            var s = s
            s.customName = names[s.projectKey] ?? ""
            return s
        }
        let free = freeProjects.map { p -> SessionInfo in
            var s = SessionInfo(id: p.id, host: "", isLocal: true)
            s.isFree = true
            s.customName = p.name
            s.status = .free
            s.statusSince = .distantPast
            return s
        }
        return live + free
    }

    // MARK: Free projects and custom names (~/.project-wheel/projects.json)

    struct FreeProject: Codable { var id: String; var name: String }
    private struct ProjectsFile: Codable { var free: [FreeProject] = []; var names: [String: String] = [:] }

    @Published private(set) var freeProjects: [FreeProject] = []
    @Published private(set) var names: [String: String] = [:]  // projectKey -> display name
    private static var projectsURL: URL { AppConfig.dir.appendingPathComponent("projects.json") }

    init() {
        if let data = try? Data(contentsOf: Self.projectsURL),
           let f = try? JSONDecoder().decode(ProjectsFile.self, from: data) {
            freeProjects = f.free
            names = f.names
        }
    }

    private func saveProjects() {
        try? FileManager.default.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ProjectsFile(free: freeProjects, names: names)) {
            try? data.write(to: Self.projectsURL, options: .atomic)
        }
    }

    func addFreeProject(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        freeProjects.append(FreeProject(id: "free:" + UUID().uuidString, name: name))
        saveProjects()
    }

    /// Free projects stay separate from session projects even when a session
    /// later starts under the same name. An empty name restores a session
    /// project's folder name and leaves a free project unchanged.
    func rename(_ s: SessionInfo, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isFree {
            guard !name.isEmpty, let i = freeProjects.firstIndex(where: { $0.id == s.id }) else { return }
            freeProjects[i].name = name
        } else {
            names[s.projectKey] = name.isEmpty ? nil : name
        }
        saveProjects()
    }

    /// Its windows are detached, not closed.
    func deleteFreeProject(_ s: SessionInfo) {
        freeProjects.removeAll { $0.id == s.id }
        saveProjects()
        WindowManager.shared.detachAll(project: s.projectKey)
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
            // With background tasks still running, Claude is not waiting for you:
            // it will be woken up when they finish.
            s.backgroundTasks = (payload["bg"] as? Int) ?? 0
            set(s.backgroundTasks > 0 ? .background : .waiting)
        case "StopFailure":
            set(.failed)
        default:
            break
        }
        sessions[sid] = s
    }

    // MARK: Session registry (~/.claude/sessions/<pid>.json, undocumented)

    /// The registry tells us which sessions exist, their launch directory, tmux
    /// pane, remote-control id, and a coarse status that covers the transitions
    /// hooks miss. Local entries are read from disk; remote ones arrive through
    /// the SSH follower as a full snapshot per cycle.
    func refreshLocalRegistry() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let entries: [[String: Any]] = files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, kill(Int32(pid), 0) == 0 else { return nil }
            return o
        }
        applyRegistry(entries, host: Self.localHost, isLocal: true)
    }

    static let localHost = "local"

    func applyRegistry(_ entries: [[String: Any]], host: String, isLocal: Bool) {
        var alive = Set<String>()
        for o in entries {
            guard let sid = o["sessionId"] as? String,
                  (o["kind"] as? String ?? "interactive") == "interactive" else { continue }
            alive.insert(sid)
            var s = sessions[sid] ?? SessionInfo(id: sid, host: host, isLocal: isLocal)
            s.registered = true
            s.registryHost = host
            if isLocal { s.pid = Int32((o["pid"] as? Int) ?? 0) }
            // The launch directory identifies the project; hook cwd can drift with `cd`.
            if let cwd = o["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
            if let t = o["tmux"] as? String, let pane = t.split(separator: ".").last { s.tmuxPane = String(pane) }
            if s.title.isEmpty { s.title = (o["name"] as? String) ?? "" }
            s.bridgeId = (o["bridgeSessionId"] as? String) ?? ""
            // Registry status: "busy", "idle", "waiting" (blocked on a permission),
            // or "shell" (turn ended, background tasks still running).
            let regStatus: SessionStatus
            switch o["status"] as? String {
            case "busy": regStatus = .running
            case "shell": regStatus = .background
            case "waiting": regStatus = .needsPermission
            default: regStatus = .waiting
            }
            let since = Date(timeIntervalSince1970: ((o["statusUpdatedAt"] as? Double) ?? 0) / 1000)
            if !s.hasHookEvents {
                if s.status != regStatus || s.statusSince != since { s.status = regStatus; s.statusSince = since }
            } else if since.timeIntervalSince(s.lastEventAt) > 1.5, regStatus != s.status,
                      !(s.status == .failed && regStatus == .waiting) {
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
            if s.registered && s.registryHost == host && !alive.contains(sid) {
                sessions[sid] = nil  // gone without a SessionEnd
            } else if !s.registered && now.timeIntervalSince(s.lastEventAt) > staleAfter {
                sessions[sid] = nil
            }
        }
    }

    /// One line from a remote follower: a journal event, a registry entry, or
    /// the marker that ends a registry snapshot.
    private var pendingRegistry: [String: [[String: Any]]] = [:]

    func applyRemote(line: String, host: String) {
        if line == "PW_REG_END" {
            applyRegistry(pendingRegistry[host] ?? [], host: host, isLocal: false)
            pendingRegistry[host] = []
            return
        }
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if o["payload"] != nil {
            apply(line: line, isLocal: false)
        } else if o["sessionId"] != nil {
            pendingRegistry[host, default: []].append(o)
        }
    }

    static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 400 ? String(flat.prefix(400)) + "…" : flat
    }
}
