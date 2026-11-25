import SwiftUI
import MijiaCore

/// One 44 pt row for the next getting-started step. Launch at login lives in the overflow menu
/// so it does not add a second row above the devices.
struct OnboardingChecklistCard: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let store: HomeStore
    var onBeginSearch: () -> Void
    var theme: PanelTheme = .liquidGlass

    var body: some View {
        let checklist = store.onboardingChecklist
        // The same row doubles as the standalone launch-at-login reminder after onboarding is
        // skipped or done. That row is not a lesson step and must not offer 试试.
        let nextStep = store.showsOnboardingChecklist ? checklist.nextStep : nil
        let row = HStack(spacing: 6) {
            Text(rowTitle(checklist, nextStep: nextStep))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 4)

            if store.shouldShowLaunchAtLoginSuggestion {
                if nextStep == nil {
                    // Alone on the row, the reminder's one job is a visible "Turn On"; × skips it.
                    launchPrimaryButton
                } else {
                    launchOverflow
                }
            }

            if let next = nextStep {
                Button(L10n.tr("试试", "Try")) {
                    run(next)
                }
                .themedPillButtonStyle(theme, isSelected: true, tintColor: .accentColor)
                .disabled(next == .allOffAndUndo && store.allOffTargets.isEmpty)
                .panelHelp(tryHelp(next))
            }

            Button {
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    store.completeOnboarding()
                    store.dismissLaunchAtLoginSuggestion()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(
                        size: theme == .classic ? 9.5 : DesignTokens.TypeSize.micro,
                        weight: .bold
                    ))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("关闭上手清单", "Close getting-started checklist")))
            .panelHelp(L10n.tr(
                "关闭清单；随时可在设置里搜索「初始设置引导」重新打开",
                "Close the checklist; reopen it by searching Settings for “Setup Guide”"
            ))
        }
        .padding(.horizontal, theme == .classic ? 10 : 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)

        cardChrome(row)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-lesson-row")
    }

    @ViewBuilder
    private func cardChrome<Content: View>(_ content: Content) -> some View {
        switch theme {
        case .liquidGlass:
            content
                .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.panel, isCapsule: true)
        case .classic:
            content
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: DesignTokens.hairline)
                }
        }
    }

    private func rowTitle(_ checklist: OnboardingChecklist, nextStep: OnboardingStep?) -> String {
        let done = checklist.completedSteps.count
        if let next = nextStep {
            return L10n.tr(
                "上手 \(done)/3 · 下一步：\(nextAction(next))",
                "Start \(done)/3 · Next: \(nextAction(next))"
            )
        }
        return L10n.tr("登录 Mac 时自动启动", "Launch at Login")
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
            return L10n.tr(
                "把光标放进搜索框；磁贴左侧开关、右侧打开调节",
                "Focus the search field; tile left toggles, right opens controls"
            )
        case .allOffAndUndo:
            if store.allOffTargets.isEmpty {
                return L10n.tr("当前没有开启的设备", "No active devices are currently on")
            }
            return L10n.tr(
                "演练只预览将关闭的设备，不会实际发送；正式操作按住「全关」0.6 秒确认，可在 10 秒内撤销，3 台起为 15 秒",
                "Practice only previews devices without sending; hold All Off for 0.6s to confirm, with 10s undo (15s for 3+ devices)"
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
            withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { _ = store.confirmAllOffHold(mode: .rehearsal) }
        }
    }

    private var hotkeyLabel: String {
        HotkeySettingsState.shared.shortcut.displayString
    }

    @MainActor private var launchAtLogin: LaunchAtLoginCoordinator { .live(store: store) }

    private var launchPrimaryButton: some View {
        Button(store.launchAtLoginPolicy.needsManualApproval
               ? L10n.tr("去系统设置开启", "Open System Settings")
               : L10n.tr("开启", "Turn On")) {
            if store.launchAtLoginPolicy.needsManualApproval {
                launchAtLogin.openSystemSettings()
            } else {
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    launchAtLogin.setEnabled(true)
                }
            }
        }
        .themedPillButtonStyle(theme, isSelected: true, tintColor: .accentColor)
        .accessibilityLabel(Text(store.launchAtLoginPolicy.needsManualApproval
            ? L10n.tr("去系统设置开启登录时自动启动", "Open System Settings to turn on Launch at Login")
            : L10n.tr("开启登录 Mac 时自动启动", "Turn on Launch at Login")))
        .panelHelp(launchAtLoginDetail)
    }

    private var launchOverflow: some View {
        Menu {
            if store.launchAtLoginPolicy.needsManualApproval {
                Button(L10n.tr("去系统设置开启", "Open System Settings")) {
                    launchAtLogin.openSystemSettings()
                }
            } else {
                Button(L10n.tr("登录 Mac 时自动启动", "Turn On Launch at Login")) {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                        launchAtLogin.setEnabled(true)
                    }
                }
            }
            Button(L10n.tr("跳过", "Skip")) {
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    store.dismissLaunchAtLoginSuggestion()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(
                    size: theme == .classic ? 12 : DesignTokens.TypeSize.caption,
                    weight: .bold
                ))
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
            "登录 Mac 后安静地待在菜单栏，随时点开就能控制，不会弹出打扰。",
            "Starts quietly in the menu bar when you log in, ready whenever you click it."
        )
    }
}
