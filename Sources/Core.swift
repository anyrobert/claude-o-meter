// Claude-O-Meter core — shared between the menu bar app and the floating app.
// Credentials, usage client, metric model, colors, the Claude glyph, and the
// usage panel view.
//
// Data source: GET https://api.anthropic.com/api/oauth/usage (the same endpoint
// Claude Code's /usage screen reads). Unofficial — parsing is deliberately
// tolerant of shape changes, mirroring the claude.ai userscript.

import AppKit
import Security
import SwiftUI

// MARK: - Errors

enum UsageError: Error {
    case noCredentials
    case tokenRejected(Int)
    case rateLimited(retryAfter: Int?)
    case http(Int)
    case badResponse

    var message: String {
        switch self {
        case .noCredentials:
            return "No Claude Code credentials found.\nSign in once with the `claude` CLI."
        case .tokenRejected:
            return "Token expired or rejected.\nUse Claude Code once to refresh it, then hit refresh here."
        case .rateLimited:
            return "Rate limited by the usage API.\nBacking off — will retry automatically."
        case .http(let code):
            return "Usage request failed (HTTP \(code))."
        case .badResponse:
            return "Unrecognized response shape."
        }
    }
}

// MARK: - Metric model

struct Metric: Identifiable {
    enum Kind: Int {
        case session = 0
        case weeklyAll = 1
        case weeklyScoped = 2
        case other = 3
    }

    let id: String
    let kind: Kind
    let label: String
    let percent: Double?
    let resetsAt: Date?

    // Session shows a countdown; weekly windows show the actual reset date.
    var resetsText: String? {
        guard let resetsAt else { return nil }
        switch kind {
        case .session:
            let seconds = resetsAt.timeIntervalSinceNow
            if seconds <= 0 { return "resets shortly" }
            let mins = Int((seconds / 60).rounded())
            let h = mins / 60
            let m = mins % 60
            return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
        default:
            return "resets " + Self.absoluteFormatter.string(from: resetsAt)
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()
}

// MARK: - Credentials (Claude Code Keychain item, with file fallback)

enum Credentials {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
    }

    private struct File: Decodable {
        let claudeAiOauth: OAuth
    }

    static func accessToken() throws -> String {
        // Env override — handy for CLI checks and debugging without a Keychain prompt.
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
            return env
        }
        if let data = keychainItem(service: "Claude Code-credentials") ?? credentialsFile() {
            if let creds = try? JSONDecoder().decode(File.self, from: data) {
                return creds.claudeAiOauth.accessToken
            }
        }
        throw UsageError.noCredentials
    }

    private static func keychainItem(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func credentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }
}

// MARK: - Usage client

enum UsageClient {
    private struct Response: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let displayName: String? }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?
        }
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
        }
        let limits: [Limit]?
        let fiveHour: Window?
        let sevenDay: Window?
    }

    static func fetchMetrics() async throws -> [Metric] {
        let token = try Credentials.accessToken()

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw UsageError.tokenRejected(http.statusCode)
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            throw UsageError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(Response.self, from: data) else {
            throw UsageError.badResponse
        }

        let metrics = buildMetrics(from: parsed)
        guard !metrics.isEmpty else { throw UsageError.badResponse }
        return metrics
    }

    private static func buildMetrics(from response: Response) -> [Metric] {
        var metrics: [Metric] = []

        for (index, limit) in (response.limits ?? []).enumerated() {
            guard let kind = limit.kind, limit.percent != nil else { continue }
            let metric: Metric
            switch kind {
            case "session":
                metric = Metric(id: "session", kind: .session, label: "Current session",
                                percent: limit.percent, resetsAt: parseDate(limit.resetsAt))
            case "weekly_all":
                metric = Metric(id: "weekly_all", kind: .weeklyAll, label: "Weekly (all models)",
                                percent: limit.percent, resetsAt: parseDate(limit.resetsAt))
            default:
                let model = limit.scope?.model?.displayName
                let label = kind.hasPrefix("weekly")
                    ? "Weekly · \(model ?? "scoped")"
                    : (model.map { "\(kind) · \($0)" } ?? kind)
                metric = Metric(id: "\(kind)-\(index)", kind: kind.hasPrefix("weekly") ? .weeklyScoped : .other,
                                label: label, percent: limit.percent, resetsAt: parseDate(limit.resetsAt))
            }
            metrics.append(metric)
        }

        // Fall back to the top-level summary objects the API also returns.
        if metrics.isEmpty {
            if let window = response.fiveHour, let pct = window.utilization {
                metrics.append(Metric(id: "session", kind: .session, label: "Current session",
                                      percent: pct, resetsAt: parseDate(window.resetsAt)))
            }
            if let window = response.sevenDay, let pct = window.utilization {
                metrics.append(Metric(id: "weekly_all", kind: .weeklyAll, label: "Weekly (all models)",
                                      percent: pct, resetsAt: parseDate(window.resetsAt)))
            }
        }

        return metrics.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) {
            return date
        }
        // The API sends microsecond fractions ISO8601DateFormatter can choke on —
        // strip the fraction and retry.
        if let dotRange = string.range(of: #"\.\d+"#, options: .regularExpression) {
            return isoPlain.date(from: string.replacingCharacters(in: dotRange, with: ""))
        }
        return nil
    }
}

