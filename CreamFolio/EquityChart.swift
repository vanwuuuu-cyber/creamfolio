import SwiftUI
import Charts

/// 账户收益走势：市值 vs 累计投入
///
/// 数据是后端「按每日净值反推」出来的，不是每天定时记录的快照 ——
/// 任意历史日期都能算，不需要 App 一直开着。
struct EquityCurveCard: View {
    let curve: Curve
    let xirr: Double?
    let xirrDays: Int
    var maxDrawdown: Double? = nil
    var maxDrawdownDate: String? = nil
    var volatility: Double? = nil

    @State private var range: Span = .all
    @EnvironmentObject private var privacy: PrivacyMode

    enum Span: String, CaseIterable, Identifiable {
        case month = "1月"
        case quarter = "3月"
        case all = "全部"

        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .month: return 30
            case .quarter: return 90
            case .all: return nil
            }
        }
    }

    private struct Pt: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let kind: String
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    /// 轴上只显示「10-08」这种短日期，不跟随系统语言
    private static let axisDF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    // MARK: - 数据切片

    private var slice: (dates: [String], mv: [Double], cost: [Double]) {
        guard let days = range.days,
              let last = curve.dates.last,
              let end = Self.df.date(from: last) else {
            return (curve.dates, curve.mv, curve.cost)
        }
        let cut = end.addingTimeInterval(-Double(days) * 86400)
        var d: [String] = []
        var m: [Double] = []
        var c: [Double] = []
        for i in curve.dates.indices {
            if let dt = Self.df.date(from: curve.dates[i]), dt >= cut {
                d.append(curve.dates[i])
                m.append(curve.mv[i])
                c.append(curve.cost[i])
            }
        }
        // 区间内没点时至少留最后一个，否则图会空掉
        if d.isEmpty && !curve.dates.isEmpty {
            return (Array(curve.dates.suffix(1)),
                    Array(curve.mv.suffix(1)),
                    Array(curve.cost.suffix(1)))
        }
        return (d, m, c)
    }

    private var points: [Pt] {
        let s = slice
        var out: [Pt] = []
        for i in s.dates.indices {
            guard let dt = Self.df.date(from: s.dates[i]) else { continue }
            out.append(Pt(id: "m\(i)", date: dt, value: s.mv[i], kind: "市值"))
            out.append(Pt(id: "c\(i)", date: dt, value: s.cost[i], kind: "投入"))
        }
        return out
    }

    /// 最大回撤 + 年化波动率：用剔除现金流后的日收益算，避免加仓日被当成大涨
    private var risk: (dd: Double, vol: Double?)? {
        let d = curve.dates, mv = curve.mv, cost = curve.cost
        guard d.count > 3, mv.count == d.count, cost.count == d.count else { return nil }
        var peak = 0.0, dd = 0.0
        var prevMV = 0.0, prevCost = 0.0
        var rets: [Double] = []
        for i in d.indices {
            if mv[i] > peak { peak = mv[i] }
            if peak > 0 { dd = min(dd, (mv[i] - peak) / peak) }
            if i > 0, prevMV > 0, cost[i] > 0 {
                rets.append((mv[i] - prevMV - (cost[i] - prevCost)) / prevMV)
            }
            prevMV = mv[i]; prevCost = cost[i]
        }
        var vol: Double?
        if rets.count > 5 {
            let n = Double(rets.count)
            let mean = rets.reduce(0, +) / n
            let v = rets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
            vol = v.squareRoot() * (250.0).squareRoot() * 100
        }
        return (dd * 100, vol)
    }

    private var shortSample: Bool { xirrDays < 30 }
    private var showPicker: Bool { curve.dates.count > 5 }

    /// Y 轴贴着数据走，别让几千块的账户被拉到 2000 的高度
    private var maxY: Double {
        let s = slice
        let top = max(s.mv.max() ?? 0, s.cost.max() ?? 0)
        return top > 0 ? top * 1.18 : 1
    }

    // MARK: - 视图

    var body: some View {
        WalletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CardCaption(text: "收益走势")
                    Spacer(minLength: 8)
                    if showPicker { spanPicker }
                }
                annualized
                if let r = risk {
                    HStack(spacing: 10) {
                        Label(privacy.hidden ? "最大回撤 ••••" : "最大回撤 \(Fmt.pct(r.dd))",
                              systemImage: "arrow.down.right")
                        if let v = r.vol {
                            Text(privacy.hidden ? "波动率 ••••" : "波动率 \(String(format: "%.2f", v))%")
                        }
                    }
                    .scaledFont(10)
                    .foregroundStyle(.tertiary)
                }
                chart
            }
        }
    }

    @ViewBuilder
    private var annualized: some View {
        if shortSample {
            Text("只投了 \(xirrDays) 天，年化会严重失真，别当真")
                .scaledFont(10.5)
                .foregroundStyle(.tertiary)
        } else if let x = xirr {
            HStack(spacing: 4) {
                Text("年化")
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
                PrivacyText(text: Fmt.pct(x * 100))
                    .scaledFont(15, weight: .semibold, design: .rounded, mono: true)
                    .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(x))
                Text("· \(xirrDays) 天")
                    .scaledFont(10.5)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var chart: some View {
        Chart(points) { p in
            AreaMark(
                x: .value("日期", p.date),
                y: .value("金额", p.value)
            )
            .foregroundStyle(by: .value("类型", p.kind))
            .opacity(p.kind == "市值" ? 0.10 : 0)

            LineMark(
                x: .value("日期", p.date),
                y: .value("金额", p.value)
            )
            .foregroundStyle(by: .value("类型", p.kind))
            .lineStyle(StrokeStyle(
                lineWidth: p.kind == "市值" ? 2 : 1.5,
                lineCap: .round,
                lineJoin: .round,
                dash: p.kind == "投入" ? [4, 3] : []
            ))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            "市值": Color.accentColor,
            "投入": Color.secondary,
        ])
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .chartYScale(domain: 0...maxY)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(Self.axisDF.string(from: d))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(privacy.hidden ? "•••" : String(format: "%.0f", d))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private var spanPicker: some View {
        Picker("区间", selection: $range) {
            ForEach(Span.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .frame(width: 140)
    }
}
