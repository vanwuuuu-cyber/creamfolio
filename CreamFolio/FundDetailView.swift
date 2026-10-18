import SwiftUI
import Charts

/// 详情页分栏：把原来一长条列表拆成三页，每页只回答一个问题。
enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "概览"
    case trend = "走势"
    case lots = "明细"

    var id: String { rawValue }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case m1 = "1月"
    case m3 = "3月"
    case m6 = "6月"
    case y1 = "1年"
    case all = "全部"

    var id: String { rawValue }

    var points: Int {
        switch self {
        case .m1: return 22
        case .m3: return 66
        case .m6: return 132
        case .y1: return 250
        case .all: return 0
        }
    }
}

struct FundDetailView: View {
    let code: String

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var fund: FundItem?
    @State private var errorText: String?
    @State private var range: ChartRange = .m3
    @State private var showingAdd = false
    @State private var showingLots = false
    @State private var showingPlan = false
    @State private var confirmDelete = false
    @State private var showingNavInfo = false

    /// 当前分栏。默认「概览」，调试时可用 FB_DETAILTAB=trend|lots 直接打开某一页
    @State private var tab: DetailTab = {
        switch DebugHooks.env("FB_DETAILTAB") ?? "" {
        case "trend": return .trend
        case "lots": return .lots
        default: return .overview
        }
    }()

    /// 选中胶囊在三个标签间滑动的动画
    @Namespace private var tabNS
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var privacy: PrivacyMode

    /// 标签栏吸顶后给一层毛玻璃，内容才不会从字底下穿过去
    @State private var headerPinned = false

