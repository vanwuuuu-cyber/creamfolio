import SwiftUI

/// 收益日历：按 日 / 周 / 月 / 年 看每个周期的盈亏。
///
/// 数据不用后端额外提供 —— 直接用 `curve`（每日市值 + 累计投入）反推：
///   当天盈亏 = 市值变化 − 当天新增投入
/// 减去投入增量这一步很关键，否则「买入那天」会被误算成赚了一大笔。
/// 周 / 月 / 年 都是在这个日序列上做求和。
struct ProfitCalendarView: View {
    @EnvironmentObject private var privacy: PrivacyMode
    @EnvironmentObject var state: AppState

    @State private var mode: Mode = {
        // 调试用：FB_CAL=week|month|year 直接进对应视图
        switch DebugHooks.env("FB_CAL") ?? "" {
        case "week": return .week
        case "month": return .month
        case "year": return .year
        default: return .day
        }
    }()
    @State private var offset: Int = {
        // 调试用：FB_CAL_OFFSET=-1 启动时停在上一个周期
        Int(DebugHooks.env("FB_CAL_OFFSET") ?? "") ?? 0
    }()
    @State private var unit: Unit = .money

    enum Mode: String, CaseIterable, Identifiable {
        case day = "日", week = "周", month = "月", year = "年"
        var id: String { rawValue }
        /// 一个格子 / 一行代表一个周期
        var isGrid: Bool { self == .day || self == .month }
    }

    enum Unit: String, CaseIterable, Identifiable {
        case money = "¥", percent = "%"
        var id: String { rawValue }
    }

    /// 一个聚合周期（周 / 月 / 年）
    private struct Bucket: Identifiable {
        let id: String
        let title: String
        let pnl: Double
        let days: Int
        let base: Double
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 1                       // 周日排第一列
        return c
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private static let mdDF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    // MARK: - 基础数据

    /// 日期 → (当天盈亏, 当天开始时的市值)
    private func dailyMap(_ curve: Curve) -> [String: (pnl: Double, base: Double, cost: Double)] {
        var out: [String: (pnl: Double, base: Double, cost: Double)] = [:]
        var prevMV = 0.0
        var prevCost = 0.0
        for i in curve.dates.indices {
            let mv = curve.mv[i]
            let cost = curve.cost[i]
            out[curve.dates[i]] = (mv - prevMV - (cost - prevCost), prevMV, cost)
            prevMV = mv
            prevCost = cost
        }
        return out
    }

    /// 当前锚点：日/周按月翻，月/年按年翻
    private var anchor: Date {
        let comps: Set<Calendar.Component> = (mode == .day || mode == .week)
            ? [.year, .month] : [.year]
        let unit: Calendar.Component = (mode == .day || mode == .week) ? .month : .year
        let base = calendar.date(from: calendar.dateComponents(comps, from: Date()))!
        return calendar.date(byAdding: unit, value: offset, to: base)!
    }

    private var title: String {
        let c = calendar.dateComponents([.year, .month], from: anchor)
        if mode == .day || mode == .week {
            return "\(c.year ?? 0) 年 \(c.month ?? 0) 月"
        }
        return "\(c.year ?? 0) 年"
    }

    /// 显示周期的合计
    private var periodTotal: (pnl: Double, base: Double) {
        guard let curve = state.dashboard?.curve else { return (0, 0) }
        let map = dailyMap(curve)
        var pnl = 0.0, base = 0.0
        for (key, hit) in map {
            guard let d = Self.df.date(from: key) else { continue }
            if isInPeriod(d) {
                pnl += hit.pnl
                base += hit.base
            }
        }
        return (pnl, base)
    }

    private func isInPeriod(_ date: Date) -> Bool {
        switch mode {
        case .day, .week:
            return calendar.isDate(date, equalTo: anchor, toGranularity: .month)
        case .month, .year:
            return calendar.isDate(date, equalTo: anchor, toGranularity: .year)
        }
    }

    private var periodLabel: String {
        switch mode {
        case .day, .week: return "本月合计"
        case .month, .year: return "本年合计"
        }
    }

    // MARK: - 视图

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let d = state.dashboard {
                        let map = dailyMap(d.curve ?? Curve(dates: [], mv: [], cost: []))
                        mainCard(map)
                        summaryCard()
                    } else if let err = state.errorMessage {
                        InlineError(text: err).padding(.top, 40)
                    } else {
                        RisingChartLoader(caption: "正在算每个周期的盈亏…")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .brandPage()
            .contentMargins(.bottom, 92, for: .scrollContent)
            .navigationTitle("收益日历")
        }
    }

