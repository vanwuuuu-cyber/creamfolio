import SwiftUI

/// 持仓页能跳去的页面。
/// 必须全部走 NavigationStack 的 path —— 混用 `navigationDestination(isPresented:)`
/// 会导致「返回后再点没反应」。
enum PortfolioRoute: Hashable {
    case fund(String)
    case kind(String)
    case flow
}

/// 「我的基金」的排序方式
enum FundSort: String, CaseIterable, Identifiable {
    case value = "市值"
    case profitDesc = "收益率 高→低"
    case profitAsc = "收益率 低→高"
    case name = "名称"

    var id: String { rawValue }
    var label: String { rawValue }
}

struct PortfolioView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var tabBarVisibility: TabBarVisibility
    @EnvironmentObject var privacy: PrivacyMode

    /// 调试用：FB_FUND=<基金代码> 启动时直接进该基金详情页
    @State private var path: [PortfolioRoute] = {
        if let k = DebugHooks.env("FB_KINDROUTE"), !k.isEmpty { return [.kind(k)] }
        let c = DebugHooks.env("FB_FUND") ?? ""
        return c.isEmpty ? [] : [.fund(c)]
    }()

    @State private var showingAdd = false
    /// 点平台卡片筛选基金列表；再点一次取消
    @State private var platformFilter: String?
    /// 平台卡片是「扇形叠放」还是「展开平铺」
    @State private var fanExpanded = false
    /// 卡片进详情的缩放转场
    @Namespace private var zoomNS

    /// 折叠起来的资产分组
    @State private var collapsedKinds: Set<String> = []

    /// 搜索持有基金（自绘搜索栏，保持大标题在左侧）
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// 大标题滚上去、紧凑栏吸顶后显示小标题和毛玻璃
    @State private var headerPinned = false

    /// 基金列表排序方式（记在本地，下次打开还是这个）
    @AppStorage("fundSort") private var sortRaw = FundSort.value.rawValue


    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 14) {
                        topHeader

                        Group {
                            if let d = state.dashboard {
                                content(d)
                            } else if let err = state.errorMessage {
                                SoftCard(padding: 14) {
                                    InlineError(text: err)
                                }
                            } else {
                                RisingChartLoader()
                                    .frame(height: 260)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    .padding(.bottom, 92)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.top)
                .scrollDismissesKeyboard(.interactively)
                .background(CloudBackdrop().ignoresSafeArea())
                .overlay(alignment: .top) {
                    // 只压一层和页面同色的渐变，避免状态栏出现一块灰材质
                    LinearGradient(colors: [Theme.canvas.opacity(colorScheme == .dark ? 0.92 : 0.88),
                                            Theme.canvas.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 64)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
                .modifier(ScrollOffsetModifier { offset in
                    let pinned = offset > 150
                    if pinned != headerPinned {
                        withAnimation(.easeInOut(duration: 0.18)) { headerPinned = pinned }
                    }
                })
                .animation(.snappy(duration: 0.30), value: platformFilter)
                .navigationTitle("持仓")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: PortfolioRoute.self) { route in
                    switch route {
                    case .fund(let code):
                        FundDetailView(code: code)
                            .cardDestination(id: code, in: zoomNS)
                    case .kind(let k):
                        KindFundsView(kind: k)
                            .id(k)
                    case .flow:
                        FlowView()
                    }
                }
                .refreshable { await state.load() }
                .sheet(isPresented: $showingAdd) {
                    AddEntryView()
                        .environmentObject(state)
                }
                .onAppear {
                    updateTabBarVisibility(for: path)
                    // 调试用：FB_FAN=1 时以「展开」状态启动，方便截图核对
                    if DebugHooks.isOn("FB_FAN") {
                        fanExpanded = true
                    }
                    // 调试用：FB_FLOW=1 直接进流水页
                    if DebugHooks.isOn("FB_FLOW"), path.isEmpty {
                        path.append(.flow)
                    }
                }
                .onChange(of: path) { _, newValue in
                    updateTabBarVisibility(for: newValue)
                }
                // 调试用：FB_ADD=1 启动后自动弹出「添加持仓」，方便自动化截图。
                // 必须等视图进入层级之后再 present，否则 sheet 会是白屏。
                .task {
                    guard DebugHooks.isOn("FB_ADD") else { return }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showingAdd = true
                }

                // 固定覆盖层：大标题滚走后才出现，不参与 ScrollView 布局，
                // 所以不会像 safeAreaInset 那样改变滚动几何。
                pinnedHeader
                    .opacity(headerPinned ? 1 : 0)
                    .allowsHitTesting(headerPinned)
            }
        }
    }

    private func updateTabBarVisibility(for path: [PortfolioRoute]) {
        // 流水页保留底部导航；详情 / 资产类型页让位给正文
        tabBarVisibility.hidden = !(path.isEmpty || path.last == .flow)
    }

    // MARK: - 大标题（在滚动内容里）
    private var topHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("持仓")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                headerActions
            }
            searchBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 60)
        .padding(.bottom, 4)
    }

    // MARK: - 吸顶覆盖层（不参与滚动布局）
    private var pinnedHeader: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("持仓")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                headerActions
            }
            searchBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Theme.canvas.opacity(colorScheme == .dark ? 0.55 : 0.30)
                }
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.35)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 2) {
            // 小眼睛：切换账户金额显示
            Button {
                withAnimation(.snappy(duration: 0.2)) { privacy.hidden.toggle() }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(privacy.hidden ? "EyeClosed" : "EyeOpen")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(privacy.hidden ? "显示账户金额" : "隐藏账户金额")

            // 流水：收据/账单图标，不用 list/菜单图标
            Button {
                path.append(.flow)
            } label: {
                Image(systemName: "receipt")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("流水")

            Menu {
                Picker("排序", selection: $sortRaw) {
                    ForEach(FundSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("排序方式：\(sort.label)")

            Button {
                showingAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("添加持仓")
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                                        lineWidth: 0.8))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜基金名称或代码", text: $query)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                                                lineWidth: 0.8))
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ d: Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 有数据但行情拉不到时，顶上放一条提示（不要让用户以为持仓没了）
            if let err = state.errorMessage {
                SoftCard(padding: 14) {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            heroCard(d)

            if let curve = d.curve, curve.dates.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    EquityCurveCard(curve: curve,
                                    xirr: d.summary.xirr,
                                    xirrDays: d.summary.xirrDays ?? 0,
                                    maxDrawdown: d.summary.maxDrawdown,
                                    maxDrawdownDate: d.summary.maxDrawdownDate,
                                    volatility: d.summary.volatility)
                    Text("曲线按每日净值反推：那天收盘时账户值多少。不是定时记的快照，所以补历史也能画。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            if d.funds.isEmpty {
                SoftCard(padding: 0) {
                    ContentUnavailableView {
                        Label("还没有持仓", systemImage: "chart.pie")
                    } description: {
                        Text("点击右上角 + 添加第一笔")
                    }
                    .padding(.vertical, 30)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(kindGroups(d)) { g in
                        Button {
                            path.append(.kind(g.kind))
                        } label: {
                            KindCard(kind: g.kind,
                                     count: g.funds.count,
                                     marketValue: g.marketValue,
                                     series: g.topSeries,
                                     up: g.topUp,
                                     pct: g.topPct)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 过滤 + 排序之后的基金列表
    private func shareOf(_ f: FundItem, in d: Dashboard) -> Double {
        let total = d.summary.marketValue
        guard total > 0 else { return 0 }
        return (f.marketValue ?? 0) / total
    }

    private func maxShareOf(_ d: Dashboard) -> Double {
        let total = d.summary.marketValue
        guard total > 0 else { return 0 }
        return (d.funds.compactMap(\.marketValue).max() ?? 0) / total
    }

    private var sort: FundSort {
        FundSort(rawValue: sortRaw) ?? .value
    }

    private struct KindGroup: Identifiable {
        let kind: String
        let funds: [FundItem]
        let marketValue: Double
        var id: String { kind }

        /// 组内市值最大那只，用它代表整组的走势
        private var top: FundItem? {
            funds.max { ($0.marketValue ?? 0) < ($1.marketValue ?? 0) }
        }
        var topSeries: [Double] { top?.seriesValues ?? [] }
        var topUp: Bool { (top?.profitPct ?? 0) >= 0 }
        var topPct: Double? { top?.profitPct }
    }

    /// 按资产类型分组（组内沿用当前排序，组间按市值降序）
    private func kindGroups(_ d: Dashboard) -> [KindGroup] {
        var by: [String: [FundItem]] = [:]
        for f in visibleFunds(d) {
            by[(f.kind ?? "其他"), default: []].append(f)
        }
        return by.map { kind, fs in
            KindGroup(kind: kind, funds: fs,
                      marketValue: fs.reduce(0) { $0 + ($1.marketValue ?? 0) })
        }
        .sorted { $0.marketValue > $1.marketValue }
    }

    private func visibleFunds(_ d: Dashboard) -> [FundItem] {
        var out = d.funds
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.code.contains(q)
            }
        }
        if let p = platformFilter {
            out = out.filter { $0.platform == p }
        }
        switch sort {
        case .value:
            out.sort { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        case .profitDesc:
            // 没有收益率数据的排到最后
            out.sort { ($0.profitPct ?? -Double.infinity) > ($1.profitPct ?? -Double.infinity) }
        case .profitAsc:
            out.sort { ($0.profitPct ?? Double.infinity) < ($1.profitPct ?? Double.infinity) }
        case .name:
            out.sort { $0.name < $1.name }
        }
        return out
    }

    // MARK: - 主卡（总资产）

    /// 资产类型分布（按市值取前 3 类）
    private func kindText(_ d: Dashboard) -> String? {
        guard let kinds = d.kinds, !kinds.isEmpty else { return nil }
        let total = kinds.reduce(0) { $0 + $1.marketValue }
        guard total > 0 else { return nil }
        return kinds
            .sorted { $0.marketValue > $1.marketValue }
            .prefix(3)
            .map { "\(Self.shortKind($0.kind)) \(Int(($0.marketValue / total * 100).rounded()))%" }
            .joined(separator: " · ")
    }

    private static func shortKind(_ k: String) -> String {
        switch k {
        case "黄金白银": return "黄金"
        case "A股指数": return "A股"
        case "主动混合": return "主动"
        default: return k
        }
    }

    private func heroCard(_ d: Dashboard) -> some View {
        let s = d.summary
        let estimated = s.estProfit != nil
        let shownValue = estimated ? s.marketValue + (s.estProfit ?? 0) : s.marketValue

        return WalletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if estimated { ToneDot(value: s.estPct) }
                    CardCaption(text: estimated ? "估算总市值" : "总市值")
                    Spacer()
                }

                CardHeroValue(text: Fmt.money(shownValue))

                if estimated {
                    HStack(spacing: 5) {
                        Text("较最新净值")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TrendBadge(pct: s.estPct,
                                   text: "\(Fmt.signed(s.estProfit))  \(Fmt.pct(s.estPct))")
                        // 只有认得出跟踪指数的基金才参与预估，覆盖率低时必须说明
                        if let cov = s.estCoverage, cov < 0.995 {
                            Text("覆盖 \(Int((cov * 100).rounded()))%")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        CardCaption(text: "按最新净值")
                        CardValue(text: Fmt.money(s.marketValue))
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 3) {
                        CardCaption(text: "持有收益")
                        HStack(spacing: 4) {
                            PrivacyText(text: Fmt.signed(s.profit))
                                .scaledFont(17, weight: .semibold, design: .rounded, mono: true)
                                .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(s.profit))
                            PrivacyText(text: Fmt.pct(s.profitPct))
                                .scaledFont(13, weight: .semibold, design: .rounded, mono: true)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(privacy.hidden
                     ? "\(s.fundCount) 只 · 金额已隐藏"
                     : ([kindText(d)].compactMap { $0 } + ["\(s.fundCount) 只", "投入 \(Fmt.money(s.cost))"]).joined(separator: " · "))
                    .scaledFont(10.5)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 平台卡片（扇形叠放）

    private func platformStrip(_ d: Dashboard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: fanExpanded ? 12 : -26) {
                ForEach(Array(d.platforms.enumerated()), id: \.element.id) { idx, p in
                    let isOn = (platformFilter == p.platform)
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            platformFilter = isOn ? nil : p.platform
                        }
                    } label: {
                        platformCard(p, idx: idx, isOn: isOn, total: d.summary.marketValue)
                    }
                    .buttonStyle(.plain)
                    .zIndex(isOn ? 999 : Double(idx))
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 40)      // 最后一张不被裁掉
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func platformCard(_ p: PlatformSummary, idx: Int, isOn: Bool,
                              total: Double = 0) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CardAvatar(text: String(p.platform.prefix(1)),
                           tint: CardStyle.accent(idx), size: 22)
                CardCaption(text: p.platform, size: 10.5)
            }
            Text(Fmt.money(p.marketValue))
                .scaledFont(18, weight: .semibold, design: .rounded, mono: true)
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            TrendBadge(pct: p.profitPct)
            Text("\(p.count) 只 · 占 \(Int((p.marketValue / max(total, 1) * 100).rounded()))%")
                .scaledFont(10)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 13)
        .padding(.trailing, fanExpanded ? 13 : 34)   // 叠放时右边留出被压住的宽度
        .padding(.vertical, 13)
        .frame(width: fanExpanded ? 130 : 142, alignment: .leading)
        .background {
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: isOn ? 0.60 : 0.40
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if isOn {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
        .scaleEffect(isOn ? 1.0 : (fanExpanded ? 1.0 : 0.95), anchor: .center)
        .offset(y: isOn ? -3 : 0)
    }
}

// MARK: - 基金行

private struct FundRow: View {
    let fund: FundItem
    /// 这只基金占组合市值的比例（0…1）
    var share: Double = 0
    /// 当前列表里占比最大的那只，作为细条满格的基准
    var maxShare: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(fund.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 10)
                Text(Fmt.money(fund.marketValue))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }

            HStack(alignment: .firstTextBaseline) {
                Text([fund.code, fund.platform].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                TrendBadge(pct: fund.profitPct)
            }

            HStack(spacing: 5) {
                Text("净值 \(Fmt.num(fund.nav, 4))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("预估")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Fmt.pct(fund.estPct))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Fmt.tone(fund.estPct))
                    if let sg = fund.sgzt, sg.hasPrefix("暂停") {
                        Text("停购")
                            .scaledFont(9, weight: .semibold)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                Spacer(minLength: 0)
                if share > 0.001 {
                    Text("占 \(Int((share * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 1)

            // 占比细条：¥10,500 和 ¥10 在列表里长得一样，加一条视觉比例
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, geo.size.width * min(1, maxShare > 0 ? share / maxShare : 0)))
                }
            }
            .frame(height: 2.5)
            .padding(.top, 3)
        }
        .padding(.vertical, 3)
    }
}







private struct ScrollOffsetModifier: ViewModifier {
    let action: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                action(offset)
            }
        } else {
            content
        }
    }
}
