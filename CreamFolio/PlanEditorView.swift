import SwiftUI

/// 定投计划编辑器。
///
/// 计划是「按生效日期分段」的：每一段从 start 那天起，每个交易日按 amount 买入，
/// 直到下一个生效段。改金额 = 加一段新的，历史记录不受影响。
struct PlanEditorView: View {
    let code: String

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var start = Date()
    @State private var amountText = ""
    @State private var saving = false
    @State private var errorText: String?

    private var fund: FundItem? {
        state.dashboard?.funds.first { $0.code == code }
    }

    private var plans: [FundPlan] {
        (fund?.plans ?? []).sorted { $0.start < $1.start }
    }

    private var skips: [String] {
        (fund?.skips ?? []).sorted()
    }

    /// 今天适用的金额（最后一段 start <= 今天）
    private var currentAmount: Double? {
        let today = Self.df.string(from: Date())
        return plans.last(where: { $0.start <= today })?.amount
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private var startString: String { Self.df.string(from: start) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if plans.isEmpty {
                        Text("还没有定投计划")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(plans) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(p.start) 起")
                                        .font(.subheadline)
                                        .monospacedDigit()
                                    if p.start == plans.last?.start, let cur = currentAmount {
                                        Text(cur > 0
                                             ? "当前生效 ¥\(Fmt.num(cur, 2)) / 交易日"
                                             : "当前已停止")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if p.amount > 0 {
                                    Text(Fmt.money(p.amount))
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                } else {
                                    Text("停止")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in
                            Task { await delete(idx) }
                        }
                    }
                } header: {
                    Text("当前计划")
                } footer: {
                    Text("每个交易日按当天真实净值买入，周末和节假日自动跳过。左滑可以删除某一段。")
                }

                if !skips.isEmpty {
                    Section {
                        ForEach(skips, id: \.self) { d in
                            HStack {
                                Text(d).monospacedDigit()
                                Spacer()
                                Text("没买成")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .onDelete { idx in
                            Task { await restore(idx) }
                        }
                    } header: {
                        Text("例外日期（\(skips.count) 天）")
                    } footer: {
                        Text("这几天计划本该买，但实际没买成（余额不足、限额、系统故障）。\n左滑可以恢复 —— 恢复后那天会自动重新生成记录。")
                    }
                }

                Section {
                    DatePicker("生效日期", selection: $start, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "zh_CN"))

                    HStack {
                        Text("每交易日金额（0 = 停止）")
                        Spacer()
                        TextField("10", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(maxWidth: 110)
                        Text("元").foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Text("保存这一段")
                            if saving { Spacer(); ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(saving || Double(amountText) == nil || (Double(amountText) ?? -1) < 0)

                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("新增 / 修改生效段")
                } footer: {
                    Text("想改金额？选一个生效日期填新金额，历史记录不受影响。\n想停止（比如基金暂停申购、外汇额度用完）？填 0 再存一段就行。同一天再存一次会覆盖那一段。")
                }

                Section {
                    Text("已经手动记过的买入日期不会被重复生成 —— 所以从手记切到定投不会算两遍。")
                        .font(.caption)
                }
            }
            .navigationTitle("定投计划")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { hideKeyboard() }
                }
            }
            .onAppear { prefillIfNeeded() }
            // 数据比弹窗晚到齐时再补一次（比如冷启动直接进详情页）
            .onChange(of: plans.count) { _, _ in prefillIfNeeded() }
        }
    }

    private func prefillIfNeeded() {
        guard amountText.isEmpty, let cur = currentAmount, cur > 0 else { return }
        amountText = String(format: "%.0f", cur)
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func save() async {
        guard let amt = Double(amountText), amt >= 0 else {
            errorText = "金额不能为负（填 0 表示停止）"
            return
        }
        saving = true
        errorText = nil
        do {
            try await state.addPlan(code: code, start: startString, amount: amt)
            amountText = ""
        } catch {
            errorText = error.localizedDescription
        }
        saving = false
    }

    private func restore(_ offsets: IndexSet) async {
        for i in offsets {
            guard skips.indices.contains(i) else { continue }
            do {
                try await state.removeSkip(code: code, date: skips[i])
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func delete(_ offsets: IndexSet) async {
        for i in offsets {
            guard plans.indices.contains(i) else { continue }
            let p = plans[i]
            do {
                try await state.removePlan(code: code, start: p.start)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
