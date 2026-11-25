import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide hotkey with press and release callbacks (Carbon: needs no permission).
final class HotKey {
    static var onDown: (() -> Void)?
    static var onUp: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int) {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { pressed ? HotKey.onDown?() : HotKey.onUp?() }
            return noErr
        }, 2, &specs, nil, nil)
        let id = EventHotKeyID(signature: 0x5057_484C, id: 1)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class WheelState: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selected: Int?
    @Published var center: CGPoint = .zero  // in view coordinates (y down)
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
    private var hotKey: HotKey?
    private var origin: CGPoint = .zero  // wheel centre in screen coordinates (y up)
    private var shownAt = Date()
    private var sticky = false

    init(store: Store) {
        self.store = store
        HotKey.onDown = { [weak self] in self?.keyDown() }
        HotKey.onUp = { [weak self] in self?.keyUp() }
        hotKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey)
    }

    private func keyDown() {
        if panel != nil { hide(); return }
        show(sticky: false)
    }

    private func keyUp() {
        guard panel != nil, !sticky else { return }
        if state.selected == nil && Date().timeIntervalSince(shownAt) < 0.3 {
            sticky = true  // quick tap: stay open, choose with a click
        } else {
            commit()
        }
    }

    func show(sticky: Bool) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let f = screen.frame
        let r = Self.outerRadius + 16
        origin = CGPoint(x: min(max(mouse.x, f.minX + r), f.maxX - r), y: min(max(mouse.y, f.minY + r), f.maxY - r))
        state.sessions = Array(store.sorted.prefix(Self.maxSectors))
        state.selected = nil
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
        if let i = state.selected, state.sessions.indices.contains(i) { Switcher.focus(state.sessions[i]) }
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
                if let i = state.selected, state.sessions.indices.contains(i) {
                    ReminderCard(session: state.sessions[i])
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
                    .lineLimit(6)
            }
        }
        .padding(18)
        .frame(width: 2 * WheelController.innerRadius - 8, height: 2 * WheelController.innerRadius - 8)
        .background(.ultraThinMaterial, in: Circle())
    }
}
