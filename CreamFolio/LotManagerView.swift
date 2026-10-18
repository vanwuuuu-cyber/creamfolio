import SwiftUI

/// 管理某只基金的买入记录：左滑删除、右上角追加一笔。
/// 用标准的 List + onDelete，交互和系统一致。
struct LotManagerView: View {
    let code: String

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var fund: FundItem?
    @State private var errorText: String?
    @State private var showingAdd = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if let f = fund {
                    if f.lots.isEmpty {
                        Text("这只基金还没有买入记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Section {
                            ForEach(Array(f.lots.reversed())) { lot in
                                row(lot)
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text("共 \(f.lots.count) 笔 · 左滑可删除")
                        } footer: {
                            Text("合计投入 \(Fmt.money(f.cost)) · 持有份额 \(Fmt.num(f.shares, 4))"
                                 + (f.avgCostNav == nil ? "" : " · 平均成本 \(Fmt.num(f.avgCostNav, 4))"))
                        }
                    }
                } else if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("加载中…").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(fund?.name ?? "买入记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("再买一笔")
                }
            }
            .sheet(isPresented: $showingAdd, onDismiss: { Task { await reload() } }) {
                AddEntryView(presetCode: code).environmentObject(state)
            }
            .task { await reload() }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.18), in: Capsule())
    }

    private func row(_ lot: Lot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(lot.date)
                    .font(.subheadline.weight(.medium))
                if lot.amount < 0 {
                    tag("卖出")
                } else if lot.auto == true {
                    tag("定投")
                }
                Spacer()
                Text(Fmt.money(abs(lot.amount)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(lot.amount < 0 ? Color.secondary : Color.primary)
            }
            HStack {
                Text("净值 \(Fmt.num(lot.nav, 4)) · 份额 \(Fmt.num(lot.shares, 4))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lot.amount < 0 ? "" : (lot.profit == nil ? "--" : Fmt.signed(lot.profit)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Fmt.tone(lot.profit))
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        do {
            fund = try await state.fundDetail(code: code)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        guard let f = fund else { return }
        let lots = Array(f.lots.reversed())
        let targets = offsets.compactMap { $0 < lots.count ? lots[$0] : nil }
        guard !targets.isEmpty else { return }

        busy = true
        Task {
            for lot in targets {
                if lot.auto == true {
                    // 定投生成的记录：删掉 = 「这天其实没买成」，记进例外日期，以后不会再生成
                    try? await state.addSkip(code: code, date: lot.date)
                } else {
                    try? await state.removeLot(code: code, date: lot.date, amount: lot.amount)
                }
            }
            await reload()
            busy = false
        }
    }
}