// MARK: - Terminal sessions (running `claude` CLI processes)

struct TerminalSession: Identifiable {
    let pid: Int32
    let workingDirectory: String?
    let uptimeSeconds: Int?

    var id: Int32 { pid }

    // "~/projects/my-app" — the session's cwd with the home dir abbreviated.
    var displayPath: String {
        guard let dir = workingDirectory else { return "pid \(pid)" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home { return "~" }
        return dir.hasPrefix(home + "/") ? "~" + dir.dropFirst(home.count) : dir
    }

    var uptimeText: String? {
        guard let s = uptimeSeconds else { return nil }
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

enum TerminalSessions {
    static func snapshot() async -> [TerminalSession] {
        await Task.detached(priority: .utility) { snapshotSync() }.value
    }

    private static func snapshotSync() -> [TerminalSession] {
        // Exact, case-sensitive name match: catches `claude` CLI processes but
        // not the Claude desktop app ("Claude") or ClaudeOMeter itself.
        let pids = run("/usr/bin/pgrep", ["-x", "claude"])
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return [] }
        let pidList = pids.map(String.init).joined(separator: ",")

        var uptimes: [Int32: Int] = [:]
        for line in run("/bin/ps", ["-o", "pid=,etime=", "-p", pidList]).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let pid = Int32(parts[0]) {
                uptimes[pid] = parseEtime(String(parts[1]))
            }
        }

        var cwds: [Int32: String] = [:]
        var currentPid: Int32?
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pidList]).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                currentPid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                cwds[pid] = String(line.dropFirst())
            }
        }

        return pids
            .map { TerminalSession(pid: $0, workingDirectory: cwds[$0], uptimeSeconds: uptimes[$0]) }
            .sorted { ($0.uptimeSeconds ?? 0) > ($1.uptimeSeconds ?? 0) }
    }

    // ps etime format: [[dd-]hh:]mm:ss
    private static func parseEtime(_ value: String) -> Int? {
        var days = 0
        var clock = value
        if let dash = value.firstIndex(of: "-") {
            days = Int(value[..<dash]) ?? 0
            clock = String(value[value.index(after: dash)...])
        }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        for part in parts { seconds = seconds * 60 + part }
        return days * 86400 + seconds
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Ring colors + menu bar ring image

enum Ring {
    static func nsColor(for percent: Double?) -> NSColor {
        guard let percent else { return NSColor(srgbRed: 0.60, green: 0.60, blue: 0.60, alpha: 1) }
        if percent < 60 { return NSColor(srgbRed: 0.298, green: 0.686, blue: 0.490, alpha: 1) }  // #4caf7d
        if percent < 85 { return NSColor(srgbRed: 0.878, green: 0.659, blue: 0.227, alpha: 1) }  // #e0a83a
        return NSColor(srgbRed: 0.878, green: 0.353, blue: 0.306, alpha: 1)                      // #e05a4e
    }

    static func image(percent: Double?, diameter: CGFloat = 16) -> NSImage {
        let fraction = percent.map { min(max($0, 0), 100) / 100.0 }
        let color = nsColor(for: percent)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let lineWidth: CGFloat = 2.5
            let circleRect = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)

            let track = NSBezierPath(ovalIn: circleRect)
            track.lineWidth = lineWidth
            NSColor.gray.withAlphaComponent(0.35).setStroke()
            track.stroke()

            if let fraction, fraction > 0.005 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: NSPoint(x: rect.midX, y: rect.midY),
                    radius: circleRect.width / 2,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false  // keep the color in the menu bar
        return image
    }
}

