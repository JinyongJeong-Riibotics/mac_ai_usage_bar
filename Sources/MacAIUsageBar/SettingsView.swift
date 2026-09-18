import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var copiedAccountID: UUID?

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

            Section {
                ForEach($settings.codexAccounts) { $account in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $account.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(.blue)
                            TextField("표시 이름", text: $account.name)
                            Button(role: .destructive) {
                                settings.removeCodexAccount(id: account.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(settings.codexAccounts.count == 1)
                            .help("계정 제거")
                        }

                        TextField("CODEX_HOME 경로", text: $account.codexHomePath)
                            .font(.system(.caption, design: .monospaced))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(account.loginCommand, forType: .string)
                            copiedAccountID = account.id
                        } label: {
                            Label(copiedAccountID == account.id ? "복사됨" : "로그인 명령 복사",
                                  systemImage: copiedAccountID == account.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    settings.addCodexAccount()
                } label: {
                    Label("Codex 계정 추가", systemImage: "plus")
                }
            } header: {
                Text("Codex 계정")
            } footer: {
                Text("계정마다 별도 CODEX_HOME을 사용합니다. 계정을 추가한 뒤 로그인 명령을 복사해 터미널에서 실행하고, 브라우저에서 해당 계정으로 로그인하세요. 기본 ~/.codex 계정은 기존 로그인을 그대로 사용합니다.")
                    .font(.caption)
            }

            Section {
                ForEach($settings.claudeAccounts) { $account in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $account.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(.blue)
                            TextField("표시 이름", text: $account.name)
                            Button(role: .destructive) {
                                settings.removeClaudeAccount(id: account.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(settings.claudeAccounts.count == 1)
                            .help("계정 제거")
                        }

                        TextField("CLAUDE_CONFIG_DIR 경로",
                                  text: $account.claudeConfigDirectoryPath)
                            .font(.system(.caption, design: .monospaced))

                        if settings.isDuplicateClaudePath(id: account.id) {
                            Label("다른 Claude 계정과 같은 경로입니다. 중복 프로필은 조회하지 않습니다.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(account.loginCommand, forType: .string)
                            copiedAccountID = account.id
                        } label: {
                            Label(copiedAccountID == account.id ? "복사됨" : "로그인 명령 복사",
                                  systemImage: copiedAccountID == account.id
                                    ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    settings.addClaudeAccount()
                } label: {
                    Label("Claude 계정 추가", systemImage: "plus")
                }
            } header: {
                Text("Claude 계정")
            } footer: {
                Text("계정마다 별도 CLAUDE_CONFIG_DIR과 macOS 키체인 항목을 사용합니다. 로그인 명령을 터미널에서 실행해 각 프로필을 인증하세요. 기본 ~/.claude 계정은 기존 로그인을 그대로 사용합니다.")
                    .font(.caption)
            }

            Section {
                Toggle("터미널 없이 Claude 인증 유지", isOn: $settings.claudeAutoRefreshViaCLI)
                    .toggleStyle(.switch)
                    .tint(.blue)
            } header: {
                Text("Claude 인증")
            } footer: {
                Text("Claude 토큰은 약 8시간마다 만료되고 Claude Code는 백그라운드에서 갱신하지 않습니다. 이 옵션을 켜면 토큰이 만료됐을 때 앱이 `claude -p`를 잠깐 실행해 Claude Code가 스스로 토큰을 갱신하게 합니다. 갱신마다 아주 작은 메시지 1개를 소모합니다.")
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
        .frame(width: 460, height: 780)
    }

    private func intervalLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))초" }
        let m = Int(seconds) / 60
        return "\(m)분"
    }
}
