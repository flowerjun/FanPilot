import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// True in the menu bar popover, where an "open as window" button makes sense.
    var inPopover = false
    @StateObject private var layout = LayoutState()

    /// Sized to the content, but never taller than the screen: on small displays the
    /// settings scroll instead of running off the bottom.
    var body: some View {
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - (inPopover ? 40 : 60)
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView(.vertical) {
                content
                    .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(layout.contentHeight, maxHeight - 64))
            .onPreferenceChange(ContentHeightKey.self) { h in
                if abs(h - layout.contentHeight) > 0.5 { layout.contentHeight = h }
            }
        }
        .frame(width: 380)
        .background(NoInitialFocus())
        .onAppear {
            // The main window's environment can open scenes; the AppKit popover's cannot.
            if model.openMainWindow == nil { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        }
    }

    /// Icon tabs across the top, like a macOS settings window.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let selected = model.selectedTab == tab
                Button { model.selectedTab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 17))
                        Text(tab.title).font(.caption)
                    }
                    .frame(width: 70, height: 46)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            readingsSection
            serviceBanner
            Divider()
            switch model.selectedTab {
            case .cooling: coolingTab
            case .appearance: appearanceTab
            case .general: generalTab
            case .history: MonitorView(live: model.live, config: model.saved, unit: model.tempUnit, language: model.language)
            }
            Divider()
            footer
        }
        .controlSize(.small)   // compact fields/buttons; text sizes are set per view and unchanged
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.callout.bold())
    }

    // MARK: Cooling

    /// Shown instead of the cooling controls on Macs without a fan: an explanation, not an error.
    private var fanlessNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("이 Mac에는 팬이 없습니다", "This Mac has no fan"), systemImage: "fanblades.slash")
                .font(.callout.bold())
            Text(tr("MacBook Air처럼 팬이 없는 Mac은 macOS가 성능을 조절해 온도를 관리하므로, 제어할 팬이 없습니다. 이 Mac에서는 FanPilot을 온도·사용률 모니터로 쓸 수 있습니다.",
                    "Fanless Macs such as the MacBook Air manage heat by adjusting performance, so there is no fan to control. FanPilot works here as a temperature and load monitor."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("모니터 보기", "Open Monitor")) { model.selectedTab = .history }
        }
        .card()
    }

    @ViewBuilder private var coolingTab: some View {
        if Hardware.isFanless { fanlessNotice } else { coolingControls }
    }

    private var coolingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(tr("빠른 설정", "Quick setup"))
            quickSetupGrid
            myCurveTile
            Divider()
            sectionTitle(tr("세부 설정", "Details"))
            Picker(tr("모드", "Mode"), selection: $model.draft.mode) {
                Text(AppModel.modeName(.system)).tag(FanMode.system)
                Text(AppModel.modeName(.curve)).tag(FanMode.curve)
                Text(AppModel.modeName(.fixed)).tag(FanMode.fixed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.draft.mode {
            case .system:
                Text(tr("macOS가 팬을 직접 제어합니다.", "macOS controls the fan.")).foregroundStyle(.secondary).font(.callout)
            case .curve:
                curveSection
            case .fixed:
                fixedSection
            }

            if model.draft.mode != .system {
                HStack {
                    Text(tr("비상 온도", "Emergency"))
                    Spacer()
                    NumberField(value: model.tempBinding($model.draft.emergencyTemp), width: 50)
                    Text(tr("\(model.tempUnit.symbol) 이상이면 최대 RPM", "\(model.tempUnit.symbol) and up → max RPM")).foregroundStyle(.secondary)
                }.font(.callout)
            }
            autoRestoreRow
        }
    }

    private var quickSetupGrid: some View {
        let active = model.activeQuickSetup
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(QuickSetup.allCases) { setup in
                let on = setup == active
                Button { model.applyQuickSetup(setup) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: setup.symbol)
                            Text(setup.title).font(.callout.bold()).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        MiniCurve(setup: setup)
                            .stroke(on ? Color.accentColor : Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: setup == .auto ? [3, 2] : []))
                            .frame(height: 18)
                        Text(setup.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .card(selected: on)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Full-width tile under the presets: the user's own setup ("내 설정").
    private var myCurveTile: some View {
        let on = model.isMyCurveActive
        return Button { model.applyMyCurve() } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("내 설정", "My settings")).font(.callout.bold())
                    Text(tr("직접 만든 설정 · 아래 세부 설정에서 편집하고 적용하면 저장됩니다", "Your own setup · edit it in Details below; Apply saves it"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .card(selected: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var autoRestoreRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(tr("자동 모드로 되돌리기", "Back to Auto after"))
                Spacer()
                Picker("", selection: $model.autoRestoreMinutes) {
                    Text(tr("안 함", "Never")).tag(0)
                    Text(tr("15분", "15 min")).tag(15)
                    Text(tr("30분", "30 min")).tag(30)
                    Text(tr("1시간", "1 hour")).tag(60)
                }
                .labelsHidden()
                .fixedSize()
            }
            if let at = model.saved.revertAt, model.saved.mode != .system {
                Text(tr("\(at.formatted(date: .omitted, time: .shortened))에 자동 모드로 돌아갑니다", "Returns to Auto at \(at.formatted(date: .omitted, time: .shortened))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("테마", "Theme")).foregroundStyle(.secondary)
                Picker(tr("테마", "Theme"), selection: $model.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            .font(.callout)
            Divider()
            sectionTitle(tr("메뉴 막대", "Menu bar"))
            iconColorSection
            Divider()
            tempColorSection
        }
    }

    // MARK: General

    /// Login item, language, units, alerts and app removal; all applied immediately.
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("로그인 시 자동 실행", "Open at Login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
            HStack {
                Text(tr("언어", "Language")).foregroundStyle(.secondary)
                Spacer()
                Picker(tr("언어", "Language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text(verbatim: $0.nativeName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text(tr("온도 단위", "Temperature")).foregroundStyle(.secondary)
                Spacer()
                Picker(tr("온도 단위", "Temperature"), selection: $model.tempUnit) {
                    Text(verbatim: "°C").tag(TempUnit.celsius)
                    Text(verbatim: "°F").tag(TempUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            Divider()
            Toggle(tr("고온 알림", "High-temperature alert"), isOn: $model.heatAlertEnabled)
                .toggleStyle(.switch)
            if model.heatAlertEnabled {
                HStack {
                    Text(tr("CPU나 GPU가", "When CPU or GPU reaches")).foregroundStyle(.secondary)
                    NumberField(value: model.tempBinding($model.heatAlertTemp), width: 50)
                    Text(tr("\(model.tempUnit.symbol) 이상이면 알림", model.tempUnit.symbol)).foregroundStyle(.secondary)
                }
                Text(tr("과열 한 번에 한 번만 알리고, 5° 이상 식으면 다시 대기합니다.", "Alerts once per hot spell and re-arms after cooling 5° below."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Settings window only; too easy to hit by accident in the menu bar popover.
            if !inPopover {
                Divider()
                HStack {
                    Spacer()
                    Button(tr("앱 삭제", "Delete App"), role: .destructive) { model.requestUninstall() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.callout)
    }

    /// Menu bar fan color per mode; applied immediately (not via 적용).
    private var iconColorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text(tr("표시", "Show")).foregroundStyle(.secondary)
                Toggle(tr("아이콘", "Icon"), isOn: $model.showIcon).disabled(model.isLastShown(\.showIcon))
                Toggle(tr("온도", "Temp"), isOn: $model.showTemp).disabled(model.isLastShown(\.showTemp))
                if !Hardware.isFanless { Toggle("RPM", isOn: $model.showRPM).disabled(model.isLastShown(\.showRPM)) }
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            HStack {
                Text(tr("표시 온도", "Shown temp")).foregroundStyle(.secondary)
                Picker(tr("표시 온도", "Shown temp"), selection: Binding(get: { model.saved.source }, set: { model.setDisplaySource($0) })) {
                    Text(tr("CPU 평균", "CPU avg")).tag(TempSource.cpuAverage)
                    Text(tr("GPU 평균", "GPU avg")).tag(TempSource.gpuAverage)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            .font(.callout)
            Toggle(tr("회전 애니메이션", "Spin animation"), isOn: $model.spinIcon)
                .toggleStyle(.switch)
                .font(.callout)
                .disabled(!model.showIcon)
            iconColorRow(tr("자동 (빈 팬)", "AUTO (outline)"), .system)
            iconColorRow(AppModel.modeName(.curve), .curve)
            iconColorRow(AppModel.modeName(.fixed), .fixed)
        }
    }

    /// Menu bar temperature/RPM text colored by temperature; applied immediately.
    private var tempColorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(tr("온도에 따라 글자 색 변경", "Color text by temperature"), isOn: $model.tempColoring)
                    .toggleStyle(.switch)
                Spacer()
                if model.tempColoring {
                    Button(tr("기본값으로", "Defaults")) { model.resetTempColorSteps() }
                }
            }
            .font(.callout)
            if model.tempColoring {
                ForEach(model.tempColorSteps.indices, id: \.self) { i in
                    HStack {
                        NumberField(value: model.tempBinding(Binding(
                            get: { model.tempColorSteps[i].minTemp },
                            set: { model.setTempColorStep(i, minTemp: $0) }
                        )), width: 50)
                        Text(tr("\(model.tempUnit.symbol) 이상", "\(model.tempUnit.symbol) and up")).foregroundStyle(.secondary)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: model.tempColorSteps[i].color) },
                            set: { model.setTempColorStep(i, color: NSColor($0)) }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        TextField("#RRGGBB", text: Binding(
                            get: { model.tempColorHex.indices.contains(i) ? model.tempColorHex[i] : "" },
                            set: { model.setTempColorHex(i, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 80)
                    }
                    .font(.callout)
                }
                Text(tr("가장 낮은 단계보다 낮으면 메뉴 막대 기본 글자색", "Below the lowest tier: the menu bar's own text color")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func iconColorRow(_ title: String, _ mode: FanMode) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.iconColors[mode] ?? .labelColor) },
                set: { model.setIconColor(NSColor($0), for: mode) }
            ), supportsOpacity: false)
            .labelsHidden()
            TextField(tr("기본", "Default"), text: Binding(
                get: { model.iconHex[mode] ?? "" },
                set: { model.setIconHex($0, for: mode) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .frame(width: 80)
            Button(tr("기본", "Default")) { model.setIconColor(nil, for: mode) }
                .disabled(model.iconColors[mode] == nil)
        }
        .font(.callout)
    }

    @ViewBuilder private var serviceBanner: some View {
        // Nothing to install on a fanless Mac: the service only exists to drive fans.
        if !Hardware.isFanless { installBanner }
    }

    @ViewBuilder private var installBanner: some View {
        switch model.daemonState {
        case .installed:
            EmptyView()
        case .notInstalled, .outdated:
            let outdated = model.daemonState == .outdated
            VStack(alignment: .leading, spacing: 8) {
                Text(outdated ? tr("팬 제어 서비스 업데이트가 있습니다.", "A fan control service update is available.") : tr("팬을 제어하려면 팬 제어 서비스를 설치해야 합니다.", "Install the fan control service to control the fan."))
                    .font(.callout)
                if !model.isInApplications {
                    Text(tr("먼저 FanPilot을 응용 프로그램 폴더로 옮긴 뒤 실행하세요.", "Move FanPilot to the Applications folder first, then open it."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Button(outdated ? tr("업데이트 (관리자 암호 필요)", "Update (admin password)") : tr("설치 (관리자 암호 필요)", "Install (admin password)")) { model.installDaemon() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isInApplications)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var readingsSection: some View { LiveHeader(live: model.live, language: model.language, unit: model.tempUnit) }

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text(tr("사용", "Use")).foregroundStyle(.secondary)
                Toggle("CPU", isOn: $model.draft.useCPU).disabled(model.draft.useCPU && !model.draft.useGPU)
                Toggle("GPU", isOn: $model.draft.useGPU).disabled(model.draft.useGPU && !model.draft.useCPU)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            Text(tr("켜진 곡선 중 더 높은 RPM을 따릅니다.", "The fan follows whichever enabled curve asks for more.")).font(.caption).foregroundStyle(.secondary)

            Picker(tr("편집할 곡선", "Curve to edit"), selection: $model.editingCurve) {
                Text(tr("CPU 평균", "CPU avg")).tag(TempSource.cpuAverage)
                Text(tr("GPU 평균", "GPU avg")).tag(TempSource.gpuAverage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LiveCurvePreview(live: model.live, config: model.draft, sensor: model.editingCurve, unit: model.tempUnit)
            Toggle(tr("부드러운 곡선 (단계 사이를 직선으로 연결)", "Smooth curve (blend between steps)"), isOn: $model.draft.smooth)
                .toggleStyle(.checkbox)
                .font(.callout)

            ForEach(model.editingSteps.wrappedValue.indices, id: \.self) { i in
                HStack {
                    NumberField(value: model.tempBinding(model.stepField(i, \.minTemp)), width: 50)
                    Text(tr("\(model.tempUnit.symbol) 이상 →", "\(model.tempUnit.symbol) and up →"))
                    NumberField(value: model.stepField(i, \.rpm), width: 64)
                    Text("RPM")
                    Spacer()
                    Button { model.editingSteps.wrappedValue.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(model.editingSteps.wrappedValue.count <= 1)
                }
            }
            .disabled(!model.draft.uses(model.editingCurve))
            HStack {
                // Same layout as the step rows (hidden arrow text) so the RPM fields line up.
                Text(tr("그 이하", "Below")).frame(width: 50, alignment: .leading)
                Text(tr("\(model.tempUnit.symbol) 이상 →", "\(model.tempUnit.symbol) and up →")).hidden()
                NumberField(value: $model.draft.baseRPM, width: 64)
                Text("RPM")
                Spacer()
                Button {
                    let lowest = model.editingSteps.wrappedValue.min { $0.minTemp < $1.minTemp }
                    model.editingSteps.wrappedValue.append(CurveStep(minTemp: (lowest?.minTemp ?? 80) - 10, rpm: lowest?.rpm ?? 2000))
                } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
            }
            HStack {
                Text(tr("히스테리시스", "Hysteresis"))
                NumberField(value: model.deltaBinding($model.draft.hysteresis), width: 40)
                Text(model.tempUnit.symbol).foregroundStyle(.secondary)
                Spacer()
                Button(tr("기본값으로", "Defaults")) { model.resetCurve() }
            }.font(.callout)
            Text(tr("팬 범위: ", "Fan range: ") + "\(Int(model.fanMin))–\(Int(model.fanMax)) RPM")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fixedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Slider(value: $model.draft.fixedRPM, in: model.fanMin...model.fanMax, step: 100)
                NumberField(value: $model.draft.fixedRPM, width: 64)
                Text("RPM")
            }
        }
    }

    private var footer: some View {
        HStack {
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if inPopover {
                Button { model.showMainWindow() } label: { Image(systemName: "macwindow") }
                    .help(tr("창으로 열기", "Open in window"))
            }
            Button(tr("되돌리기", "Revert")) { model.draft = model.saved }.disabled(!model.dirty)
            Button(tr("적용", "Apply")) { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.dirty)
            Button(tr("종료", "Quit")) { NSApplication.shared.terminate(nil) }
        }
    }
}

/// The only view that observes per-tick data, so new readings re-render just this header.
struct LiveHeader: View {
    @ObservedObject var live: LiveState
    /// Not read directly; passing it makes SwiftUI re-render the header when the language changes.
    let language: AppLanguage
    let unit: TempUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 18) {
                stat(tr("CPU 평균", "CPU avg"), unit.text(live.readings.cpuAverage, decimals: 1))
                stat(tr("GPU 평균", "GPU avg"), unit.text(live.readings.gpuAverage, decimals: 1))
                // Several fans don't fit in one row; the header shows their average and the
                // Monitor tab has a card per fan.
                let count = live.readings.fans?.count ?? 1
                if !Hardware.isFanless { stat(count > 1 ? tr("팬 평균 (\(count)개)", "Fans avg (\(count))") : tr("팬", "Fan"), Format.rpm(live.readings.fanRPM) + " RPM") }
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).monospacedDigit()).bold()
        }
    }

    private var statusColor: Color {
        if Hardware.isFanless { return .secondary }
        guard live.daemonAlive, let s = live.status else { return .red }
        if s.emergency { return .orange }
        return s.error == nil ? .green : .orange
    }

    private var statusText: String {
        if Hardware.isFanless { return tr("팬이 없는 Mac · 온도 모니터로 동작 중", "No fan on this Mac · monitoring only") }
        guard live.daemonAlive, let s = live.status else { return tr("팬 제어 서비스가 실행 중이 아닙니다", "Fan control service isn't running") }
        if let e = s.error { return localizedDaemonError(e) }
        if s.emergency { return tr("비상: 최대 RPM으로 동작 중", "Emergency: running at max RPM") }
        switch s.mode {
        case .system: return tr("시스템 자동 제어 중", "macOS is controlling the fan")
        case .curve:
            let by = s.driver.map { $0 == .cpuAverage ? " (CPU)" : " (GPU)" } ?? ""
            return tr("목표 \(Int(s.targetRPM ?? 0)) RPM으로 제어 중", "Holding \(Int(s.targetRPM ?? 0)) RPM") + by
        case .fixed: return tr("목표 \(Int(s.targetRPM ?? 0)) RPM으로 제어 중", "Holding \(Int(s.targetRPM ?? 0)) RPM")
        }
    }
}

/// AppKit focuses the first text field when a window opens, so typing meant for another app
/// (e.g. right after launch) landed in the first curve step. Clear that initial focus once.
private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusClearingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FocusClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
        }
    }
}

/// Measured height of the settings content. (A StateObject because the @State macro isn't
/// available with the Command Line Tools toolchain.)
final class LayoutState: ObservableObject {
    @Published var contentHeight: CGFloat = 600
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NumberField: View {
    @Binding var value: Double
    var width: CGFloat

    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .textFieldStyle(.roundedBorder)
    }
}
