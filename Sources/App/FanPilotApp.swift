import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Used by uninstall.sh to remove the login item before the bundle is deleted.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
    }

    var body: some Scene {
        Window("FanPilot", id: "main") {
            ContentView().environmentObject(delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.applyTheme()
        statusBar = StatusBarController(model: model)
    }

    // Closing the settings window (X) keeps the menu bar item alive; only "종료" quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the Dock icon with no window open brings the settings window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// Per-tick readings live in their own object; see LiveState.
    let live = LiveState()
    /// GitHub release check and in-place update (one request at launch and daily).
    let updater = Updater()
    @Published var draft: FanConfig
    @Published var saved: FanConfig
    @Published var message: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var daemonState = DaemonInstaller.state
    /// Menu bar fan tint per mode; a missing entry follows the menu bar text color.
    /// App-only preference, so it lives in UserDefaults rather than the daemon's config.json.
    @Published private(set) var iconColors: [FanMode: NSColor] = [:]
    /// Text in each mode's hex field. A complete 6-digit code is applied as soon as it's typed.
    @Published private(set) var iconHex: [FanMode: String] = [:]
    /// App language (한국어 / English); defaults to the macOS language on first launch.
    @Published var language: AppLanguage = UserDefaults.standard.string(forKey: "language").flatMap(AppLanguage.init) ?? .systemDefault {
        didSet {
            L10n.current = language
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            message = nil   // it was written in the old language
        }
    }
    /// Temperature display unit (default °C). Storage and control stay in °C.
    @Published var tempUnit: TempUnit = UserDefaults.standard.string(forKey: "tempUnit").flatMap(TempUnit.init) ?? .celsius {
        didSet { UserDefaults.standard.set(tempUnit.rawValue, forKey: "tempUnit") }
    }

    /// Binding that shows/edits a °C value in the current unit.
    func tempBinding(_ celsius: Binding<Double>) -> Binding<Double> {
        Binding(get: { self.tempUnit.show(celsius.wrappedValue) }, set: { celsius.wrappedValue = self.tempUnit.store($0) })
    }
    /// Same for a temperature difference (hysteresis).
    func deltaBinding(_ celsius: Binding<Double>) -> Binding<Double> {
        Binding(get: { self.tempUnit.showDelta(celsius.wrappedValue) }, set: { celsius.wrappedValue = self.tempUnit.storeDelta($0) })
    }
    /// Settings tab (remembered between launches).
    @Published var selectedTab: SettingsTab = UserDefaults.standard.string(forKey: "selectedTab").flatMap(SettingsTab.init) ?? .cooling {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: "selectedTab") }
    }
    /// Window appearance: follow the system (default), or force light / dark.
    @Published var theme: AppTheme = UserDefaults.standard.string(forKey: "theme").flatMap(AppTheme.init) ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme"); applyTheme() }
    }
    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    /// Timed CUSTOM/CONSTANT: hand the fan back to macOS after this many minutes (0 = never).
    @Published var autoRestoreMinutes: Int = UserDefaults.standard.integer(forKey: "autoRestoreMinutes") {
        didSet {
            UserDefaults.standard.set(autoRestoreMinutes, forKey: "autoRestoreMinutes")
            var cfg = saved
            stampRevert(&cfg, from: saved, restart: true)
            save(cfg)
        }
    }
    /// High-temperature notification (opt-in, like any notification).
    @Published var heatAlertEnabled = UserDefaults.standard.bool(forKey: "heatAlertEnabled") {
        didSet {
            UserDefaults.standard.set(heatAlertEnabled, forKey: "heatAlertEnabled")
            if heatAlertEnabled { requestNotificationPermission() }
        }
    }
    /// °C at which the alert fires (default 90).
    @Published var heatAlertTemp: Double = UserDefaults.standard.object(forKey: "heatAlertTemp") as? Double ?? 90 {
        didSet { UserDefaults.standard.set(heatAlertTemp, forKey: "heatAlertTemp") }
    }
    /// The user's own curve ("내 설정"), stored apart from the config so presets can't erase it.
    @Published private(set) var myCurve = MyCurve(FanConfig())

    private func storeMyCurve(_ c: FanConfig) {
        myCurve = MyCurve(c)
        if let data = try? JSONEncoder().encode(myCurve) { UserDefaults.standard.set(data, forKey: "myCurve") }
    }

    /// True when the applied config is the user's own curve.
    var isMyCurveActive: Bool { saved.mode == .curve && MyCurve(saved) == myCurve }

    func applyMyCurve() {
        var cfg = saved
        cfg.mode = .curve
        myCurve.apply(to: &cfg)
        stampRevert(&cfg, from: saved, restart: true)
        save(cfg, adoptAll: true)
        message = tr("내 설정 적용", "My settings applied")
    }
    /// One alert per hot episode; re-armed once the temperature drops 5 °C below the threshold.
    private var heatAlerted = false
    private var subscriptions: Set<AnyCancellable> = []
    /// What the menu bar item shows. At least one stays on (enforced in the UI), otherwise
    /// the item would vanish and there'd be nothing to right-click to get back to settings.
    @Published var showIcon = UserDefaults.standard.object(forKey: "showIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showIcon, forKey: "showIcon") }
    }
    @Published var showTemp = UserDefaults.standard.object(forKey: "showTemp") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTemp, forKey: "showTemp") }
    }
    @Published var showRPM = UserDefaults.standard.object(forKey: "showRPM") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRPM, forKey: "showRPM") }
    }
    /// True when `item` is the only thing still shown, so its toggle must stay on.
    func isLastShown(_ item: KeyPath<AppModel, Bool>) -> Bool {
        self[keyPath: item] && [showIcon, showTemp, showRPM].filter { $0 }.count == 1
    }
    /// Spin the menu bar fan at a speed proportional to the real RPM (default on).
    @Published var spinIcon = UserDefaults.standard.object(forKey: "spinIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(spinIcon, forKey: "spinIcon") }
    }
    /// Color the menu bar temperature/RPM text by temperature (default on).
    @Published var tempColoring = UserDefaults.standard.object(forKey: "tempColoring") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tempColoring, forKey: "tempColoring") }
    }
    /// Text color tiers: the hottest tier whose minTemp is reached wins; below all → menu bar default.
    @Published private(set) var tempColorSteps: [TempColorStep] = AppModel.loadTempColorSteps()
    /// Text in each tier's hex field, same index as tempColorSteps.
    @Published private(set) var tempColorHex: [String] = []

    struct TempColorStep {
        var minTemp: Double
        var color: NSColor
    }

    static let defaultTempColorSteps = [
        TempColorStep(minTemp: 50, color: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)),   // #FFD60A yellow
        TempColorStep(minTemp: 70, color: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)),   // #FF9F0A orange
        TempColorStep(minTemp: 80, color: NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)),   // #FF453A red
    ]

    func titleColor(for temp: Double?) -> NSColor? {
        guard tempColoring, let temp else { return nil }
        return tempColorSteps.filter { temp >= $0.minTemp }.max { $0.minTemp < $1.minTemp }?.color
    }

    func setTempColorStep(_ index: Int, minTemp: Double? = nil, color: NSColor? = nil) {
        guard tempColorSteps.indices.contains(index) else { return }
        if let minTemp { tempColorSteps[index].minTemp = minTemp }
        if let color {
            tempColorSteps[index].color = color
            tempColorHex[index] = "#" + Self.hexString(color)
        }
        storeTempColorSteps()
    }

    func setTempColorHex(_ index: Int, _ text: String) {
        guard tempColorHex.indices.contains(index) else { return }
        tempColorHex[index] = text
        guard let color = Self.color(fromHex: text) else { return }
        tempColorSteps[index].color = color
        storeTempColorSteps()
    }

    func resetTempColorSteps() {
        tempColorSteps = Self.defaultTempColorSteps
        tempColorHex = tempColorSteps.map { "#" + Self.hexString($0.color) }
        UserDefaults.standard.removeObject(forKey: "tempColorSteps")
    }

    private static func loadTempColorSteps() -> [TempColorStep] {
        guard let raw = UserDefaults.standard.array(forKey: "tempColorSteps") as? [[Double]] else { return defaultTempColorSteps }
        let steps = raw.compactMap { v in
            v.count == 4 ? TempColorStep(minTemp: v[0], color: NSColor(srgbRed: v[1], green: v[2], blue: v[3], alpha: 1)) : nil
        }
        return steps.count == defaultTempColorSteps.count ? steps : defaultTempColorSteps
    }

    private func storeTempColorSteps() {
        let raw: [[Double]] = tempColorSteps.map { s in
            let c = s.color.usingColorSpace(.sRGB) ?? s.color
            return [s.minTemp, Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        }
        UserDefaults.standard.set(raw, forKey: "tempColorSteps")
    }

    func setIconColor(_ color: NSColor?, for mode: FanMode) {
        iconColors[mode] = color
        iconHex[mode] = color.map { "#" + Self.hexString($0) } ?? ""
        Self.storeColor(color, for: mode)
    }

    func setIconHex(_ text: String, for mode: FanMode) {
        iconHex[mode] = text
        guard let color = Self.color(fromHex: text) else { return }
        iconColors[mode] = color
        Self.storeColor(color, for: mode)
    }

    private func loadIconColors() {
        // Migrate the single curve-only color from the previous version.
        if let old = UserDefaults.standard.array(forKey: "curveIconColor") {
            UserDefaults.standard.set(old, forKey: Self.colorKey(.curve))
            UserDefaults.standard.removeObject(forKey: "curveIconColor")
        }
        for mode in FanMode.allCases {
            guard let c = UserDefaults.standard.array(forKey: Self.colorKey(mode)) as? [Double], c.count == 4 else { continue }
            let color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            iconColors[mode] = color
            iconHex[mode] = "#" + Self.hexString(color)
        }
    }

    private static func colorKey(_ mode: FanMode) -> String { "iconColor.\(mode.rawValue)" }

    private static func storeColor(_ color: NSColor?, for mode: FanMode) {
        guard let c = color?.usingColorSpace(.sRGB) else { UserDefaults.standard.removeObject(forKey: colorKey(mode)); return }
        UserDefaults.standard.set([c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init), forKey: colorKey(mode))
    }

    static func hexString(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    static func color(fromHex text: String) -> NSColor? {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    /// Set by a SwiftUI view so AppKit code (the status item popover) can open the main window.
    var openMainWindow: (() -> Void)?

    /// Opens (or brings back) the settings window from AppKit code: Dock click, popover button.
    /// `openMainWindow` only exists once the window has appeared, and macOS doesn't reopen a
    /// window that was closed at last quit, so it can be nil. Then fall back to the "FanPilot"
    /// item SwiftUI puts in the Window menu for the scene, which opens it the same way.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = openMainWindow { open(); return }
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == "FanPilot", item.action != nil, item.submenu == nil { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        if let item = find(NSApp.mainMenu), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }


    init() {
        let cfg = ConfigStore.load() ?? FanConfig()
        draft = cfg; saved = cfg
        L10n.current = language   // didSet doesn't run for the initial value
        loadIconColors()
        tempColorHex = tempColorSteps.map { "#" + Self.hexString($0.color) }
        UserDefaults.standard.removeObject(forKey: "syncTitleColor")   // replaced by tempColoring
        UserDefaults.standard.removeObject(forKey: "resumeMode")       // replaced by cycleMode
        for key in ["menuBarSectionExpanded", "settingsSectionExpanded"] {   // replaced by tabs
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let data = UserDefaults.standard.data(forKey: "myCurve"), let mc = try? JSONDecoder().decode(MyCurve.self, from: data) {
            myCurve = mc
        } else if cfg.mode == .curve || cfg.steps != FanConfig().steps {
            // First run with this feature: the curve the user already had becomes "my curve".
            storeMyCurve(cfg)
        }

        // Both react to values LiveState already publishes; no extra timers or polling.
        live.$status
            .sink { [weak self] s in if s?.restoredToAuto == true { self?.adoptAutoRestore() } }
            .store(in: &subscriptions)
        live.$readings
            .sink { [weak self] r in self?.checkHeat(r) }
            .store(in: &subscriptions)
    }

    /// revertAt is the daemon's business; editing the curve shouldn't count as a change.
    var dirty: Bool {
        var d = draft
        d.revertAt = saved.revertAt
        return d != saved
    }

    /// Saves `cfg` as the applied config; the draft follows the fields that were saved, while
    /// keeping any unrelated pending edits out of it.
    private func save(_ cfg: FanConfig, adoptAll: Bool = false) {
        do {
            try ConfigStore.save(cfg)
            if adoptAll { draft = cfg } else { draft.mode = cfg.mode; draft.revertAt = cfg.revertAt }
            saved = cfg
        } catch {
            message = tr("저장 실패: ", "Save failed: ") + error.localizedDescription
        }
    }

    /// Sets revertAt for timed modes. A new timer starts when the mode changes (or `restart`);
    /// otherwise an already running one is kept.
    private func stampRevert(_ cfg: inout FanConfig, from previous: FanConfig, restart: Bool = false) {
        if cfg.mode == .system || autoRestoreMinutes == 0 {
            cfg.revertAt = nil
        } else if restart || cfg.mode != previous.mode || previous.revertAt == nil {
            cfg.revertAt = Date().addingTimeInterval(Double(autoRestoreMinutes) * 60)
        } else {
            cfg.revertAt = previous.revertAt
        }
    }

    /// The daemon reached revertAt and is already running AUTO; record that in the config.
    private func adoptAutoRestore() {
        guard saved.mode != .system else { return }
        var cfg = saved
        cfg.mode = .system
        cfg.revertAt = nil
        save(cfg)
        message = tr("시간이 지나 자동 모드로 돌아왔습니다", "Time's up: back to Auto")
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard !granted else { return }
            DispatchQueue.main.async {
                self.message = tr("시스템 설정 → 알림에서 FanPilot 알림을 허용해 주세요", "Allow FanPilot in System Settings → Notifications")
            }
        }
    }

    private func checkHeat(_ r: Readings) {
        guard heatAlertEnabled, let hottest = [r.cpuAverage, r.gpuAverage].compactMap({ $0 }).max() else { return }
        if hottest < heatAlertTemp - 5 { heatAlerted = false }
        guard hottest >= heatAlertTemp, !heatAlerted else { return }
        heatAlerted = true
        let content = UNMutableNotificationContent()
        content.title = tr("FanPilot: 온도가 높습니다", "FanPilot: running hot")
        let shown = tempUnit.text(hottest)
        content.body = tr("현재 \(shown)입니다. 성능이나 익스트림 프리셋으로 바꾸면 더 빨리 식힐 수 있습니다.",
                          "It's \(shown). Switching to Performance or Extreme cools it down faster.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heat", content: content, trigger: nil))
    }

    /// One-click setup: applied and saved immediately.
    func applyQuickSetup(_ setup: QuickSetup) {
        if saved.mode == .curve, activeQuickSetup == nil { storeMyCurve(saved) }
        var cfg = saved
        switch setup {
        case .auto: cfg.mode = .system
        case .constant: cfg.mode = .fixed
        default:
            guard let p = setup.steps(min: fanMin, max: fanMax) else { return }
            cfg.mode = .curve
            cfg.steps = p.steps
            cfg.gpuSteps = p.steps
            cfg.baseRPM = p.base
            cfg.useCPU = true
            cfg.useGPU = true
            cfg.smooth = true
        }
        stampRevert(&cfg, from: saved, restart: true)
        save(cfg, adoptAll: true)
        message = tr("\(setup.title) 적용", "\(setup.title) applied")
    }

    var activeQuickSetup: QuickSetup? { QuickSetup.matching(saved, min: fanMin, max: fanMax) }

    /// Hardware fan limits; constant, so reading them doesn't subscribe to live updates.
    var fanMin: Double { live.readings.fanMin }
    var fanMax: Double { live.readings.fanMax }

    func apply() {
        var cfg = draft
        stampRevert(&cfg, from: saved)
        let lo = fanMin, hi = fanMax
        cfg.steps = cfg.steps.map { CurveStep(minTemp: $0.minTemp, rpm: min(max($0.rpm, lo), hi)) }
        cfg.gpuSteps = cfg.gpuSteps.map { CurveStep(minTemp: $0.minTemp, rpm: min(max($0.rpm, lo), hi)) }
        cfg.baseRPM = min(max(cfg.baseRPM, lo), hi)
        cfg.fixedRPM = min(max(cfg.fixedRPM, lo), hi)
        do {
            try ConfigStore.save(cfg)
            draft = cfg; saved = cfg
            if cfg.mode == .curve, activeQuickSetup == nil { storeMyCurve(cfg) }
            message = tr("적용했습니다", "Applied")
        } catch {
            message = tr("저장 실패: ", "Save failed: ") + error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = tr("자동 실행 설정 실패: ", "Couldn't change login item: ") + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on && SMAppService.mainApp.status == .requiresApproval {
            message = tr("시스템 설정 → 로그인 항목에서 허용해 주세요", "Allow it in System Settings → Login Items")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    var isInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    func installDaemon() {
        do {
            try DaemonInstaller.install()
            message = tr("팬 제어 서비스를 설치했습니다", "Fan control service installed")
            daemonState = DaemonInstaller.state
        } catch {
            message = tr("설치 실패: ", "Install failed: ") + error.localizedDescription
        }
        live.refresh()
    }

    /// "앱 삭제…": asks twice before anything is removed. The second prompt defaults to 취소,
    /// so a stray Return can't confirm it.
    func requestUninstall() {
        let first = NSAlert()
        first.alertStyle = .warning
        first.messageText = tr("FanPilot을 삭제할까요?", "Delete FanPilot?")
        first.informativeText = tr("팬을 macOS 기본 제어로 되돌리고, 팬 제어 서비스·설정·앱을 모두 지운 뒤 종료합니다.", "The fan goes back to macOS control, then the fan service, settings and app are removed and FanPilot quits.")
        first.addButton(withTitle: tr("계속", "Continue"))
        first.addButton(withTitle: tr("취소", "Cancel"))
        guard first.runModal() == .alertFirstButtonReturn else { return }

        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = tr("정말 삭제할까요?", "Are you sure?")
        second.informativeText = tr("이 작업은 되돌릴 수 없습니다. 다시 쓰려면 DMG로 새로 설치해야 합니다.", "This can't be undone. To use FanPilot again, reinstall it from the DMG.")
        second.addButton(withTitle: tr("취소", "Cancel"))                       // default (Return)
        let delete = second.addButton(withTitle: tr("앱 삭제", "Delete App"))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        guard second.runModal() == .alertSecondButtonReturn else { return }
        uninstallEverything()
    }

    /// Hands the fan back to macOS, removes the daemon, settings and this app, then quits.
    func uninstallEverything() {
        try? SMAppService.mainApp.unregister()
        // Clear prefs through cfprefsd; deleting the plist file alone can be undone when the
        // daemon flushes its cached copy on quit.
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        do {
            try DaemonInstaller.uninstall()
            NSApplication.shared.terminate(nil)
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = tr("삭제 실패: ", "Delete failed: ") + error.localizedDescription
        }
    }

    /// Mode name in the current language: 자동 / 커스텀 / 고정, or AUTO / CUSTOM / CONSTANT.
    static func modeName(_ mode: FanMode) -> String {
        switch mode {
        case .system: return tr("자동", "AUTO")
        case .curve: return tr("커스텀", "CUSTOM")
        case .fixed: return tr("고정", "CONSTANT")
        }
    }

    /// Menu bar left-click: AUTO → CUSTOM → CONSTANT → AUTO, using the applied settings.
    func cycleMode() {
        var cfg = saved
        switch cfg.mode {
        case .system: cfg.mode = .curve
        case .curve: cfg.mode = .fixed
        case .fixed: cfg.mode = .system
        }
        stampRevert(&cfg, from: saved)
        save(cfg)
        message = tr("\(Self.modeName(cfg.mode)) 모드로 전환", "Switched to \(Self.modeName(cfg.mode))")
    }

    func resetCurve() {
        let d = FanConfig()
        draft.steps = d.steps; draft.gpuSteps = d.gpuSteps; draft.useCPU = d.useCPU; draft.useGPU = d.useGPU
        draft.baseRPM = d.baseRPM; draft.hysteresis = d.hysteresis; draft.emergencyTemp = d.emergencyTemp
        draft.smooth = d.smooth
    }

    /// Which curve the settings editor shows (UI state only).
    @Published var editingCurve: TempSource = .cpuAverage

    /// The draft steps of the curve being edited.
    var editingSteps: Binding<[CurveStep]> {
        Binding(
            get: { self.editingCurve == .cpuAverage ? self.draft.steps : self.draft.gpuSteps },
            set: { if self.editingCurve == .cpuAverage { self.draft.steps = $0 } else { self.draft.gpuSteps = $0 } }
        )
    }

    /// Binding to one field of one step in the curve being edited.
    func stepField(_ index: Int, _ field: WritableKeyPath<CurveStep, Double>) -> Binding<Double> {
        Binding(
            get: { self.editingSteps.wrappedValue.indices.contains(index) ? self.editingSteps.wrappedValue[index][keyPath: field] : 0 },
            set: { v in
                var steps = self.editingSteps.wrappedValue
                guard steps.indices.contains(index) else { return }
                steps[index][keyPath: field] = v
                self.editingSteps.wrappedValue = steps
            }
        )
    }

    /// Menu bar temperature (CPU/GPU). A display choice, so it's saved immediately like the
    /// other menu bar options instead of waiting for 적용; pending draft edits are kept.
    func setDisplaySource(_ source: TempSource) {
        var cfg = saved
        cfg.source = source
        do {
            try ConfigStore.save(cfg)
            saved = cfg
            draft.source = source
        } catch {
            message = tr("저장 실패: ", "Save failed: ") + error.localizedDescription
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case cooling, appearance, general, history

    var title: String {
        switch self {
        case .cooling: return tr("쿨링", "Cooling")
        case .appearance: return tr("모양", "Appearance")
        case .general: return tr("일반", "General")
        case .history: return tr("모니터", "Monitor")
        }
    }

    var symbol: String {
        switch self {
        case .cooling: return "fan"
        case .appearance: return "paintbrush"
        case .general: return "gearshape"
        case .history: return "gauge.with.dots.needle.50percent"
        }
    }
}

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return tr("시스템", "System")
        case .light: return tr("라이트", "Light")
        case .dark: return tr("다크", "Dark")
        }
    }
}
