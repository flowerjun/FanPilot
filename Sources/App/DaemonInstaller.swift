import Foundation

/// Installs / updates / removes the root daemon from inside the app via the macOS admin password prompt.
enum DaemonInstaller {
    enum State { case notInstalled, outdated, installed }

    static let installedDaemon = URL(fileURLWithPath: "/usr/local/libexec/fanpilotd")
    static let launchdPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.flowerjun.fanpilot.plist")
    static var bundledDaemon: URL? { Bundle.main.url(forResource: "fanpilotd", withExtension: nil) }
    static var adminScript: URL? { Bundle.main.url(forResource: "fanpilot-admin", withExtension: "sh") }

    static var state: State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: launchdPlist.path), let installed = fm.contents(atPath: installedDaemon.path) else {
            return .notInstalled
        }
        guard let bundled = bundledDaemon.flatMap({ fm.contents(atPath: $0.path) }) else { return .installed }
        return installed == bundled ? .installed : .outdated
    }

    static func install() throws { try runAdmin("install") }
    static func uninstall() throws { try runAdmin("uninstall") }

    private static func runAdmin(_ command: String) throws {
        guard let script = adminScript else { throw err(tr("앱 안에 관리 스크립트가 없습니다", "The admin script is missing from the app")) }
        let prompt = command == "install"
            ? tr("FanPilot 팬 제어 서비스를 설치합니다.", "FanPilot will install its fan control service.")
            : tr("FanPilot 팬 제어 서비스를 제거합니다.", "FanPilot will remove its fan control service.")
        try runAdmin(script: script, [command, Bundle.main.bundlePath, NSUserName()], prompt: prompt)
    }

    /// Installs a downloaded, verified app over this one, using the new version's own script.
    static func update(to newApp: URL, version: String) throws {
        let script = newApp.appendingPathComponent("Contents/Resources/fanpilot-admin.sh")
        try runAdmin(script: script, ["update", newApp.path, NSUserName(), Bundle.main.bundlePath],
                     prompt: tr("FanPilot을 \(version) 버전으로 업데이트합니다.", "FanPilot will update to version \(version)."))
    }

    /// Runs a script as root through the standard macOS admin password prompt.
    private static func runAdmin(script: URL, _ args: [String], prompt: String) throws {
        let shell = "/bin/zsh " + ([script.path] + args).map(shellQuote).joined(separator: " ") + " 2>&1"
        let source = "do shell script \(appleScriptString(shell)) with administrator privileges with prompt \(appleScriptString(prompt))"
        var info: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw err(tr("AppleScript 생성 실패", "Couldn't create AppleScript")) }
        script.executeAndReturnError(&info)
        if let info {
            // -128: user cancelled the password prompt
            if info[NSAppleScript.errorNumber] as? Int == -128 { throw err(tr("취소했습니다", "Cancelled")) }
            throw err(info[NSAppleScript.errorMessage] as? String ?? tr("알 수 없는 오류", "Unknown error"))
        }
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func err(_ msg: String) -> NSError { NSError(domain: "FanPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
}
