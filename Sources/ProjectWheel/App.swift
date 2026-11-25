import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var local: LocalJournal!
    private var remotes: [RemoteJournal] = []
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") { dumpAndExit() }
        local = LocalJournal { [store] line in store.apply(line: line, isLocal: true) }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }

        for host in AppConfig.load().remotes {
            store.remoteConnected[host] = false
            let r = RemoteJournal(
                host: host,
                onLine: { [store] line in store.apply(line: line, isLocal: false) },
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
        store.refreshRegistry()
    }

    /// Debug aid: print the state derived from the local journal and registry.
    private func dumpAndExit() -> Never {
        let j = LocalJournal { [store] line in store.apply(line: line, isLocal: true) }
        j.poll()
        store.refreshRegistry()
        for s in store.sorted {
            print("\(s.status.label)\t\(s.projectName)\t\(s.host)\tpane=\(s.tmuxPane)\tpid=\(s.pid)\t\(s.reminder.prefix(80))")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sorted.isEmpty {
                Text("Aucune session Claude Code active")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            ForEach(store.sorted) { s in
                SessionRow(session: s)
                Divider()
            }
            HStack(spacing: 10) {
                ForEach(store.remoteConnected.keys.sorted(), id: \.self) { host in
                    let up = store.remoteConnected[host] ?? false
                    Label(host, systemImage: up ? "network" : "network.slash")
                        .font(.caption)
                        .foregroundStyle(up ? Color.secondary : Color.red)
                        .help(up ? "Connecté" : "Injoignable, nouvelle tentative en cours")
                }
                Spacer()
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

struct SessionRow: View {
    let session: SessionInfo
    // @State is a macro in the macOS 27 SDK and its plugin ships only with Xcode;
    // a StateObject keeps the project buildable with the Command Line Tools alone.
    @StateObject private var hover = HoverState()

    var body: some View {
        Button {
            Switcher.focus(session)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(session.projectColor)
                    .frame(width: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.projectName).font(.headline).lineLimit(1)
                        if !session.isLocal {
                            Text(session.host)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer()
                        Circle().fill(session.status.color).frame(width: 8, height: 8)
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text("\(session.status.label) · \(Self.elapsed(since: session.statusSince, now: ctx.date))")
                                .font(.caption)
                                .foregroundStyle(session.status.needsYou ? Color.primary : Color.secondary)
                        }
                    }
                    if !session.reminder.isEmpty {
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
            .background(hover.on ? Color.primary.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }

    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \((s % 3600) / 60) min" }
        return "\(s / 86400) j"
    }
}
