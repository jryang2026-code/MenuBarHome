import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
struct MiAccountAutoLoginTests {
    @Test("Automatic QR login needs an automatic-login request plus Xiaomi Cloud or an expired Mi session")
    func autoLoginNeedsAReason() {
        #expect(MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: true, homeBackend: .xiaomiCloud, miSessionShowsExpired: false
        ))
        #expect(MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: true, homeBackend: .homeAssistant, miSessionShowsExpired: true
        ))
        #expect(!MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: false, homeBackend: .xiaomiCloud, miSessionShowsExpired: true
        ))
        for backend in [HomeBackend.homeAssistant, .demo] {
            #expect(!MiAccountSection.shouldAutoStartQRLogin(
                autoStartsQRLogin: true, homeBackend: backend, miSessionShowsExpired: false
            ))
        }
    }

    @Test("Consolidated logout alert state distinguishes per-account removal from single and multi-account sign-out")
    func logoutConfirmationCopy() {
        let account = MiAccount(session: MiSession(
            userId: "123456789",
            cUserId: "c1",
            ssecurity: "s1",
            serviceToken: "t1",
            region: "cn"
        ))
        L10n.$overrideLanguage.withValue(.zhHans) {
            let single = MiAccountSection.LogoutConfirmation.account(account)
            #expect(single.title(accountCount: 2) == "移除米家账号？")
            #expect(single.confirmButtonTitle(accountCount: 2) == "移除")
            #expect(single.messageText.contains(account.displayName))

            let allOne = MiAccountSection.LogoutConfirmation.all
            #expect(allOne.title(accountCount: 1) == "退出米家账号？")
            #expect(allOne.confirmButtonTitle(accountCount: 1) == "退出登录")
            #expect(allOne.title(accountCount: 2) == "退出全部米家账号？")
            #expect(allOne.confirmButtonTitle(accountCount: 2) == "全部退出")
        }
        L10n.$overrideLanguage.withValue(.en) {
            let single = MiAccountSection.LogoutConfirmation.account(account)
            #expect(single.title(accountCount: 2) == "Remove Xiaomi Home account?")
            #expect(single.confirmButtonTitle(accountCount: 2) == "Remove")
            #expect(single.messageText.contains(account.displayName))

            let allMany = MiAccountSection.LogoutConfirmation.all
            #expect(allMany.title(accountCount: 2) == "Sign out of all Xiaomi Home accounts?")
            #expect(allMany.confirmButtonTitle(accountCount: 2) == "Sign Out of All")
        }
    }

    @Test("Disable connection confirmation previews affected items using 连接 copy without technical jargon")
    func disableConnectionConfirmationCopy() {
        let account = MiAccount(session: MiSession(
            userId: "123456789", cUserId: "c1", ssecurity: "s1", serviceToken: "t1", region: "cn"
        ))
        let items = [
            AffectedReferenceItem(
                kind: .waitingTimer, id: "t1", name: "23:00 关客厅灯",
                connectionScopes: [account.id], affectedTargetIds: ["d1"], affectedCapabilities: [.connection(.xiaomiCloud)]
            ),
            AffectedReferenceItem(
                kind: .automationRule, id: "r1", name: "锁屏 · 关灯",
                connectionScopes: [account.id], affectedTargetIds: ["d1"], affectedCapabilities: [.connection(.xiaomiCloud)]
            ),
        ]
        let confirmation = MiAccountSection.DisableConnectionConfirmation(
            account: account, itemsToPause: items, generation: 1
        )
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(confirmation.title == "停用米家账号连接？")
            #expect(confirmation.confirmButtonTitle == "暂停并停用连接")
            #expect(confirmation.messageText.contains("连接"))
            #expect(confirmation.messageText.contains("23:00 关客厅灯"))
            #expect(confirmation.messageText.contains("锁屏 · 关灯"))
            for technicalWord in ["backend", "provider", "scope", "slot", "后端", "作用域", "槽位"] {
                #expect(!confirmation.messageText.localizedCaseInsensitiveContains(technicalWord))
                #expect(!confirmation.title.localizedCaseInsensitiveContains(technicalWord))
            }
        }
    }
}