    private func mainCard(_ map: [String: (pnl: Double, base: Double, cost: Double)]) -> some View {
        WalletCard(padding: 16, translucent: true) {
            VStack(spacing: 12) {
                navRow
                pickers

                switch mode {
                case .day:   dayGrid(map)
                case .week:  bucketList(weekBuckets(map))
                case .month: monthGrid(map)
                case .year:  bucketList(yearBuckets(map))
                }
            }
        }
    }

    // MARK: 顶部：翻页 + 两个选择器

    private var navRow: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { offset -= 1 }
            } label: {
                Image(systemName: "chevron.left").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            Button {
                withAnimation(.snappy(duration: 0.2)) { offset += 1 }
            } label: {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(offset >= 0 ? Color.secondary.opacity(0.3) : Color.secondary)
            .disabled(offset >= 0)

            // 回到当前周期。始终占位，只改强调色 —— 否则按钮出现/消失会让标题左右跳
            Button {
                withAnimation(.snappy(duration: 0.2)) { offset = 0 }
            } label: {
                Text("今天")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        offset == 0 ? Color.clear : Color.accentColor.opacity(0.16),
                        in: Capsule()
                    )
                    .foregroundStyle(offset == 0 ? Color.secondary.opacity(0.35) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(offset == 0)
            .accessibilityLabel("回到今天")
        }
    }

    private var pickers: some View {
        HStack(spacing: 8) {
            Picker("周期", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("单位", selection: $unit) {
                ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)
        }
        .onChange(of: mode) { _, _ in offset = 0 }
    }

    // MARK: 日视图

    private func dayGrid(_ map: [String: (pnl: Double, base: Double, cost: Double)]) -> some View {
        let days = daysInMonth()
        let lead = leadingBlanks()

        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { w in
                    Text(w)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(0..<rowsNeeded(), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col - lead
                        if index >= 0 && index < days {
                            dayCell(day: index + 1, map: map)
                        } else {
                            Color.clear.frame(height: 52)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(day: Int, map: [String: (pnl: Double, base: Double, cost: Double)]) -> some View {
        let date = calendar.date(byAdding: .day, value: day - 1, to: anchor)!
        let key = Self.df.string(from: date)
        let hit = map[key]
        let isToday = key == Self.df.string(from: Date())
        let isFuture = date > Date()

        return VStack(spacing: 3) {
            Text("\(day)")
                .font(.caption2)
                .foregroundStyle(isToday ? Color.accentColor : Color.secondary)

            // hit.cost == 0 表示那天还没建仓（曲线第一个零点），显示「—」而不是 0.00
            if let hit = hit, !isFuture, hit.cost > 0 {
                Text(display(hit.pnl, base: hit.base))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(hit.pnl))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            } else {
                Text(isToday ? "今天" : "—")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(tint(hit?.pnl), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isToday ? 0.9 : 0), lineWidth: 1.5)
        )
    }

    // MARK: 月视图（一年 12 格）

    private func monthGrid(_ map: [String: (pnl: Double, base: Double, cost: Double)]) -> some View {
        let values = monthBuckets(map)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                         spacing: 6) {
            ForEach(values) { b in
                VStack(spacing: 3) {
                    Text(b.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(display(b.pnl, base: b.base))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(b.pnl))
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(tint(b.pnl), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: 周 / 年：列表

    private func bucketList(_ buckets: [Bucket]) -> some View {
        VStack(spacing: 0) {
            if buckets.isEmpty {
                Text("这段时间没有数据")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { i, b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title)
                                .font(.subheadline)
                                .monospacedDigit()
                            Text("\(b.days) 个交易日")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(display(b.pnl, base: b.base))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(b.pnl))
                    }
                    .padding(.vertical, 10)

                    if i < buckets.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 0.5)
                    }
                }
            }
        }
    }

    // MARK: 汇总卡

    private func summaryCard() -> some View {
        let t = periodTotal
        let (win, lose) = winLose()
        return WalletCard(padding: 16, translucent: true) {
            VStack(alignment: .leading, spacing: 8) {
                CardCaption(text: periodLabel)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(display(t.pnl, base: t.base, signedAlways: true))
                        .scaledFont(28, weight: .bold, design: .rounded, mono: true,
                                    relativeTo: .title)
                        .foregroundStyle(privacy.hidden ? Color.secondary : Fmt.tone(t.pnl))
                    Spacer()
                    Text("\(win) 涨 · \(lose) 跌")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("按每日净值反推。没有净值的日子（周末、节假日、还没更新）不计入。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func winLose() -> (Int, Int) {
        guard let curve = state.dashboard?.curve else { return (0, 0) }
        // 周/年这类聚合看的是「周期」涨跌，日/月看的是「天」
        if mode == .day {
            var w = 0, l = 0
            for (key, hit) in dailyMap(curve) where key.hasPrefix(key) {
                guard let d = Self.df.date(from: key), isInPeriod(d) else { continue }
                if hit.pnl > 0.005 { w += 1 }
                if hit.pnl < -0.005 { l += 1 }
            }
            return (w, l)
        }
        var w = 0, l = 0
        for b in (mode == .week ? weekBuckets(dailyMap(curve)) : monthBuckets(dailyMap(curve)))
        where b.days > 0 {
            if b.pnl > 0.005 { w += 1 }
            if b.pnl < -0.005 { l += 1 }
        }
        return (w, l)
    }

    // MARK: 聚合

    private func weekBuckets(_ map: [String: (pnl: Double, base: Double, cost: Double)]) -> [Bucket] {
        var out: [Bucket] = []
        var seen = Set<String>()
        let days = daysInMonth()

        for day in 1...days {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: anchor),
                  let iv = calendar.dateInterval(of: .weekOfYear, for: date) else { continue }
            let key = Self.df.string(from: iv.start)
            if seen.contains(key) { continue }
            seen.insert(key)

            var pnl = 0.0, base = 0.0, n = 0
            var inMonthStart: Date?
            var inMonthEnd: Date?

            for d in 0..<7 {
                guard let dd = calendar.date(byAdding: .day, value: d, to: iv.start) else { continue }
                guard calendar.isDate(dd, equalTo: anchor, toGranularity: .month) else { continue }
                if inMonthStart == nil { inMonthStart = dd }
                inMonthEnd = dd
                if let hit = map[Self.df.string(from: dd)], hit.cost > 0 {
                    pnl += hit.pnl
                    base += hit.base
                    n += 1
                }
            }

            guard let s = inMonthStart, let e = inMonthEnd else { continue }
            let range = n == 1
                ? Self.mdDF.string(from: s)
                : "\(Self.mdDF.string(from: s)) – \(Self.mdDF.string(from: e))"
            out.append(Bucket(id: key, title: range, pnl: pnl, days: n, base: base))
        }
        return out
    }

    private func monthBuckets(_ map: [String: (pnl: Double, base: Double, cost: Double)]) -> [Bucket] {
        let year = calendar.component(.year, from: anchor)
        return (1...12).map { m in
            var pnl = 0.0, base = 0.0, n = 0
            for (key, hit) in map {
                guard let d = Self.df.date(from: key) else { continue }
                let c = calendar.dateComponents([.year, .month], from: d)
                guard c.year == year, c.month == m, hit.cost > 0 else { continue }
                pnl += hit.pnl
                base += hit.base
                n += 1
            }
            return Bucket(id: "\(year)-\(m)", title: "\(m) 月", pnl: pnl, days: n, base: base)
        }
    }

    private func yearBuckets(_ map: [String: (pnl: Double, base: Double, cost: Double)]) -> [Bucket] {
        var byYear: [Int: (pnl: Double, base: Double, n: Int)] = [:]
        for (key, hit) in map {
            guard let d = Self.df.date(from: key) else { continue }
            guard hit.cost > 0 else { continue }
            let y = calendar.component(.year, from: d)
            var cur = byYear[y] ?? (0, 0, 0)
            cur.pnl += hit.pnl
            cur.base += hit.base
            cur.n += 1
            byYear[y] = cur
        }
        return byYear.keys.sorted(by: >).map { y in
            let v = byYear[y]!
            return Bucket(id: "\(y)", title: "\(y) 年", pnl: v.pnl, days: v.n, base: v.base)
        }
    }

    // MARK: - 展示辅助

    private func display(_ pnl: Double, base: Double, signedAlways: Bool = false) -> String {
        if privacy.hidden { return PrivacyMode.mask }
        if unit == .percent, base > 0.01 {
            return Fmt.pct(pnl / base * 100)
        }
        if !signedAlways && abs(pnl) < 0.005 {
            return "0.00"
        }
        return Fmt.signed(pnl)
    }

    private func tint(_ pnl: Double?) -> Color {
        if privacy.hidden { return Color.primary.opacity(0.04) }
        guard let pnl = pnl, abs(pnl) > 0.005 else {
            return Color.primary.opacity(0.04)
        }
        // 红涨绿跌
        return pnl > 0 ? Color.red.opacity(0.16) : Color.green.opacity(0.16)
    }

    private func daysInMonth() -> Int {
        calendar.range(of: .day, in: .month, for: anchor)?.count ?? 30
    }

    private func leadingBlanks() -> Int {
        calendar.component(.weekday, from: anchor) - 1
    }

    private func rowsNeeded() -> Int {
        Int(ceil(Double(leadingBlanks() + daysInMonth()) / 7.0))
    }
}