// MARK: - Claude glyph (the Claude Code mark from the userscript, #D97757)

enum ClaudeGlyph {
    static let color = NSColor(srgbRed: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0, alpha: 1)  // #D97757

    private static let viewBox: CGFloat = 24
    private static let pathData =
        "M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20"
        + "H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z"

    // Parsed once, in SVG coordinates (y-down, 24x24 box).
    private static let svgPath: NSBezierPath = {
        let path = parse(pathData)
        path.windingRule = .evenOdd
        return path
    }()

    // The glyph transformed to fit a y-up rect.
    static func path(in rect: NSRect) -> NSBezierPath {
        let scale = min(rect.width, rect.height) / viewBox
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.maxY)
        transform.scaleX(by: scale, yBy: -scale)
        return transform.transform(svgPath)
    }

    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            path(in: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // Minimal SVG path parser: M/m, L/l, H/h, V/v, Z/z — all this glyph uses.
    private static func parse(_ d: String) -> NSBezierPath {
        var tokens: [(Character, [CGFloat])] = []
        var command: Character?
        var numbers: [CGFloat] = []
        var buffer = ""

        func flushNumber() {
            if !buffer.isEmpty, let value = Double(buffer) {
                numbers.append(CGFloat(value))
            }
            buffer = ""
        }

        for ch in d {
            if ch.isLetter {
                flushNumber()
                if let command { tokens.append((command, numbers)) }
                command = ch
                numbers = []
            } else if ch == "," || ch == " " {
                flushNumber()
            } else if ch == "-" {
                flushNumber()
                buffer = "-"
            } else {
                buffer.append(ch)
            }
        }
        flushNumber()
        if let command { tokens.append((command, numbers)) }

        let path = NSBezierPath()
        var point = CGPoint.zero
        var subpathStart = CGPoint.zero
        for (cmd, args) in tokens {
            switch cmd {
            case "M" where args.count >= 2:
                point = CGPoint(x: args[0], y: args[1])
                path.move(to: point)
                subpathStart = point
            case "m" where args.count >= 2:
                point = CGPoint(x: point.x + args[0], y: point.y + args[1])
                path.move(to: point)
                subpathStart = point
            case "L" where args.count >= 2:
                point = CGPoint(x: args[0], y: args[1])
                path.line(to: point)
            case "l" where args.count >= 2:
                point = CGPoint(x: point.x + args[0], y: point.y + args[1])
                path.line(to: point)
            case "H" where !args.isEmpty:
                point.x = args[0]
                path.line(to: point)
            case "h" where !args.isEmpty:
                point.x += args[0]
                path.line(to: point)
            case "V" where !args.isEmpty:
                point.y = args[0]
                path.line(to: point)
            case "v" where !args.isEmpty:
                point.y += args[0]
                path.line(to: point)
            case "Z", "z":
                path.close()
                point = subpathStart
            default:
                break
            }
        }
        return path
    }
}

// MARK: - Observable model

@MainActor
final class UsageModel: ObservableObject {
    enum Status {
        case loading
        case ok
        case error(String)
    }

    @Published var status: Status = .loading
    @Published var metrics: [Metric] = []
    @Published var sessions: [TerminalSession] = []
    @Published var lastUpdated: Date?
    @Published var isFetching = false

    private var timer: Timer?
    private var backoffUntil: Date?

    init() {
        refresh()
        // 120s: gentle on the (undocumented) usage endpoint's rate limit even
        // with both apps running; a 429 additionally triggers a ≥5min backoff.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // One immediate refresh on wake — the 60s timer doesn't fire during sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isFetching else { return }
        // Sit out the timer ticks while rate-limited; a manual refresh from the
        // panel still goes through (it clears the backoff first via refreshNow).
        if let backoffUntil, backoffUntil > Date() { return }
        isFetching = true
        Task {
            async let sessionSnapshot = TerminalSessions.snapshot()
            do {
                metrics = try await UsageClient.fetchMetrics()
                status = .ok
                lastUpdated = Date()
                backoffUntil = nil
            } catch let error as UsageError {
                status = .error(error.message)
                if case .rateLimited(let retryAfter) = error {
                    let delay = max(Double(retryAfter ?? 0), 300)
                    backoffUntil = Date().addingTimeInterval(delay)
                }
            } catch {
                status = .error("Usage data unavailable.\n\(error.localizedDescription)")
            }
            sessions = await sessionSnapshot  // updates even when the usage fetch fails
            isFetching = false
        }
    }

