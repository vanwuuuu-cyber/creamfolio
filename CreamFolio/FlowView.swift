import SwiftUI

struct FlowView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var privacy: PrivacyMode

    var body: some View {
        // 从持仓页 push 进来，不要再套一层 NavigationStack
        List {
            if let d = state.dashboard {
                content(d)
            } else if let err = state.errorMessage {
                Section { InlineError(text: err) }
            } else {
                Section {
                    RisingChartLoader()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .brandPage()
        .contentMargins(.bottom, 92, for: .scrollContent)
        .navigationTitle("流水")
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await state.load() }
    }

    @ViewBuilder
    private func content(_ d: Dashboard) -> some View {
        let s = d.summary

        Section {
            WalletCard {
                VStack(alignment: .leading, spacing: 9) {
                    CardCaption(text: "累计投入")

                    CardHeroValue(text: Fmt.money(s.cost), size: 38)

                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            CardCaption(text: "记录笔数")
                            CardValue(text: "\(s.lotsCount) 笔", size: 15, sensitive: false)
                        }
                        Spacer(minLength: 10)
                        VStack(alignment: .trailing, spacing: 3) {
                            CardCaption(text: "平均每笔")
                            CardValue(text: Fmt.money(s.lotsCount > 0 ? s.cost / Double(s.lotsCount) : 0), size: 15)
                        }
                    }

                    Text(privacy.hidden
                         ? "本月已投入 ••••（\(s.monthCount) 笔）"
                         : "本月已投入 \(Fmt.money(s.monthAmount))（\(s.monthCount) 笔）")
                        .scaledFont(10.5)
                        .foregroundStyle(.tertiary)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        let groups = DaySection.group(d.transactions)

        if groups.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("还没有买入记录", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("在持仓页点击 + 记第一笔")
                }
                .listRowInsets(EdgeInsets())
            }
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { t in
                        GlassRow {
                            TransactionRow(item: t)
                        }
                        .glassListRow()
                    }
                } header: {
                    HStack {
                        Text("\(group.date) \(Fmt.weekday(group.date))")
                        Spacer()
                        Text(privacy.hidden
                             ? "•••• · \(group.items.count) 笔"
                             : "\(Fmt.money(group.total)) · \(group.items.count) 笔")
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - 按日期分组

struct DaySection: Identifiable {
    let date: String
    let items: [Transaction]

    var id: String { date }
    var total: Double { items.reduce(0) { $0 + $1.amount } }

    /// 保持服务端给的时间倒序，同一天合并成一个 Section
    static func group(_ tx: [Transaction]) -> [DaySection] {
        var order: [String] = []
        var map: [String: [Transaction]] = [:]
        for t in tx {
            if map[t.date] == nil { order.append(t.date) }
            map[t.date, default: []].append(t)
        }
        return order.map { DaySection(date: $0, items: map[$0] ?? []) }
    }
}

// MARK: - 单笔

private struct TransactionRow: View {
    let item: Transaction

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(item.platform) · \(item.code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                PrivacyText(text: Fmt.money(item.amount))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                Text("净值 \(Fmt.num(item.nav, 4))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
