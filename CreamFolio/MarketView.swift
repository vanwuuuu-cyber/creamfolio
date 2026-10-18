import SwiftUI

struct MarketView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
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
            .navigationTitle("行情")
            .refreshable { await state.load() }
        }
    }

    @ViewBuilder
    private func content(_ d: Dashboard) -> some View {
        let m = d.market

        Section {
            glassQuote("纳斯达克 100", m.ndx)
            glassQuote("标普 500", m.spx)
            glassQuote("纳斯达克综合", m.ixic)
        } header: {
            Text("指数")
        } footer: {
            Text("已收盘的官方数值。")
        }

        Section {
            glassQuote("纳指 100 期货", m.nq)
            glassQuote("标普 500 期货", m.es)
        } header: {
            Text("外盘期货")
        } footer: {
            Text("A 股交易时段美股已休市，期货仍在交易，是判断「今晚大概怎么走」的主要依据。")
        }

        Section("汇率") {
            glassQuote("美元 / 人民币", m.usdcny, isFX: true)
        }

        Section {
            if d.funds.isEmpty {
                ContentUnavailableView {
                    Label("还没有持仓", systemImage: "chart.pie")
                }
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(d.funds) { f in
                    GlassRow {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text(basis(f))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 10)
                            Text(Fmt.pct(f.estPct))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Fmt.tone(f.estPct))
                        }
                    }
                    .glassListRow()
                }
            }
        } header: {
            Text("我的基金预估")
        } footer: {
            Text("本工具按「指数（A股时段取期货）涨跌 × 仓位系数 + 当日汇率变动」合成，不是基金公司公布的官方估值。")
        }

        Section("关于这个预估") {
            GlassRow(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                explain("为什么没有「实时估值」？",
                        "QDII 基金投的是美股。A 股交易时段美股在休市，净值要等美股收盘后由托管行核算、基金公司复核才能公布，所以净值天然滞后 1 个交易日。天天基金等平台的实时估值模型对 QDII 直接返回空值。")
                explain("预估是怎么算的",
                        "从「最新净值日」的指数收盘，累计到最新收盘（中间每天连乘），再叠加当前盘中的期货涨跌；乘上这只基金自己的 β，加上同期美元兑人民币变动。β 用最近 60 个交易日回归自动校准，所以每只基金不完全一样。")
                explain("为什么不是「今天的涨跌」",
                        "QDII 净值常常滞后 1~2 个交易日。如果只算今天一天，就会漏掉前面一两场 —— 实测滞后 2 天时误差会到 0.7 个百分点，改成累计连乘后降到 0.07。")
                    explain("数据来源",
                            "净值与走势：天天基金（东方财富）；美股指数日线：腾讯财经（东财兜底）；实时指数 / 期货 / 汇率：新浪财经。只读取公开行情，不涉及任何基金账号信息。")
                }
                .padding(.vertical, 4)
            }
            .glassListRow()
        }
    }

    private func glassQuote(_ title: String, _ quote: MarketQuote?, isFX: Bool = false) -> some View {
        GlassRow {
            QuoteRow(title: title, quote: quote, isFX: isFX)
        }
        .glassListRow()
    }

    private func basis(_ f: FundItem) -> String {
        guard let src = f.estSrc, !src.isEmpty else { return "未设置 track" }
        var parts = [src]
        if let b = f.estBeta {
            parts.append("β \(Fmt.num(b, 3))")
        }
        return parts.joined(separator: " · ")
    }

    private func explain(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