    var body: some View {
        ZStack(alignment: .bottom) {
            CloudBackdrop().ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                        if let f = fund {
                            heroCard(f)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                                .id("detailTop")

                            Section {
                                content(f)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 6)
                                    .id("detailTabContent")
                            } header: {
                                tabHeader
                                    .id("detailTabs")
                            }
                        } else if let errorText {
                            InlineError(text: errorText)
                                .padding(20)
                        } else {
                            ProgressView()
                                .padding(.top, 140)
                        }
                    }
                    .padding(.bottom, 210)
                }
                .scrollIndicators(.hidden)
                .refreshable { await reload() }
                .coordinateSpace(.named("detailScroll"))
                .onPreferenceChange(TabHeaderOffsetKey.self) { y in
                    let pinned = y <= 1
                    guard pinned != headerPinned else { return }
                    withAnimation(.easeInOut(duration: 0.16)) { headerPinned = pinned }
                }
                .onChange(of: tab) { _, _ in
                    // 吸顶状态下切标签，让新内容从标签下面开始；否则回到页面顶部
                    withAnimation(.snappy(duration: 0.28)) {
                        proxy.scrollTo(headerPinned ? "detailTabs" : "detailTop", anchor: .top)
                    }
                }
                .task {
                    // 调试用：FB_DETAILSCROLL=1 自动滚到标签栏，让标签吸顶，便于截图检查
                    guard DebugHooks.isOn("FB_DETAILSCROLL") else { return }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    withAnimation(.snappy(duration: 0.35)) {
                        proxy.scrollTo("detailTabs", anchor: .top)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .navigationTitle(fund?.code ?? "基金详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .task {
            // 调试用：FB_PLAN=1 自动打开「定投计划」
            guard DebugHooks.isOn("FB_PLAN") else { return }
            try? await Task.sleep(nanoseconds: 11_000_000_000)
            showingPlan = true
        }
        .overlay(alignment: .bottom) {
            if let f = fund {
                bottomCard(f)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            // 标题：基金代码 + 名称。名称很长时自动缩小字号，而不是截断成省略号
            ToolbarItem(placement: .principal) {
                if let f = fund {
                    VStack(spacing: 1) {
                        Text(f.code)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(f.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(fund?.code ?? "基金详情")
                        .font(.headline)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("再买一笔", systemImage: "plus")
                    }
                    Button {
                        showingLots = true
                    } label: {
                        Label("管理买入记录", systemImage: "list.bullet")
                    }
                    Button {
                        showingPlan = true
                    } label: {
                        Label("定投计划", systemImage: "repeat")
                    }
                    Menu {
                        ForEach(TrackOption.allCases) { opt in
                            Button {
                                changeTrack(opt)
                            } label: {
                                if (fund?.track ?? "") == opt.value {
                                    Label(opt.label, systemImage: "checkmark")
                                } else {
                                    Text(opt.label)
                                }
                            }
                        }
                    } label: {
                        Label("跟踪指数：\(trackLabel(fund?.track ?? ""))",
                              systemImage: "chart.line.uptrend.xyaxis")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除这只基金", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
            }
        }
        .sheet(isPresented: $showingAdd, onDismiss: { Task { await reload() } }) {
            AddEntryView(presetCode: code).environmentObject(state)
        }
        .sheet(isPresented: $showingPlan, onDismiss: { Task { await reload() } }) {
            PlanEditorView(code: code)
                .environmentObject(state)
        }
        .sheet(isPresented: $showingLots, onDismiss: { Task { await reload() } }) {
            LotManagerView(code: code).environmentObject(state)
        }
        .confirmationDialog("确定删除这只基金？", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    try? await state.removeFund(code: code)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会连同全部买入记录一起移除，无法撤销。")
        }
    }

    private func reload() async {
        do {
            fund = try await state.fundDetail(code: code)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - 内容

    /// 净值预估跟着哪个指数走
    enum TrackOption: String, CaseIterable, Identifiable {
        case ndx = "NDX"
        case spx = "SPX"
        case off = ""

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ndx: return "纳斯达克 100"
            case .spx: return "标普 500"
            case .off: return "不估算"
            }
        }
        var value: String { rawValue }
    }

    /// 今天适用的定投金额（最后一段 start <= 今天）
    private func currentPlanAmount(_ f: FundItem) -> Double? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let today = df.string(from: Date())
        return (f.plans ?? [])
            .sorted { $0.start < $1.start }
            .last(where: { $0.start <= today })?.amount
    }

    private func trackLabel(_ track: String) -> String {
        switch track.uppercased() {
        case "NDX": return "纳指100"
        case "SPX": return "标普500"
        case "IXIC": return "纳斯达克"
        default: return "不估算"
        }
    }

    private func changeTrack(_ opt: TrackOption) {
        Task {
            // 只有基金被删掉才会失败，这种情况下不弹错也无所谓
            try? await state.setTrack(code: code, track: opt.value)
            await reload()
        }
    }

    // MARK: - 分标签

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { t in
                let on = tab == t
                Button {
                    guard tab != t else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        tab = t
                    }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Theme.canvas : Theme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if on {
                                Capsule()
                                    .fill(Theme.ink)
                                    .matchedGeometryEffect(id: "detailTabPill", in: tabNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background {
            GlassSurface(shape: Capsule(), tint: 0.34)
        }
        .shadow(color: .black.opacity(0.07), radius: 12, x: 0, y: 5)
    }

    /// 吸顶的标签栏：滚动时内容从它下面穿过，所以垫一层毛玻璃
    private var tabHeader: some View {
        tabBar
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                if headerPinned {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(alignment: .bottom) {
                            Divider().opacity(0.4)
                        }
                        .transition(.opacity)
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabHeaderOffsetKey.self,
                        value: geo.frame(in: .named("detailScroll")).minY
                    )
                }
            }
    }

    @ViewBuilder
    private func content(_ f: FundItem) -> some View {
        switch tab {
        case .overview: overviewTab(f)
        case .trend:    trendTab(f)
        case .lots:     lotsTab(f)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 2)
    }

    // MARK: 概览：我这笔持仓怎么样

    @ViewBuilder
    private func overviewTab(_ f: FundItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("持仓数据")

            DetailCard {
                VStack(spacing: 0) {
                    statRow("累计投入") {
                        PrivacyText(text: Fmt.money(f.cost)).monospacedDigit()
                    }
                    rowDivider
                    statRow("持有份额") {
                        PrivacyText(text: Fmt.num(f.shares, 4)).monospacedDigit()
                    }
                    rowDivider
                    statRow("平均成本净值") {
                        PrivacyText(text: Fmt.num(f.avgCostNav, 4)).monospacedDigit()
                    }
                    rowDivider
                    statRow("最新净值") {
                        HStack(spacing: 6) {
                            Text(Fmt.num(f.nav, 4)).monospacedDigit()
                            Text(Fmt.pct(f.navChg))
                                .monospacedDigit()
                                .foregroundStyle(Fmt.tone(f.navChg))
                        }
                    }
                    rowDivider
                    statRow("净值日期") {
                        Text(f.navDate ?? "--").monospacedDigit()
                    }
                    rowDivider
                    statRow("资金加权年化") {
                        if let x = f.xirr, (f.xirrDays ?? 0) >= 30 {
                            PrivacyText(text: Fmt.pct(x * 100))
                                .monospacedDigit()
                                .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(x))
                        } else {
                            Text("持有满 30 天才算得准")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    rowDivider
                    statRow("记录笔数") {
                        Text("\(f.lotsCount) 笔")
                    }
                    rowDivider
                    statRow("定投计划") {
                        if let cur = currentPlanAmount(f) {
                            if cur > 0 {
                                Text(privacy.hidden ? "•••• / 交易日" : "¥\(Fmt.num(cur, 2)) / 交易日")
                                    .monospacedDigit()
                            } else {
                                Text("已停止").font(.footnote).foregroundStyle(.tertiary)
                            }
                        } else {
                            Text("未设置").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    if let sgzt = f.sgzt, !sgzt.isEmpty {
                        rowDivider
                        statRow("申购状态") {
                            Text(sgzt)
                                .font(.footnote)
                                .foregroundStyle(f.canBuy == false ? Color.orange : Color.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    rowDivider
                    statRow("首次买入") {
                        Text(f.firstBuy ?? "--").monospacedDigit()
                    }
                    rowDivider
                    statRow("最近买入") {
                        Text(f.lastBuy ?? "--").monospacedDigit()
                    }
                }
            }

            Text("估算依据：\(basis(f))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: 走势：这只基金本身表现如何

    @ViewBuilder
    private func trendTab(_ f: FundItem) -> some View {
        let visible = visibleSeries(f)
        let bounds = yBounds(visible, cost: f.avgCostNav)

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("净值走势")

                DetailCard {
                    VStack(spacing: 12) {
                        Picker("区间", selection: $range) {
                            ForEach(ChartRange.allCases) { r in
                                Text(r.rawValue).tag(r)
                            }
                        }
                        .pickerStyle(.segmented)

                        if visible.count > 1 {
                            priceChart(visible, fund: f, lo: bounds.0, hi: bounds.1)
                        } else {
                            Text("暂无走势数据")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160)
                        }

                        HStack(spacing: 6) {
                            Text("\(visible.count) 个交易日")
                            Spacer()
                            if let cost = f.avgCostNav {
                                Label(privacy.hidden ? "平均成本 ••••" : "平均成本 \(Fmt.num(cost, 4))",
                                      systemImage: "line.diagonal")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }

            if visible.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("区间统计")

                    DetailCard {
                        VStack(spacing: 0) {
                            statRow("区间涨跌") {
                                let chg = rangeChange(visible)
                                Text(Fmt.pct(chg))
                                    .monospacedDigit()
                                    .foregroundStyle(Fmt.tone(chg))
                            }
                            rowDivider
                            statRow("最高净值") {
                                Text(Fmt.num(visible.map(\.v).max(), 4)).monospacedDigit()
                            }
                            rowDivider
                            statRow("最低净值") {
                                Text(Fmt.num(visible.map(\.v).min(), 4)).monospacedDigit()
                            }
                            if let cost = f.avgCostNav, let last = visible.last?.v {
                                rowDivider
                                statRow("现价相对成本") {
                                    let gap = cost > 0 ? (last / cost - 1) * 100 : 0
                                    Text(Fmt.pct(gap))
                                        .monospacedDigit()
                                        .foregroundStyle(Fmt.tone(gap))
                                }
                            }
                        }
                    }

                    Text("区间：\(range.rawValue) · 涨跌只算净值本身，不含分红。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            if !f.perf.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("阶段涨幅")

                    DetailCard {
                        VStack(spacing: 0) {
                            ForEach(Array(["近1月", "近3月", "近6月", "近1年"].enumerated()),
                                    id: \.offset) { idx, key in
                                if idx > 0 { rowDivider }
                                statRow(key) {
                                    Text(Fmt.pct(f.perf[key]))
                                        .monospacedDigit()
                                        .foregroundStyle(Fmt.tone(f.perf[key]))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 明细：每一笔钱是什么时候、按什么净值买的

    @ViewBuilder
    private func lotsTab(_ f: FundItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("买入明细（共 \(f.lots.count) 笔）")

            if f.lots.isEmpty {
                DetailCard {
                    ContentUnavailableView {
                        Label("还没有买入记录", systemImage: "tray")
                    } description: {
                        Text("从右上角 ⋯ 里的「再买一笔」开始记")
                    } actions: {
                        Button("再买一笔") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 22)
                }
            } else {
                DetailCard {
                    VStack(spacing: 0) {
                        ForEach(Array(f.lots.reversed())) { lot in
                            LotRow(lot: lot)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            if lot.id != f.lots.first?.id {
                                rowDivider
                            }
                        }
                    }
                }
            }

            Text("「确认净值」是基金公司按你买入当天核算的净值（QDII 为 T 日净值，份额 T+2 可查）。份额 = 金额 ÷ 确认净值，未计申购费。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - 基础行

    private func statRow<Value: View>(_ label: String,
                                      @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 15.5))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            value()
                .font(.system(size: 15.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    // MARK: - 底部悬浮卡

    private func bottomCard(_ f: FundItem) -> some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 34, height: 4)
                .padding(.top, 2)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最新净值")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.num(f.nav, 4))
                            .font(.urbanist(32, .bold))
                            .tracking(-0.8)
                            .foregroundStyle(Theme.ink)
                        navChangeChip(f.navChg)
                    }

                    Text("\(f.navDate ?? "--") · \(f.code)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                Button {
                    showingNavInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("净值说明")
            }

            HStack(spacing: 10) {
                bottomButton("再买一笔", icon: "plus", primary: true) {
                    showingAdd = true
                }
                bottomButton("定投计划", icon: "repeat", primary: false) {
                    showingPlan = true
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background {
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: 28, style: .continuous),
                tint: 0.40,
                material: .ultraThinMaterial
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12),
                    radius: 22, x: 0, y: 8)
        }
        .alert("净值说明", isPresented: $showingNavInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(navInfo(f))
        }
    }

    /// 底部卡的 ⓘ：先讲官方净值，再讲盘中预估的依据，避免把「净值」和「估值」混为一谈
    private func navInfo(_ f: FundItem) -> String {
        var lines = [
            "最新净值 \(Fmt.num(f.nav, 4))，净值日期 \(f.navDate ?? "--")。",
            "官方净值由基金公司核算，QDII 通常滞后 1 个交易日。"
        ]
        if f.estPct != nil {
            lines.append("盘中预估依据：\(basis(f))。")
        }
        return lines.joined(separator: "\n")
    }

    private func navChangeChip(_ pct: Double?) -> some View {
        let tone = Fmt.tone(pct)
        return HStack(spacing: 2) {
            Image(systemName: (pct ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(Fmt.pct(pct))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.opacity(0.12), in: Capsule())
    }

    private func bottomButton(_ title: String, icon: String, primary: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primary ? Theme.canvas : Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(primary ? Theme.ink : Theme.canvas, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 顶部卡片

    private func heroCard(_ f: FundItem) -> some View {
        let estimated = f.estPct != nil
        let shownValue = (estimated ? (f.marketValue ?? 0) * (1 + (f.estPct ?? 0) / 100)
                                    : (f.marketValue ?? 0))

        return WalletCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    if estimated { ToneDot(value: f.estPct) }
                    CardCaption(text: f.name, size: 10.5)
                    Spacer(minLength: 8)
                    if let est = f.estPct {
                        Text(Fmt.pct(est))
                            .scaledFont(11, weight: .semibold, mono: true)
                            .foregroundStyle(Fmt.tone(est))
                    }
                }

                CardHeroValue(text: Fmt.money(shownValue), size: 36)

                HStack(spacing: 5) {
                    Text("累计收益")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PrivacyText(text: Fmt.signed(f.profit))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(f.profit))
                    PrivacyText(text: Fmt.pct(f.profitPct))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(f.profitPct))
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        CardCaption(text: "持有份额")
                        CardValue(text: Fmt.num(f.shares, 4), size: 15)
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 3) {
                        CardCaption(text: "平均成本净值")
                        CardValue(text: Fmt.num(f.avgCostNav, 4), size: 15)
                    }
                }

                Text(privacy.hidden
                     ? "\([f.code, f.platform].filter { !$0.isEmpty }.joined(separator: " · ")) · \(f.lotsCount) 笔买入 · 投入 ••••"
                     : "\([f.code, f.platform].filter { !$0.isEmpty }.joined(separator: " · ")) · \(f.lotsCount) 笔买入 · 投入 \(Fmt.money(f.cost))")
                    .scaledFont(10.5)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 估算依据：从哪个净值日累计到哪一天、β 多少、用多少样本校准的
    private func basis(_ f: FundItem) -> String {
        guard let src = f.estSrc, !src.isEmpty else { return "未设置 track" }
        var parts = [src]
        if let b = f.estBeta {
            parts.append("β \(Fmt.num(b, 3))")
        }
        if let n = f.estBetaN, n > 0 {
            parts.append("\(n) 日校准")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 图表

    private func priceChart(_ pts: [SeriesPoint], fund f: FundItem, lo: Double, hi: Double) -> some View {
        let rising = (pts.last?.v ?? 0) >= (pts.first?.v ?? 0)
        let col = rising ? Color.red : Color.green

        return Chart {
            ForEach(pts) { p in
                AreaMark(
                    x: .value("日期", p.date),
                    y: .value("净值", p.v)
                )
                .foregroundStyle(
                    LinearGradient(colors: [col.opacity(0.25), col.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日期", p.date),
                    y: .value("净值", p.v)
                )
                .foregroundStyle(col)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }

            if let cost = f.avgCostNav, cost > lo, cost < hi, !privacy.hidden {
                RuleMark(y: .value("平均成本", cost))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .annotation(position: .topTrailing, spacing: 2) {
                        Text("成本")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 220)
        // List / ScrollView 里 Chart 的绘图区会超出自身 frame，裁掉才不会盖住下面的说明
        .clipped()
    }

    // MARK: - 计算

    private func visibleSeries(_ f: FundItem) -> [SeriesPoint] {
        let n = range.points
        guard n > 0, f.series.count > n else { return f.series }
        return Array(f.series.suffix(n))
    }

    /// 区间涨跌（%）：只看首尾净值，不折算分红
    private func rangeChange(_ pts: [SeriesPoint]) -> Double? {
        guard let first = pts.first?.v, let last = pts.last?.v, first != 0 else { return nil }
        return (last / first - 1) * 100
    }

    private func yBounds(_ pts: [SeriesPoint], cost: Double?) -> (Double, Double) {
        var vals = pts.map(\.v)
        if let c = cost { vals.append(c) }
        guard let mn = vals.min(), let mx = vals.max() else { return (0, 1) }
        let raw = mx - mn
        let pad = raw == 0 ? max(abs(mx) * 0.02, 0.001) : raw * 0.08
        return (mn - pad, mx + pad)
    }
}

// MARK: - 卡片 & 吸顶检测

private struct DetailCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GlassSurface(
                    shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                    tint: 0.46
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.06),
                    radius: scheme == .dark ? 20 : 16, x: 0, y: 7)
    }
}

private struct TabHeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - 买入明细行

private struct LotRow: View {
    let lot: Lot
    @EnvironmentObject private var privacy: PrivacyMode

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lot.date)
                    .font(.subheadline)
                Text(privacy.hidden
                     ? "净值 \(Fmt.num(lot.nav, 4)) · 份额 ••••"
                     : "净值 \(Fmt.num(lot.nav, 4)) · 份额 \(Fmt.num(lot.shares, 4))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    if lot.amount < 0 {
                        Text("卖出")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    PrivacyText(text: Fmt.money(abs(lot.amount)))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(lot.amount < 0 ? Color.secondary : Color.primary)
                }
                if lot.amount >= 0 {
                    PrivacyText(text: lot.profit == nil ? "--" : Fmt.signed(lot.profit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(lot.profit))
                } else {
                    Text("赎回")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
