import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide hotkeys with press and release callbacks (Carbon: needs no permission).
/// One application-wide handler dispatches on EventHotKeyID.id.
final class HotKey {
    private static var callbacks: [UInt32: (down: () -> Void, up: () -> Void)] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        Self.installHandler()
        let n = Self.nextID
        Self.nextID += 1
        Self.callbacks[n] = (onDown, onUp)
        let id = EventHotKeyID(signature: 0x5057_484C, id: n)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    /// Carbon hotkeys take a physical key position: find the key that types `char`
    /// on the current layout (on AZERTY, "a" sits where QWERTY has Q).
    static func keyCode(for char: Character, fallback: Int) -> Int {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buf -> Int in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                         OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if err == noErr, len == 1, String(utf16CodeUnits: chars, count: 1) == String(char) { return code }
            }
            return fallback
        }
    }

    /// Installed once: a handler per hotkey would fire every callback for each key.
    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard let cb = HotKey.callbacks[hk.id] else { return }
                pressed ? cb.down() : cb.up()
            }
            return noErr
        }, 2, &specs, nil, nil)
    }
}

final class WheelState: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selected: Int?
    @Published var center: CGPoint = .zero  // in view coordinates (y down)
    /// Set in attach mode: the window that choosing a sector attaches.
    @Published var attaching: CapturedWindow?
}

/// Shows the wheel around the cursor while the hotkey is held; releasing over a
/// sector switches to that project. A quick tap keeps it open until a click.
final class WheelController {
    static let outerRadius: CGFloat = 270
    static let innerRadius: CGFloat = 128
    static let maxSectors = 8

    private let store: Store
    private let state = WheelState()
    private var panel: NSPanel?
    private var tracker: Timer?
    private var hotKeys: [HotKey] = []
    private var origin: CGPoint = .zero  // wheel centre in screen coordinates (y up)
    private var shownAt = Date()
    private var sticky = false

