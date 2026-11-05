import Foundation

/// In-app language (independent of the macOS language), switchable at runtime.
enum AppLanguage: String, CaseIterable {
    case ko, en

    /// Shown in the language menu, in that language.
    var nativeName: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        }
    }

    /// First launch follows macOS: Korean if it's the preferred language, otherwise English.
    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .ko : .en
    }
}

enum L10n {
    /// Set by AppModel.language; read by `tr` from views, alerts and AppKit code on the main thread.
    nonisolated(unsafe) static var current: AppLanguage = .ko
}

/// Korean / English pair, picked by the current app language. Strings live next to where
/// they're used, so the two versions can't drift apart.
func tr(_ ko: String, _ en: String) -> String {
    L10n.current == .en ? en : ko
}

/// The daemon reports problems as codes (it has no idea which language the app shows);
/// this turns them into text. Format: "code" or "code:detail".
func localizedDaemonError(_ raw: String) -> String {
    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
    let detail = parts.count > 1 ? parts[1] : ""
    switch parts[0] {
    case "config_parse": return tr("config.json 파싱 실패", "Could not parse config.json")
    case "sensor_read": return tr("온도 센서 읽기 실패", "Could not read temperature sensors")
    case "fan_write": return tr("팬 쓰기 실패: ", "Could not set fan speed: ") + detail
    default: return raw   // e.g. text from an older daemon
    }
}

/// Display unit for temperatures. Everything is stored and controlled in °C (config.json, the
/// daemon); this only converts what the UI shows and what the user types.
enum TempUnit: String, CaseIterable {
    case celsius, fahrenheit

    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// °C → shown value (rounded to 0.1 so stored round-trips don't show 211.99).
    func show(_ c: Double) -> Double {
        self == .celsius ? c : ((c * 9 / 5 + 32) * 10).rounded() / 10
    }
    /// Typed value → °C.
    func store(_ v: Double) -> Double {
        self == .celsius ? v : ((v - 32) * 5 / 9 * 100).rounded() / 100
    }
    /// Temperature differences (hysteresis) scale but don't shift: 3 °C = 5.4 °F.
    func showDelta(_ c: Double) -> Double { self == .celsius ? c : (c * 9 / 5 * 10).rounded() / 10 }
    func storeDelta(_ v: Double) -> Double { self == .celsius ? v : (v * 5 / 9 * 100).rounded() / 100 }
}

extension TempUnit {
    /// "38.2°C", "101°F", "38°" — the one place temperatures become text.
    func text(_ celsius: Double?, decimals: Int = 0, symbol showSymbol: Bool = true) -> String {
        guard let c = celsius else { return "--" }
        let v = show(c)
        let n = decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
        return n + (showSymbol ? symbol : "°")
    }
}
