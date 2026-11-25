import Foundation

/// Splits a byte stream into complete lines.
struct LineBuffer {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        return lines
    }
}

/// Follows the local journal by polling its size (cheap, and survives truncation).
final class LocalJournal {
    private let url = AppConfig.dir.appendingPathComponent("events.jsonl")
    private var offset: UInt64 = 0
    private var buffer = LineBuffer()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func poll() {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; buffer = LineBuffer() }  // truncated or rotated
        if offset == 0 && size > 2_000_000 { offset = size - 2_000_000 }  // only replay the tail
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        let data = fh.readDataToEndOfFile()
        offset += UInt64(data.count)
        for line in buffer.feed(data) { onLine(line) }
    }
}

/// Follows a remote machine's journal through `ssh host tail -F`, reconnecting forever.
final class RemoteJournal {
    let host: String
    private let onLine: (String) -> Void
    private let onState: (Bool) -> Void
    private var process: Process?
    private var buffer = LineBuffer()
    private var stopped = false

    /// Runs in the remote login shell (bash, including Git Bash on Windows):
    /// streams the journal, and every few seconds a snapshot of the session
    /// registry, one JSON object per line, closed by PW_REG_END.
    static let registrySnapshot =
        "for f in ~/.claude/sessions/*.json; do [ -f \"$f\" ] && cat \"$f\" && echo; done; echo PW_REG_END"
    static let followCommand =
        "echo PW_CONNECTED; mkdir -p ~/.project-wheel; touch ~/.project-wheel/events.jsonl; "
        + "tail -n 5000 -F ~/.project-wheel/events.jsonl & "
        + "while :; do \(registrySnapshot) || exit; sleep 4; done"

    init(host: String, onLine: @escaping (String) -> Void, onState: @escaping (Bool) -> Void) {
        self.host = host
        self.onLine = onLine
        self.onState = onState
    }

    func start() {
        guard !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=2",
            host,
            RemoteJournal.followCommand,
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        buffer = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self, !data.isEmpty else { return }
            DispatchQueue.main.async {
                for line in self.buffer.feed(data) {
                    if line == "PW_CONNECTED" { self.onState(true) } else { self.onLine(line) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.onState(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.start() }
            }
        }
        do { try p.run(); process = p } catch {
            onState(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.start() }
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }
}