    init(store: Store) {
        self.store = store
        // ⌃⌥Space switches; ⌃⌥A attaches the frontmost window to the chosen project.
        // Both share the hold / aim / release state machine.
        hotKeys.append(HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey,
                              onDown: { [weak self] in self?.keyDown() },
                              onUp: { [weak self] in self?.keyUp() }))
        hotKeys.append(HotKey(keyCode: HotKey.keyCode(for: "a", fallback: kVK_ANSI_A), modifiers: controlKey | optionKey,
                              onDown: { [weak self] in self?.attachKeyDown() },
                              onUp: { [weak self] in self?.keyUp() }))
    }

    private func keyDown() {
        if panel != nil { hide(); return }
        show(sticky: false)
    }

    private func attachKeyDown() {
        if panel != nil { hide(); return }
        // Capture first: whatever is frontmost now is the window the user means.
        guard WindowManager.shared.ensureTrusted() else { return }  // the system dialog explains
        guard !store.sessions.isEmpty, let w = WindowManager.shared.frontmostWindow() else { NSSound.beep(); return }
        show(sticky: false, attaching: w)
    }

    private func keyUp() {
        guard panel != nil, !sticky else { return }
        if state.selected == nil && Date().timeIntervalSince(shownAt) < 0.3 {
            sticky = true  // quick tap: stay open, choose with a click
        } else {
            commit()
        }
    }

    func show(sticky: Bool, attaching: CapturedWindow? = nil) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let f = screen.frame
        let r = Self.outerRadius + 16
        origin = CGPoint(x: min(max(mouse.x, f.minX + r), f.maxX - r), y: min(max(mouse.y, f.minY + r), f.maxY - r))
        state.sessions = Array(store.sorted.prefix(Self.maxSectors))
        state.selected = nil
        state.attaching = attaching
        state.center = CGPoint(x: origin.x - f.minX, y: f.maxY - origin.y)
        self.sticky = sticky
        shownAt = Date()

        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = NSHostingView(rootView: WheelView(state: state, onClick: { [weak self] in self?.commit() }))
        p.setFrame(f, display: true)
        p.orderFrontRegardless()
        panel = p

        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.track() }
    }

    private func track() {
        let m = NSEvent.mouseLocation
        let dx = m.x - origin.x, dy = m.y - origin.y
        let n = state.sessions.count
        var sel: Int?
        if n > 0, hypot(dx, dy) > 36 {
            var a = atan2(dx, dy)  // clockwise from 12 o'clock
            if a < 0 { a += 2 * .pi }
            sel = min(n - 1, Int(a / (2 * .pi / CGFloat(n))))
        }
        if sel != state.selected { state.selected = sel }
    }

    private func commit() {
        if let i = state.selected, state.sessions.indices.contains(i) {
            let s = state.sessions[i]
            if let w = state.attaching {
                // Choosing the project the window already belongs to detaches it.
                let wm = WindowManager.shared
                if wm.project(of: w) == s.projectKey { wm.detach(w) } else { wm.attach(w, to: s.projectKey) }
            } else {
                Switcher.focus(s)
            }
        }
        hide()
    }

    private func hide() {
        tracker?.invalidate()
        tracker = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct WheelView: View {
    @ObservedObject var state: WheelState
    @ObservedObject var windows = WindowManager.shared
    let onClick: () -> Void

    var body: some View {
        let n = state.sessions.count
        ZStack {
            Color.black.opacity(0.25)
            ZStack {
                if n == 0 {
                    Circle().fill(.ultraThinMaterial).frame(width: 2 * WheelController.innerRadius, height: 2 * WheelController.innerRadius)
                    Text("Aucune session active").foregroundStyle(.secondary)
                }
                ForEach(Array(state.sessions.enumerated()), id: \.element.id) { i, s in
                    SectorView(session: s, index: i, count: n, selected: state.selected == i)
                }
                let sel = state.selected.flatMap { state.sessions.indices.contains($0) ? state.sessions[$0] : nil }
                if let w = state.attaching {
                    AttachCard(window: w, current: windows.project(of: w), target: sel)
                } else if let s = sel {
                    ReminderCard(session: s, attached: windows.count(for: s.projectKey))
                } else if n > 0 {
                    let waiting = state.sessions.filter { $0.status.needsYou }.count
                    VStack(spacing: 4) {
                        Text("\(waiting)").font(.system(size: 44, weight: .bold, design: .rounded))
                        Text(waiting == 1 ? "projet t'attend" : "projets t'attendent").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 2 * WheelController.outerRadius, height: 2 * WheelController.outerRadius)
            .position(state.center)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .environment(\.colorScheme, .dark)
    }
}

struct SectorShape: Shape {
    let start: Double, end: Double  // radians, clockwise from 12 o'clock
    let inner: CGFloat, outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a0 = Angle(radians: start - .pi / 2), a1 = Angle(radians: end - .pi / 2)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct SectorView: View {
    let session: SessionInfo
    let index: Int
    let count: Int
    let selected: Bool

    var body: some View {
        let width = 2 * Double.pi / Double(count)
        let gap = count > 1 ? 0.018 : 0
        let start = Double(index) * width + gap, end = Double(index + 1) * width - gap
        let mid = (start + end) / 2
        let outer = WheelController.outerRadius + (selected ? 12 : 0)
        let shape = SectorShape(start: start, end: end, inner: WheelController.innerRadius + 6, outer: outer)
        let labelR = (WheelController.innerRadius + WheelController.outerRadius) / 2 + 4
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(session.projectColor.opacity(selected ? 0.75 : 0.32))
            // Status rim: the thing to read at a glance.
            SectorShape(start: start, end: end, inner: outer - 7, outer: outer)
                .fill(session.status.color.opacity(session.status.needsYou ? 1 : 0.55))
            VStack(spacing: 5) {
                Text(String(session.projectName.prefix(1)).uppercased())
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .frame(width: 46, height: 46)
                    .background(session.projectColor, in: Circle())
                    .foregroundStyle(.black.opacity(0.75))
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: count > 5 ? 96 : 130)
                HStack(spacing: 4) {
                    if !session.isLocal { Image(systemName: "network").font(.system(size: 9)) }
                    Text(session.status.label).font(.system(size: 11))
                }
                .foregroundStyle(session.status.needsYou ? session.status.color : Color.secondary)
            }
            .offset(x: labelR * sin(mid), y: -labelR * cos(mid))
        }
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}

/// Centre of the wheel: what this project was doing and what it wants from you.
struct ReminderCard: View {
    let session: SessionInfo
    let attached: Int

    var body: some View {
        VStack(spacing: 6) {
            Text(session.projectName).font(.system(size: 17, weight: .bold)).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(session.status.color).frame(width: 8, height: 8)
                Text("\(session.status.label) · \(SessionRow.elapsed(since: session.statusSince, now: Date()))")
                    .font(.system(size: 12))
            }
            if !session.isLocal {
                Text(session.host).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !session.reminder.isEmpty {
                Text(session.reminder)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(attached > 0 ? 5 : 6)
            }
            if attached > 0 {
                Label(attached == 1 ? "1 fenêtre rattachée" : "\(attached) fenêtres rattachées", systemImage: "macwindow.on.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 2 * WheelController.innerRadius - 8, height: 2 * WheelController.innerRadius - 8)
        .background(.ultraThinMaterial, in: Circle())
    }
}

/// Centre of the wheel in attach mode: which window is being attached, where it
/// is now, and what releasing over the selected sector will do.
struct AttachCard: View {
    let window: CapturedWindow
    let current: String?  // project key the window belongs to, if any
    let target: SessionInfo?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "macwindow.badge.plus").font(.system(size: 22))
            Text(window.app).font(.system(size: 16, weight: .bold)).lineLimit(1)
            if !window.title.isEmpty {
                Text(window.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text(current.map { "Rattachée à " + Self.name(ofKey: $0) } ?? "Rattachée à aucun projet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Group {
                if let t = target {
                    Text(t.projectKey == current ? "Détacher de \(t.projectName)" : "→ \(t.projectName)")
                } else {
                    Text("Choisis un projet")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
        }
        .padding(18)
        .frame(width: 2 * WheelController.innerRadius - 8, height: 2 * WheelController.innerRadius - 8)
        .background(.ultraThinMaterial, in: Circle())
    }

    /// "local:/Users/x/proj" -> "proj" (same rule as SessionInfo.projectName).
    static func name(ofKey key: String) -> String {
        let path = key.drop(while: { $0 != ":" }).dropFirst()
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "?"
    }
}
