import Foundation
import SwiftUI

/// 账户金额隐私开关：小眼睛切换，记住上次选择。
final class PrivacyMode: ObservableObject {
    static let storageKey = "hideAccountAmounts"
    static let mask = "••••"

    @Published var hidden: Bool {
        didSet { UserDefaults.standard.set(hidden, forKey: Self.storageKey) }
    }

    init() {
        // 调试用：FB_PRIVACY=1/0 启动时强制隐藏/显示，方便截图核对
        if let v = DebugHooks.env("FB_PRIVACY") {
            hidden = (v == "1")
            return
        }
        hidden = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    func money(_ value: Double?, _ digits: Int = 2) -> String {
        hidden ? Self.mask : Fmt.money(value, digits)
    }

    func signed(_ value: Double?, _ digits: Int = 2) -> String {
        hidden ? Self.mask : Fmt.signed(value, digits)
    }

    func pct(_ value: Double?, _ digits: Int = 2) -> String {
        hidden ? Self.mask : Fmt.pct(value, digits)
    }

    func text(_ value: String) -> String {
        hidden ? Self.mask : value
    }
}

/// 只给数字用的隐私文本：金额 / 收益 / 百分比，隐藏时换成 ••••
struct PrivacyText: View {
    let text: String
    var mask: String = PrivacyMode.mask

    @EnvironmentObject private var privacy: PrivacyMode

    var body: some View {
        Text(privacy.hidden ? mask : text)
    }
}
