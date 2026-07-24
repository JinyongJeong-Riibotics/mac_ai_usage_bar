import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    private let codexOptions: [Double] = [30, 60, 120, 300]
    private let claudeOptions: [Double] = [180, 300, 600, 900, 1800]

    var body: some View {
        Form {
            Section("일반") {
                Toggle("부팅 시 자동 실행", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .tint(.blue)
                if let err = settings.loginItemError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Codex 갱신 주기", selection: $settings.codexInterval) {
                    ForEach(codexOptions, id: \.self) { Text(intervalLabel($0)).tag($0) }
                }
                Picker("Claude 갱신 주기", selection: $settings.claudeInterval) {
                    ForEach(claudeOptions, id: \.self) { Text(intervalLabel($0)).tag($0) }
                }
            } header: {
                Text("갱신 주기")
            } footer: {
                Text("Claude 사용량 API는 호출이 잦으면 429로 차단됩니다. 최소 3분 이상 권장하며, 차단 시 자동으로 간격을 늘립니다.")
                    .font(.caption)
            }

            Section("표시") {
                Picker("표시 방식", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("메뉴바 기준 창", selection: $settings.barWindow) {
                    ForEach(BarWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("메뉴바에 표시할 서비스") {
                Toggle("Codex", isOn: $settings.showCodex)
                    .toggleStyle(.switch)
                    .tint(.blue)
                Toggle("Claude", isOn: $settings.showClaude)
                    .toggleStyle(.switch)
                    .tint(.blue)
            }

            Section {
                Toggle("임계값 알림", isOn: $settings.notificationsEnabled)
                    .toggleStyle(.switch)
                    .tint(.blue)
                Toggle("메뉴바 색상 경고", isOn: $settings.colorMenuBar)
                    .toggleStyle(.switch)
                    .tint(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("경고 임계값")
                        Spacer()
                        Text("\(Int(settings.warnThreshold))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.warnThreshold, in: 50...95, step: 5)
                }
            } header: {
                Text("알림 및 경고")
            } footer: {
                Text("사용률이 임계값을 넘으면 알림을 보내고 메뉴바를 빨갛게 표시합니다. 그 아래 한 단계(−15%)에서는 주황색으로 표시합니다. (알림은 정식 .app으로 실행할 때만 동작)")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func intervalLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))초" }
        let m = Int(seconds) / 60
        return "\(m)분"
    }
}
