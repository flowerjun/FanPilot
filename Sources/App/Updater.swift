import AppKit
import CryptoKit
import SwiftUI

/// Checks GitHub for a newer release and installs it in place.
///
/// The app is ad-hoc signed, so a DMG downloaded in a browser is quarantined and Gatekeeper asks
/// for "Open Anyway" again on every version. A file the app downloads itself carries no
/// quarantine flag, so an update installed from here just opens. The DMG is checked against the
/// SHA-256 GitHub publishes for the asset before anything is installed.
///
/// Cost: one small HTTPS request at launch and once a day; nothing runs in between.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let dmg: URL
        let sha256: String
        let page: URL
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, working(String), failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var latest: Release?
    @Published var autoCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck"); schedule() }
    }

    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    /// Overridable for testing an update against a local feed (a file:// URL to a release JSON).
    private static let feed = URL(string: ProcessInfo.processInfo.environment["FANPILOT_UPDATE_FEED"]
                                  ?? "https://api.github.com/repos/flowerjun/FanPilot/releases/latest")!
    private var timer: Timer?

    init() { schedule() }

    var available: Bool { latest.map { Self.isNewer($0.version, than: Self.current) } ?? false }

    /// First check shortly after launch (not during it), then daily.
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard autoCheck else { return }
        let first = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startDaily() }
        }
        first.tolerance = 5
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    private func startDaily() {
        Task { await check(silent: true) }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.check(silent: true) } }
        }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `silent`: background check; failures leave the UI alone.
    func check(silent: Bool = false) async {
        if case .working = phase { return }
        if !silent { phase = .checking }
        do {
            var request = URLRequest(url: Self.feed)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try Self.parse(data)
            latest = release
            phase = Self.isNewer(release.version, than: Self.current) ? .available : (silent ? .idle : .upToDate)
        } catch {
            if !silent { phase = .failed(tr("업데이트 확인 실패: ", "Couldn't check for updates: ") + error.localizedDescription) }
        }
    }

    /// Download → verify → unpack → replace (one admin prompt, which also updates the service) → relaunch.
    func install() async {
        guard let release = latest, available else { return }
        let fm = FileManager.default
        let work = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.flowerjun.fanpilot/update", isDirectory: true)
        let mount = work.appendingPathComponent("mnt")
        do {
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            phase = .working(tr("내려받는 중…", "Downloading…"))
            let (tmp, _) = try await URLSession.shared.download(from: release.dmg)
            let dmg = work.appendingPathComponent("FanPilot.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            phase = .working(tr("확인하는 중…", "Verifying…"))
            let staged = work.appendingPathComponent("FanPilot.app")
            try await Task.detached {
                let digest = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
                guard digest == release.sha256 else {
                    throw DaemonInstaller.err(tr("내려받은 파일이 손상됐습니다 (SHA-256 불일치)", "The download is corrupted (SHA-256 mismatch)"))
                }
                try Self.run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path)
                defer { try? Self.run("/usr/bin/hdiutil", "detach", "-force", mount.path) }
                try Self.run("/usr/bin/ditto", mount.appendingPathComponent("FanPilot.app").path, staged.path)
            }.value

            // Make sure it is really FanPilot at the advertised version before handing it root.
            let info = Bundle(url: staged)?.infoDictionary
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info?["CFBundleShortVersionString"] as? String == release.version else {
                throw DaemonInstaller.err(tr("업데이트 파일이 올바르지 않습니다", "The update isn't a valid FanPilot build"))
            }

            phase = .working(tr("설치하는 중…", "Installing…"))
            try DaemonInstaller.update(to: staged, version: release.version)
            try? fm.removeItem(at: work)
            relaunch()
        } catch {
            try? fm.removeItem(at: work)
            phase = .failed(tr("업데이트 실패: ", "Update failed: ") + error.localizedDescription)
        }
    }

    /// Opens the new copy once this process has exited.
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    nonisolated private static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DaemonInstaller.err("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus))")
        }
    }

    private static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Payload: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard let asset = p.assets.first(where: { $0.name == "FanPilot.dmg" }),
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw DaemonInstaller.err(tr("릴리즈에 확인 가능한 DMG가 없습니다", "The release has no verifiable DMG"))
        }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        return Release(version: version, dmg: asset.browser_download_url, sha256: String(digest.dropFirst(7)), page: p.html_url)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Update row in the General tab; also used as a banner when a new version is out.
struct UpdateSection: View {
    @ObservedObject var updater: Updater
    var banner = false

    var body: some View {
        if banner {
            if updater.available, let v = updater.latest?.version { bannerView(v) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("버전 \(Updater.current)", "Version \(Updater.current)")).foregroundStyle(.secondary)
                    Spacer()
                    if updater.available, let v = updater.latest?.version {
                        Button(tr("\(v)로 업데이트", "Update to \(v)")) { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking)
                    } else {
                        Button(tr("업데이트 확인", "Check for Updates")) { Task { await updater.check() } }
                            .disabled(isWorking || updater.phase == .checking)
                    }
                }
                Toggle(tr("자동으로 업데이트 확인", "Check for updates automatically"), isOn: $updater.autoCheck)
                    .toggleStyle(.switch)
                status
            }
        }
    }

    private var isWorking: Bool { if case .working = updater.phase { return true } else { return false } }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .checking: Text(tr("확인하는 중…", "Checking…")).font(.caption).foregroundStyle(.secondary)
        case .upToDate: Text(tr("최신 버전입니다", "You're up to date")).font(.caption).foregroundStyle(.secondary)
        case .working(let s): Text(s).font(.caption).foregroundStyle(.secondary)
        case .failed(let s): Text(s).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .idle, .available: EmptyView()
        }
    }

    private func bannerView(_ version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("새 버전이 나왔습니다 (\(version))", "Version \(version) is available")).font(.callout.bold())
                if case .working(let s) = updater.phase { Text(s).font(.caption).foregroundStyle(.secondary) }
                if case .failed(let s) = updater.phase { Text(s).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if let page = updater.latest?.page {
                Button(tr("변경 사항", "What's New")) { NSWorkspace.shared.open(page) }.buttonStyle(.borderless)
            }
            Button(tr("업데이트", "Update")) { Task { await updater.install() } }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
        }
        .card()
    }
}
