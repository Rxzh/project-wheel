import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var local: LocalJournal!
    private var remotes: [RemoteJournal] = []
    private var timer: Timer?
    private var wheel: WheelController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") { dumpAndExit() }
        if CommandLine.arguments.contains("--print-follow") { print(RemoteJournal.followCommand); exit(0) }
        // Followers of a previous instance that was killed outlive it: reap them,
        // and make sure ours die with us on a signal too.
        let reap = Process()
        reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reap.arguments = ["-f", "^/usr/bin/ssh .*echo PW_CONNECTED"]
        try? reap.run()
        reap.waitUntilExit()
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.remotes.forEach { $0.stop() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        local = LocalJournal { [store] line in store.apply(line: line, isLocal: true) }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }

        wheel = WheelController(store: store)
        if ProcessInfo.processInfo.environment["PW_SHOW_WHEEL"] != nil {  // debug aid
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.wheel?.show(sticky: true) }
        }

        for host in AppConfig.load().remotes {
            store.remoteConnected[host] = false
            let r = RemoteJournal(
                host: host,
                onLine: { [store] line in store.applyRemote(line: line, host: host) },
                onState: { [store] up in store.remoteConnected[host] = up })
            remotes.append(r)
            r.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        remotes.forEach { $0.stop() }
    }

    private func tick() {
        local.poll()
        store.refreshLocalRegistry()
        WindowManager.shared.refreshTrust()
    }

    /// Debug aid: print the state derived from the local journal and registry.
    private func dumpAndExit() -> Never {
        let j = LocalJournal { [store] line in store.apply(line: line, isLocal: true) }
        j.poll()
        store.refreshLocalRegistry()
        for host in AppConfig.load().remotes {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "tail -n 5000 ~/.project-wheel/events.jsonl; " + RemoteJournal.registrySnapshot]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { print("remote \(host): ssh failed"); continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var buf = LineBuffer()
            let lines = buf.feed(data)
            print("remote \(host): exit \(p.terminationStatus), \(lines.count) events")
            for line in lines { store.applyRemote(line: line, host: host) }
        }
        for s in store.sorted {
            print("\(s.status.label)\t\(s.projectName)\t\(s.isFree ? "libre" : (s.isLocal ? "local" : s.host))\tpane=\(s.tmuxPane)\tbridge=\(s.bridgeId.prefix(14))\t\(s.reminder.prefix(70))")
        }
        let wm = WindowManager.shared
        print("accessibility=\(wm.trusted) focusMode=\(wm.focusMode) attached=\(wm.windows.count)")
        for w in wm.windows {
            print("window\t\(w.project)\t\(w.app)\tpid=\(w.pid)\tid=\(w.windowID)\t\(w.title.prefix(60))")
        }
        exit(0)
    }
}

@main
struct ProjectWheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            SessionList(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let n = store.needsYouCount
        Image(systemName: n > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid")
        if n > 0 { Text("\(n)") }
    }
}

struct SessionList: View {
    @ObservedObject var store: Store
    @ObservedObject var windows = WindowManager.shared
    @StateObject private var edit = EditState()

    private func addProject() {
        store.addFreeProject(name: edit.newName)
        edit.newName = ""
        edit.adding = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !windows.trusted {
                // Attaching windows needs it; switching works without.
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Autorise l'accessibilité pour rattacher des fenêtres (⌃⌥A) et le mode focus.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Réglages…") {
                        windows.ensureTrusted()
                        windows.openAccessibilitySettings()
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            if store.sorted.isEmpty {
                Text("Aucune session Claude Code active")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            ForEach(store.sorted) { s in
                SessionRow(session: s, store: store, attached: windows.count(for: s.projectKey), edit: edit)
                Divider()
            }
            // A free project groups windows only (pages, tools), with no session.
            HStack(spacing: 8) {
                if edit.adding {
                    TextField("Nom du nouveau projet", text: $edit.newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addProject() }
                    Button("Créer") { addProject() }
                    Button("Annuler") { edit.adding = false; edit.newName = "" }
                } else {
                    Button { edit.adding = true } label: { Label("Nouveau projet", systemImage: "plus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            HStack(spacing: 10) {
                ForEach(store.remoteConnected.keys.sorted(), id: \.self) { host in
                    let up = store.remoteConnected[host] ?? false
                    Label(host, systemImage: up ? "network" : "network.slash")
                        .font(.caption)
                        .foregroundStyle(up ? Color.secondary : Color.red)
                        .help(up ? "Connecté" : "Injoignable, nouvelle tentative en cours")
                }
                Spacer()
                Toggle("Mode focus", isOn: $windows.focusMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .help("En changeant de projet, masque les apps sans fenêtre rattachée au projet")
                Button("Quitter") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
    }
}

final class HoverState: ObservableObject {
    @Published var on = false
}

/// Which row is being renamed, and the "new project" field. Shared by the list.
final class EditState: ObservableObject {
    @Published var editingKey: String?
    @Published var text = ""
    @Published var adding = false
    @Published var newName = ""
}

struct SessionRow: View {
    let session: SessionInfo
    let store: Store
    let attached: Int
    @ObservedObject var edit: EditState
    // @State is a macro in the macOS 27 SDK and its plugin ships only with Xcode;
    // a StateObject keeps the project buildable with the Command Line Tools alone.
    @StateObject private var hover = HoverState()

    private var editing: Bool { edit.editingKey == session.projectKey }

    var body: some View {
        Group {
            if editing {
                content  // not a button while the name field is open
            } else {
                Button { Switcher.focus(session) } label: { content }
                    .buttonStyle(.plain)
            }
        }
        .onHover { hover.on = $0 }
        .contextMenu {
            Button("Renommer…") { startRename() }
            if !session.isFree && !session.customName.isEmpty {
                Button("Rétablir le nom du dossier") { store.rename(session, to: "") }
            }
            if session.isFree {
                Button("Supprimer le projet") { store.deleteFreeProject(session) }
            }
        }
    }

    private func startRename() {
        edit.text = session.projectName
        edit.editingKey = session.projectKey
    }

    private func commitRename() {
        store.rename(session, to: edit.text)
        edit.editingKey = nil
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(session.projectColor)
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if editing {
                        TextField("Nom du projet", text: $edit.text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitRename() }
                        Button("OK") { commitRename() }
                        Button("Annuler") { edit.editingKey = nil }
                    } else {
                        Text(session.projectName).font(.headline).lineLimit(1)
                        if !session.isLocal {
                            Text(session.host)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        if hover.on {
                            Button { startRename() } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Renommer")
                        }
                        Spacer()
                        Circle().fill(session.status.color).frame(width: 8, height: 8)
                        if session.isFree {
                            Text(session.status.label).font(.caption).foregroundStyle(.secondary)
                        } else {
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                Text("\(session.status.label) · \(Self.elapsed(since: session.statusSince, now: ctx.date))")
                                    .font(.caption)
                                    .foregroundStyle(session.status.needsYou ? Color.primary : Color.secondary)
                            }
                        }
                    }
                }
                if session.isFree {
                    Text(attached == 0 ? "Aucune fenêtre : ⌃⌥A sur une fenêtre pour la rattacher"
                         : (attached == 1 ? "1 fenêtre rattachée" : "\(attached) fenêtres rattachées"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !session.reminder.isEmpty {
                    Text(session.reminder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover.on && !editing ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
    }

    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \((s % 3600) / 60) min" }
        return "\(s / 86400) j"
    }
}
