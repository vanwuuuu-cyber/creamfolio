import SwiftUI

/// 在 App 内添加持仓。三种模式：
///   1. 输入代码   —— 只填「基金代码 + 金额」，最快，适合买完立刻记一笔
///   2. 选择基金   —— 从已持有的基金里挑，再填金额
///   3. 直接填份额 —— 懒得记每一笔，只维护「我持有多少份」
struct AddEntryView: View {
    /// 从基金详情页进来时，预填好这只基金
    var presetCode: String? = nil

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case code = "输入代码"
        case pick = "选择基金"
        case manual = "直接填份额"
        var id: String { rawValue }
    }

    enum Field: Hashable { case code, search, amount, shares, cost, platform }

    /// 跟踪哪个指数（决定净值预估跟着谁走）
    enum TrackChoice: String, CaseIterable, Identifiable {
        case auto = "auto"
        case ndx = "NDX"
        case spx = "SPX"
        case off = "off"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "自动"
            case .ndx: return "纳指100"
            case .spx: return "标普500"
            case .off: return "不估算"
            }
        }
        /// 写进 holdings.json 的值；nil 表示交给自动识别
        var stored: String? {
            switch self {
            case .auto: return nil
            case .ndx: return "NDX"
            case .spx: return "SPX"
            case .off: return ""
            }
        }
    }

    /// 买还是卖
    enum Side: String, CaseIterable, Identifiable {
        case buy = "买入"
        case sell = "卖出"
        var id: String { rawValue }
    }

    @State private var side: Side = .buy
    @State private var mode: Mode = .code

    // 输入代码模式
    @State private var codeText = ""
    @State private var resolved: FundSearchResult?
    @State private var codeError: String?
    @State private var resolving = false
    @State private var resolveTask: Task<Void, Never>?

    // 选择基金模式
    @State private var searchText = ""
    @State private var results: [FundSearchResult] = []
    @State private var searching = false
    @State private var selected: FundSearchResult?
    @State private var searchTask: Task<Void, Never>?

    // 金额 / 份额
    @State private var amountText = ""
    @State private var sharesText = ""
    @State private var costText = ""
    @State private var date = Date()

    /// 买入平台：支付宝 / 天天基金 / 各家基金公司 App
    @State private var platformText = ""

    /// 跟踪指数：默认交给自动识别
    @State private var trackChoice: TrackChoice = .auto

    @State private var saving = false
    @State private var errorText: String?

    @FocusState private var focus: Field?

    private let quickAmounts: [Double] = [5, 10, 20, 50]

    // MARK: - 派生

    private var heldFunds: [FundSearchResult] {
        (state.dashboard?.funds ?? []).map {
            FundSearchResult(code: $0.code, name: $0.name,
                             type: $0.track, company: $0.platform)
        }
    }

    private var shownFunds: [FundSearchResult] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? heldFunds : results
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private var canSave: Bool {
        guard !saving else { return false }
        switch mode {
        case .code:
            return codeText.count == 6 && codeError == nil && (Double(amountText) ?? 0) > 0
        case .pick:
            return selected != nil && (Double(amountText) ?? 0) > 0
        case .manual:
            return selected != nil && (Double(sharesText) ?? 0) > 0
        }
    }

    // MARK: - 界面

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("买还是卖", selection: $side) {
                        ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
                }

                Section {
                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }

                if mode == .code {
                    codeSection
                } else {
                    fundSection
                }

                if mode == .manual && side == .buy {
                    manualSection
                } else {
                    amountSection
                }

                platformSection
                trackSection

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加持仓")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("保存").bold() }
                    }
                    .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focus = nil }
                }
            }
            .onAppear(perform: preselect)
            .onChange(of: searchText) { _, q in scheduleSearch(q) }
            .onChange(of: side) { _, v in
                // 「直接填份额」是整体覆盖，和卖出语义冲突
                if v == .sell && mode == .manual { mode = .code }
            }
        }
    }

    // MARK: - 输入代码

    @ViewBuilder
    private var codeSection: some View {
        Section {
            HStack {
                Text("基金代码")
                Spacer()
                TextField("6 位数字", text: $codeText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: .code)
                    .frame(maxWidth: 150)
                    .onChange(of: codeText) { _, raw in
                        let digits = String(raw.filter { $0.isNumber }.prefix(6))
                        if digits != raw { codeText = digits }
                        scheduleResolve(digits)
                    }
            }

            if resolving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("查询中…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let codeError {
                Text(codeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let r = resolved {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.subheadline)
                    Text([r.code, r.company].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("基金")
        } footer: {
            Text("填 6 位基金代码，会自动显示基金名称确认。没有的基金会自动加入持仓。")
        }
    }

    // MARK: - 选择基金

    @ViewBuilder
    private var fundSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索基金名称或代码", text: $searchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .search)
                if searching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        focus = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if shownFunds.isEmpty {
                Text(searchText.isEmpty ? "还没有持仓，搜索一只基金开始" : "没搜到，换个关键词试试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(shownFunds) { f in
                Button {
                    selected = f
                    if platformText.isEmpty { platformText = f.company }
                    focus = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text([f.code, f.company].filter { !$0.isEmpty }
                                    .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected?.code == f.code {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("选择基金")
        } footer: {
            if let s = selected {
                Text("已选：\(s.name)（\(s.code)）")
            } else {
                Text("从已持有的基金里选，或搜索一只新的。")
            }
        }
    }

    // MARK: - 金额 / 份额

    private var amountSection: some View {
        Section {
            DatePicker("日期", selection: $date, displayedComponents: .date)
                .environment(\.locale, Locale(identifier: "zh_CN"))

            HStack {
                Text(side == .buy ? "金额" : "赎回金额")
                Spacer()
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: .amount)
                    .frame(maxWidth: 110)
                Text("元").foregroundStyle(.secondary)
            }

            if side == .buy {
                HStack(spacing: 8) {
                    ForEach(quickAmounts, id: \.self) { v in
                        Button("¥\(Int(v))") {
                            amountText = String(Int(v))
                            focus = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Text("赎回份额")
                    Spacer()
                    TextField("可留空", text: $sharesText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($focus, equals: .shares)
                        .frame(maxWidth: 110)
                    Text("份").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(side == .buy ? "买入信息" : "卖出信息")
        } footer: {
            if side == .sell {
                Text("填了份额会按份额校验，避免卖超；留空则按「赎回金额 ÷ 当天净值」折算。")
            }
        }
    }

    private var manualSection: some View {
        Section {
            HStack {
                Text("持有份额")
                Spacer()
                TextField("0.0000", text: $sharesText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: .shares)
                    .frame(maxWidth: 130)
            }
            HStack {
                Text("累计投入")
                Spacer()
                TextField("选填", text: $costText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: .cost)
                    .frame(maxWidth: 110)
                Text("元").foregroundStyle(.secondary)
            }
        } header: {
            Text("持仓")
        } footer: {
            Text("填了份额后，看板直接用这个数，不再按买入记录推算。累计投入留空则按买入记录里的总额计。")
        }
    }

    // MARK: - 行为

    // MARK: - 买入平台

    /// 常用平台：固定给两个 + 你已经用过的（排除「未标注」）
    private var platformChoices: [String] {
        var out = ["支付宝", "天天基金"]
        for p in (state.dashboard?.platforms ?? []).map(\.platform)
        where !p.isEmpty && p != "未标注" && !out.contains(p) {
            out.append(p)
        }
        return out
    }

    /// 用户没填就退回基金公司的名字，保持以前的行为
    private var effectivePlatform: String {
        let t = platformText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return resolved?.company ?? selected?.company ?? ""
    }

    private func isHeld(_ code: String) -> Bool {
        (state.dashboard?.funds ?? []).contains { $0.code == code }
    }

    @ViewBuilder
    private var platformSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(platformChoices, id: \.self) { p in
                        let on = (effectivePlatform == p)
                        Button {
                            platformText = p
                        } label: {
                            Text(p)
                                .font(.footnote.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    on ? Color.accentColor : Color.primary.opacity(0.07),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            TextField("买入平台，比如「支付宝」", text: $platformText)
                .autocorrectionDisabled(true)
                .focused($focus, equals: .platform)
                .submitLabel(.done)
                .onSubmit { focus = nil }
        } header: {
            Text("在哪儿买的")
        } footer: {
            Text("这只基金归到哪个平台。同一只基金只归一个平台；两边都买过的话，建议分开记成两只。")
        }
    }

    @ViewBuilder
    private var trackSection: some View {
        Section {
            Picker("跟踪指数", selection: $trackChoice) {
                ForEach(TrackChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("跟踪指数")
        } footer: {
            Text("决定「下一份净值预估」跟着哪个指数算。自动 = 按基金名字识别（纳指 / 标普）。选「不估算」它就不参与预估，其余数字照常。")
        }
    }

    /// 买 / 卖 分流
    private func submit(code: String, amount: Double) async throws {
        if side == .buy {
            try await ensureFund(code: code)
            try await state.addBuy(code: code, amount: amount, date: dateString)
        } else {
            guard isHeld(code) else {
                throw HoldingsError.message("还没有这只基金的持仓，不能卖出")
            }
            let sh = Double(sharesText.trimmingCharacters(in: .whitespacesAndNewlines))
            try await state.addSell(code: code, amount: amount, date: dateString, shares: sh)
        }
    }

    /// 需要时才建基金；顺便把跟踪指数改掉
    private func ensureFund(code: String) async throws {
        if !isHeld(code) {
            try await state.addFund(code: code, platform: effectivePlatform)
        }
        if let t = trackChoice.stored {
            try await state.setTrack(code: code, track: t)
        }
    }

    private func preselect() {
        guard let c = presetCode, !c.isEmpty else { return }
        mode = .code
        codeText = c
        scheduleResolve(c)
    }

    /// 6 位代码 → 查一次名称
    private func scheduleResolve(_ text: String) {
        resolveTask?.cancel()
        resolved = nil
        codeError = nil
        guard text.count == 6 else {
            resolving = false
            return
        }
        resolving = true
        resolveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let rs = try await state.searchFunds(text)
                if let hit = rs.first(where: { $0.code == text }) {
                    resolved = hit
                    if platformText.isEmpty { platformText = hit.company }
                } else {
                    codeError = "查不到这个基金代码"
                }
            } catch {
                codeError = error.localizedDescription
            }
            resolving = false
        }
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let kw = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            results = []
            searching = false
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            searching = true
            do {
                let r = try await state.searchFunds(kw)
                if !Task.isCancelled { results = r }
            } catch {
                if !Task.isCancelled { results = [] }
            }
            searching = false
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        focus = nil

        do {
            switch mode {
            case .code:
                let code = codeText.trimmingCharacters(in: .whitespaces)
                guard code.count == 6, let amt = Double(amountText), amt > 0 else {
                    errorText = "请填 6 位基金代码，金额要大于 0"
                    saving = false
                    return
                }
                try await submit(code: code, amount: amt)

            case .pick:
                guard let f = selected, let amt = Double(amountText), amt > 0 else {
                    errorText = "请选择基金，金额要大于 0"
                    saving = false
                    return
                }
                try await submit(code: f.code, amount: amt)

            case .manual:
                guard let f = selected, let sh = Double(sharesText), sh > 0 else {
                    errorText = "请选择基金，份额要大于 0"
                    saving = false
                    return
                }
                try await ensureFund(code: f.code)
                try await state.setManual(code: f.code, shares: sh, cost: Double(costText))
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        saving = false
    }
}
