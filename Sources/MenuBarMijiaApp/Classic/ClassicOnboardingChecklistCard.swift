import SwiftUI
import MijiaCore

/// One 44 pt row for the next getting-started step. Launch at login lives in the overflow menu
/// so it does not add a second row above the devices.
struct ClassicOnboardingChecklistCard: View {
    let store: HomeStore
    var onBeginSearch: () -> Void

    var body: some View {
        let checklist = store.onboardingChecklist
        // The same row doubles as the standalone launch-at-login reminder after onboarding is
        // skipped or done. That row is not a lesson step and must not offer 试试.
        let nextStep = store.showsOnboardingChecklist ? checklist.nextStep : nil
        HStack(spacing: 6) {
            Text(rowTitle(checklist, nextStep: nextStep))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 4)

            if store.shouldShowLaunchAtLoginSuggestion {
                launchOverflow
            }

            if let next = nextStep {
                Button(L10n.tr("试试", "Try")) {
                    run(next)
                }
                .buttonStyle(ClassicPillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                .disabled(next == .allOffAndUndo && store.allOffTargets.isEmpty)
                .panelHelp(tryHelp(next))
            }

            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.completeOnboarding()
                    store.dismissLaunchAtLoginSuggestion()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("关闭上手清单", "Close getting-started checklist")))
            .panelHelp(L10n.tr(
                "关闭清单；随时可在设置 → 通用 → 首次设置重新打开",
                "Close the checklist; reopen it in Settings → General → Setup"
            ))
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: DesignTokens.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-lesson-row")
    }

    private func rowTitle(_ checklist: OnboardingChecklist, nextStep: OnboardingStep?) -> String {
        let done = checklist.completedSteps.count
        if let next = nextStep {
            return L10n.tr(
                "上手 \(done)/3 · 下一步：\(nextAction(next))",
                "Start \(done)/3 · Next: \(nextAction(next))"
            )
        }
        return L10n.tr("开机自动启动", "Launch at Login")
    }

    private func nextAction(_ step: OnboardingStep) -> String {
        switch step {
        case .connectAccount:
            return L10n.tr("连接账号", "Connect")
        case .searchDevice:
            return L10n.tr("按 \(hotkeyLabel) 搜索", "Search with \(hotkeyLabel)")
        case .allOffAndUndo:
            return L10n.tr("演练全关", "Practice All Off")
        }
    }

    private func tryHelp(_ step: OnboardingStep) -> String {
        switch step {
        case .connectAccount:
            return L10n.tr("去连接账号", "Connect an account")
        case .searchDevice:
            return L10n.tr("把光标放进搜索框", "Focus the search field")
        case .allOffAndUndo:
            if store.allOffTargets.isEmpty {
                return L10n.tr("当前没有开启的设备", "No active devices are currently on")
            }
            return L10n.tr(
                "按住全关，只预览会关闭哪些设备，不会真的发送",
                "Hold All Off to preview the devices. Nothing is sent."
            )
        }
    }

    private func run(_ step: OnboardingStep) {
        switch step {
        case .connectAccount:
            SettingsWindowOpener.shared.show(tab: .connection)
        case .searchDevice:
            onBeginSearch()
        case .allOffAndUndo:
            withAnimation(AppleMotion.snappySpring) { _ = store.rehearseAllOff() }
        }
    }

    private var hotkeyLabel: String {
        HotkeySettingsState.shared.shortcut.displayString
    }

    @MainActor private var launchAtLogin: LaunchAtLoginCoordinator { .live(store: store) }

    private var launchOverflow: some View {
        Menu {
            if store.launchAtLoginPolicy.needsManualApproval {
                Button(L10n.tr("去系统设置开启", "Open System Settings")) {
                    launchAtLogin.openSystemSettings()
                }
            } else {
                Button(L10n.tr("登录 Mac 时自动启动", "Turn On Launch at Login")) {
                    withAnimation(AppleMotion.snappySpring) {
                        launchAtLogin.setEnabled(true)
                    }
                }
            }
            Button(L10n.tr("跳过", "Skip")) {
                withAnimation(AppleMotion.snappySpring) {
                    store.dismissLaunchAtLoginSuggestion()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(L10n.tr("登录 Mac 时自动启动", "Launch at Login")))
        .panelHelp(launchAtLoginDetail)
    }

    private var launchAtLoginDetail: String {
        if store.launchAtLoginPolicy.needsManualApproval {
            return L10n.tr(
                "系统没有自动设置成功，请到系统设置里手动开启。",
                "macOS could not enable it automatically. Turn it on in System Settings."
            )
        }
        return L10n.tr(
            "登录 Mac 后自动打开面板，不用再找菜单栏。",
            "Open the panel automatically after you log in, without hunting for the menu bar."
        )
    }
}