    // Manual refresh: the user asked, so ignore any pending backoff.
    func refreshNow() {
        backoffUntil = nil
        refresh()
    }

    // Re-scan terminal sessions only — no usage API call, so no rate-limit cost.
    func refreshSessions(afterDelay seconds: Double = 0) {
        Task {
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            sessions = await TerminalSessions.snapshot()
        }
    }

    // SIGTERM lets `claude` exit cleanly (the session stays resumable via
    // `claude --resume`); SIGKILL is for ghosts that ignore SIGTERM.
    func terminate(_ session: TerminalSession, force: Bool) {
        _ = Darwin.kill(session.pid, force ? SIGKILL : SIGTERM)
        refreshSessions(afterDelay: 0.8)  // give the process a moment to die
    }

    var sessionPercent: Double? {
        metrics.first { $0.kind == .session }?.percent
    }

    var hasError: Bool {
        if case .error = status { return true }
        return false
    }

    var menuText: String {
        if hasError { return "!" }
        guard let pct = sessionPercent else { return "–" }
        return "\(Int(pct.rounded()))%"
    }
}

// MARK: - Panel views (shared by both apps)

struct MetricRow: View {
    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(metric.percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: 13, weight: .bold))
            }
            ProgressView(value: min(max((metric.percent ?? 0) / 100, 0), 1))
                .tint(Color(nsColor: Ring.nsColor(for: metric.percent)))
            if let resets = metric.resetsText {
                Text(resets)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: ClaudeGlyph.image(size: 16))
                Text("Claude Usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isFetching {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    model.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isFetching)
                .help("Refresh now")
            }

            switch model.status {
            case .loading:
                Text("Loading usage…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .ok:
                ForEach(Array(model.metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 { Divider() }
                    MetricRow(metric: metric)
                }
            }

            Divider()

            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Claude in terminals")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.sessions.count)")
                    .font(.system(size: 13, weight: .bold))
            }
            if model.sessions.isEmpty {
                Text("No active sessions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.sessions) { session in
                    Menu {
                        Button("Terminate session (pid \(session.pid))") {
                            model.terminate(session, force: false)
                        }
                        Button("Force kill", role: .destructive) {
                            model.terminate(session, force: true)
                        }
                        Divider()
                        Button("Copy PID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(session.pid)", forType: .string)
                        }
                    } label: {
                        HStack {
                            Text(session.displayPath)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let uptime = session.uptimeText {
                                Text(uptime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help("\(session.workingDirectory ?? "unknown directory") — pid \(session.pid) — click for actions")
                }
            }

            Divider()

            HStack {
                if let updated = model.lastUpdated {
                    Text("Updated \(updated, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Details") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                .font(.caption)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .font(.caption)
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 270)
    }
}

// MARK: - CLI check mode

// `<binary> --check` does one fetch, prints the metrics, and exits.
// Used for end-to-end verification and debugging without launching the UI.
func runCheckAndExit() -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let metrics = try await UsageClient.fetchMetrics()
            let iso = ISO8601DateFormatter()
            for metric in metrics {
                let pct = metric.percent.map { "\(Int($0.rounded()))%" } ?? "n/a"
                let resets = metric.resetsAt.map { " (resets \(iso.string(from: $0)))" } ?? ""
                print("\(metric.label): \(pct)\(resets)")
            }
            let sessions = await TerminalSessions.snapshot()
            print("Claude in terminals: \(sessions.count)")
            for session in sessions {
                let uptime = session.uptimeText.map { ", up \($0)" } ?? ""
                print("  \(session.displayPath) (pid \(session.pid)\(uptime))")
            }
            exit(0)
        } catch let error as UsageError {
            print("ERROR: \(error.message.replacingOccurrences(of: "\n", with: " "))")
            exit(1)
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
    semaphore.wait()  // never signaled — the task exits the process
    fatalError("unreachable")
}
