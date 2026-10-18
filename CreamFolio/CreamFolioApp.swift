import SwiftUI

@main
struct CreamFolioApp: App {
    @StateObject private var state = AppState()
    @StateObject private var privacy = PrivacyMode()
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if let k = ProcessInfo.processInfo.environment["FB_KIND"], !k.isEmpty {
                    NavigationStack { KindFundsView(kind: k) }
                } else if ProcessInfo.processInfo.environment["FB_PREVIEW"] == "1" {
                    NavigationStack { TabBarPreviewView() }
                } else {
                    RootView()
                }
            }
                .environmentObject(state)
                .environmentObject(privacy)
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
                .task {
                    await state.load()
                    state.startAutoRefresh(seconds: 60)
                }
        }
    }
}

/// 主界面底部悬浮导航的显示状态：push 进详情 / 资产类型 / 流水 / 导航预览时隐藏
final class TabBarVisibility: ObservableObject {
    @Published var hidden = false
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var tabBarVisibility = TabBarVisibility()

    /// 允许通过启动环境变量直接进入某个页签，方便自动化截图 / 调试：
    ///   FB_TAB = hold | calendar | market | settings
    ///   流水页不再是页签，用 FB_FLOW=1 进（入口在持仓页工具栏）
    @State private var selection: Int = {
        switch DebugHooks.env("FB_TAB") ?? "" {
        case "calendar": return 1
        case "market": return 2
        case "settings": return 3
        default: return 0
        }
    }()

    private let tabItems: [(icon: String, title: String)] = [
        ("chart.pie.fill", "持仓"),
        ("calendar", "日历"),
        ("chart.line.uptrend.xyaxis", "市场"),
        ("gearshape.fill", "设置"),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                PortfolioView()
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Label("持仓", systemImage: "chart.pie.fill") }
                    .tag(0)

                ProfitCalendarView()
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Label("日历", systemImage: "calendar") }
                    .tag(1)

                MarketView()
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Label("市场", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(2)

                SettingsView()
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(3)
            }
            if !tabBarVisibility.hidden {
                FloatingTabBar(selection: $selection, items: tabItems)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environmentObject(tabBarVisibility)
        .animation(.snappy(duration: 0.25), value: tabBarVisibility.hidden)
    }
}
