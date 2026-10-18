import Foundation

// ==========================================================================
// 计算层：逐函数对照 fund-dashboard/server.py
// 输出 [String: Any]（snake_case），和 Python 的 JSON 结构一一对应。
// ==========================================================================

// MARK: - 持仓配置模型

/// 定投计划的一个「生效段」：从 start 这天起，每个交易日按 amount 买入，
/// 直到下一个段的 start 为止（没有下一段就一直有效）。
struct PlanSegment: Equatable {
    var start: String
    var amount: Double

    init(start: String, amount: Double) {
        self.start = start
        self.amount = amount
    }

    init?(json: [String: Any]) {
        // amount == 0 是合法的：表示「从这天起停止」
        guard let start = fundStr(json["start"]), let amount = fundNum(json["amount"]),
              amount >= 0 else { return nil }
        self.start = start
        self.amount = amount
    }

    var jsonObject: [String: Any] { ["start": start, "amount": amount] }
}

struct HoldingFund {
    var code: String
    var name: String
    var platform: String
    var track: String
    var ratio: Double
    /// 每笔是 [date, amount] / [date, amount, nav] / [date, amount, nav, shares]
    var lots: [[Any]]
    var shares: Double?
    var cost: Double?
    var reconciledAt: String?
    /// 定投计划（按生效日期分段）。为空表示没有计划。
    var plans: [PlanSegment]
    /// 例外日期：计划本该买、但那一天实际没买成（余额不足、限额、系统故障）。
    /// 这些日期不会生成记录。
    var skips: [String]

    init(code: String, name: String = "", platform: String = "", track: String = "",
         ratio: Double = 0.95, lots: [[Any]] = [], shares: Double? = nil,
         cost: Double? = nil, reconciledAt: String? = nil,
         plans: [PlanSegment] = [], skips: [String] = []) {
        self.code = code
        self.name = name
        self.platform = platform
        self.track = track
        self.ratio = ratio
        self.lots = lots
        self.shares = shares
        self.cost = cost
        self.reconciledAt = reconciledAt
        self.plans = plans
        self.skips = skips
    }

    init?(json: [String: Any]) {
        guard let code = fundStr(json["code"]) else { return nil }
        self.code = code
        self.name = fundStr(json["name"]) ?? code
        self.platform = fundStr(json["platform"]) ?? ""
        self.track = fundStr(json["track"]) ?? ""
        self.ratio = fundNum(json["ratio"]) ?? 0.95
        self.lots = (json["lots"] as? [Any])?.compactMap { $0 as? [Any] } ?? []
        self.shares = fundNum(json["shares"])
        self.cost = fundNum(json["cost"])
        self.reconciledAt = fundStr(json["reconciled_at"])
        self.plans = (json["plans"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap { PlanSegment(json: $0) }
            .sorted { $0.start < $1.start } ?? []
        self.skips = (json["skips"] as? [Any])?.compactMap { fundStr($0) } ?? []
    }

    var jsonObject: [String: Any] {
        var d: [String: Any] = [
            "code": code,
            "name": name,
            "platform": platform,
            "track": track,
            "ratio": ratio,
            "lots": lots,
        ]
        if let shares = shares { d["shares"] = shares }
        if let cost = cost { d["cost"] = cost }
        if let reconciledAt = reconciledAt { d["reconciled_at"] = reconciledAt }
        if !plans.isEmpty { d["plans"] = plans.map(\.jsonObject) }
        if !skips.isEmpty { d["skips"] = skips.sorted() }
        return d
    }
}

struct HoldingsConfig {
    var funds: [HoldingFund]
    var refreshSeconds: Int
    var marketRefreshSeconds: Int
    var smsSyncedAt: String?

    init(funds: [HoldingFund] = [], refreshSeconds: Int = 60,
         marketRefreshSeconds: Int = 30, smsSyncedAt: String? = nil) {
        self.funds = funds
        self.refreshSeconds = refreshSeconds
        self.marketRefreshSeconds = marketRefreshSeconds
        self.smsSyncedAt = smsSyncedAt
    }

    init(json: [String: Any]) {
        self.funds = ((json["funds"] as? [Any]) ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap(HoldingFund.init(json:))
        if let v = fundNum(json["refresh_seconds"]), v >= 0, v < 1e9 {
            self.refreshSeconds = Int(v)
        } else {
            self.refreshSeconds = 60
        }
        if let v = fundNum(json["market_refresh_seconds"]), v >= 0, v < 1e9 {
            self.marketRefreshSeconds = Int(v)
        } else {
            self.marketRefreshSeconds = 30
        }
        self.smsSyncedAt = fundStr(json["sms_synced_at"])
    }

    func jsonObject() -> [String: Any] {
        var d: [String: Any] = [
            "refresh_seconds": refreshSeconds,
            "market_refresh_seconds": marketRefreshSeconds,
            "funds": funds.map { $0.jsonObject },
        ]
        if let smsSyncedAt = smsSyncedAt { d["sms_synced_at"] = smsSyncedAt }
        return d
    }
}

// MARK: - 小工具

/// 对应 guess_track
/// 把「定投计划」展开成买入记录。
///
/// 规则：
///   - 只在该基金**有净值的交易日**生成（净值序列本身就是交易日历）
///   - 金额取「生效日期不晚于当天」的最后一个分段
///   - **跳过已经手动记过的日期**，避免和手记重复
///   - 生成的 lot 带第 5 位标记 "plan"，界面上会标「定投」且不允许直接删
func expandPlan(_ f: HoldingFund, _ hist: FundHistory) -> HoldingFund {
    guard !f.plans.isEmpty, !hist.series.isEmpty else { return f }
    let segs = f.plans.sorted { $0.start < $1.start }
    guard let first = segs.first else { return f }

    // 已经手动记过的日期 + 明确标记「这天没买成」的例外日期，都不生成
    var manual = Set<String>()
    for lot in f.lots {
        if let d = fundStr(lot.first) { manual.insert(d) }
    }
    for d in f.skips { manual.insert(d) }

    var navByDate: [String: Double] = [:]
    for p in hist.series where p.v > 0 {
        navByDate[fundDayString(TimeInterval(p.t))] = p.v
    }

    var out = f
    for (date, nav) in navByDate.sorted(by: { $0.key < $1.key }) {
        guard date >= first.start, !manual.contains(date) else { continue }
        guard let seg = segs.last(where: { $0.start <= date }) else { continue }
        guard seg.amount > 0 else { continue }   // 停止段：从这天起不再生成
        out.lots.append([date, seg.amount, nav, seg.amount / nav, "plan"])
    }
    return out
}

/// 把基金归到一个资产大类，用于「按类型」分组和组合构成展示。
/// 纯展示用，不影响任何计算。
func fundKind(name: String, track: String) -> String {
    if name.contains("黄金") || name.contains("白银") { return "黄金白银" }
    if track == "NDX" || track == "SPX" { return "美股" }
    if name.contains("港股") || name.contains("恒生") { return "港股" }
    if name.contains("红利") { return "红利" }
    if name.contains("ETF") || name.contains("指数") || name.contains("LOF") { return "A股指数" }
    return "主动混合"
}

/// 最大回撤 + 年化波动率。都用「剔除现金流之后的日收益」算，
/// 否则加仓那天会被当成大涨。
func computeRisk(_ curve: [String: Any]) -> (maxDD: Double?, maxDDDate: String?, vol: Double?) {
    let dates = (curve["dates"] as? [String]) ?? []
    let mvs = (curve["mv"] as? [Double]) ?? []
    let costs = (curve["cost"] as? [Double]) ?? []
    guard dates.count > 2, mvs.count == dates.count, costs.count == dates.count else {
        return (nil, nil, nil)
    }
    var peak = 0.0
    var maxDD = 0.0
    var maxDDDate: String?
    var rets: [Double] = []
    var prevMV = 0.0
    var prevCost = 0.0
    for i in dates.indices {
        let mv = mvs[i], cost = costs[i]
        if mv > peak { peak = mv }
        if peak > 0 {
            let dd = (mv - peak) / peak
            if dd < maxDD { maxDD = dd; maxDDDate = dates[i] }
        }
        if i > 0, prevMV > 0, cost > 0 {
            rets.append((mv - prevMV - (cost - prevCost)) / prevMV)
        }
        prevMV = mv; prevCost = cost
    }
    var vol: Double?
    if rets.count > 5 {
        let n = Double(rets.count)
        let mean = rets.reduce(0, +) / n
        let v = rets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        vol = (v.squareRoot()) * (250.0).squareRoot() * 100
    }
    return (maxDD * 100, maxDDDate, vol)
}

func guessTrack(_ name: String) -> String {
    let n = name
    if n.contains("纳斯达克") || n.contains("纳指") { return "NDX" }
    if n.contains("标普") || n.uppercased().contains("S&P") { return "SPX" }
    return ""
}

/// 两个 'YYYY-MM-DD' 相差多少天（对应 _day_diff）
func fundDayDiff(_ d1: String, _ d2: String) -> Double {
    guard let a = fundDate(d1), let b = fundDate(d2) else { return 0 }
    return b.timeIntervalSince(a) / 86400.0
}

/// 对应 nav_on：取某日净值；当天非交易日时回退到此前最近一个交易日
func fundNAVOn(_ series: [NavPoint], _ dateStr: String) -> (nav: Double?, date: String?) {
    if series.isEmpty { return (nil, nil) }
    guard let target = fundDate(dateStr) else {
        let last = series[series.count - 1]
        return (last.v, fundDayString(TimeInterval(last.t)))
    }
    let limit = target.timeIntervalSince1970 + 86399
    var best: NavPoint? = nil
    for p in series {
        if TimeInterval(p.t) <= limit { best = p } else { break }
    }
    let hit = best ?? series[0]
    return (hit.v, fundDayString(TimeInterval(hit.t)))
}

/// 对应 xirr：二分法，区间 (-0.9999, 10)，最多 200 次
func fundXIRR(_ flows: [(String, Double)]) -> Double? {
    var clean: [(String, Double)] = []
    for (d, a) in flows {
        if abs(a) < 1e-9 { continue }
        let date = String(d.prefix(10))
        guard fundDate(date) != nil else { continue }
        clean.append((date, a))
    }
    if clean.count < 2 { return nil }
    if !clean.contains(where: { $0.1 < 0 }) || !clean.contains(where: { $0.1 > 0 }) {
        return nil
    }

    let t0 = clean.map { $0.0 }.min()!
    let ts = clean.map { fundDayDiff(t0, $0.0) / 365.0 }
    let amounts = clean.map { $0.1 }

    func npv(_ r: Double) -> Double {
        let base = 1.0 + r
        if base <= 0 { return .infinity }
        var sum = 0.0
        for i in 0..<amounts.count {
            sum += amounts[i] / pow(base, ts[i])
        }
        return sum
    }

    var lo = -0.9999
    var hi = 10.0
    var flo = npv(lo)
    var fhi = npv(hi)
    var tries = 0
    while flo * fhi > 0 && tries < 6 {
        hi *= 10
        fhi = npv(hi)
        tries += 1
    }
    if flo * fhi > 0 { return nil }

    for _ in 0..<200 {
        let mid = (lo + hi) / 2.0
        let fm = npv(mid)
        if abs(fm) < 1e-9 || (hi - lo) < 1e-10 { return mid }
        if flo * fm <= 0 {
            hi = mid
        } else {
            lo = mid
            flo = fm
        }
    }
    return (lo + hi) / 2.0
}

/// 对应 _fund_flows：把一只基金的买入记录 + 当前市值变成现金流
func fundFlows(_ f: HoldingFund, mv: Double?, today: String) -> [(String, Double)] {
    var flows: [(String, Double)] = []
    for lot in f.lots {
        guard lot.count >= 2, let d = fundStr(lot[0]), let amt = fundNum(lot[1]) else { continue }
        if amt > 0 { flows.append((String(d.prefix(10)), -amt)) }
    }
    if fundTruthy(mv) {
        flows.append((today, mv!))
    }
    return flows
}

// MARK: - 估值中间结果

private struct EstimateResult {
    var pct: Double? = nil
    var src: String = ""
    var beta: Double? = nil
    var betaN: Int = 0
    var from: String? = nil
    var to: String? = nil
    var days: Int = 0
    var live: Bool = false
}

private struct BetaResult {
    let beta: Double
    let n: Int
    let r2: Double
}

// MARK: - 引擎

final class PortfolioEngine {
    static let shared = PortfolioEngine()

    private let api: FundAPI

    init(api: FundAPI = FundAPI.shared) {
        self.api = api
    }

    // ------------------------------------------------------------ 对外入口

    /// 对应 server.py 的 build()
    func dashboard(holdings: HoldingsConfig) async -> [String: Any] {
        let now = Date()
        let funds = holdings.funds
        let codes = funds.map { $0.code }.filter { !$0.isEmpty }

        let market: MarketData
        do {
            market = try await api.marketCached(ttl: TimeInterval(holdings.marketRefreshSeconds))
        } catch {
            market = MarketData.empty(now)
        }
        var quotes: [String: FundQuote] = [:]
        if !codes.isEmpty {
            quotes = await api.quotesCached(codes: codes, ttl: TimeInterval(holdings.refreshSeconds))
        }
        let fxPct = fundFXPercent(market)

        // 历史净值并发拉：冷启动一次要拿十几只，串行要 8~10 秒。
        // 限 4 个并发，再多东财会限流。
        let apiRef = api
        let codeList = funds.filter { !$0.code.isEmpty }.map(\.code)
        var histMap: [String: FundHistory] = [:]
        await withTaskGroup(of: (String, FundHistory).self) { group in
            var next = 0
            let limit = 4
            let total = codeList.count
            while next < min(limit, total) {
                let c = codeList[next]
                next += 1
                group.addTask { (c, await apiRef.historyCached(code: c)) }
            }
            while let pair = await group.next() {
                histMap[pair.0] = pair.1
                if next < total {
                    let c = codeList[next]
                    next += 1
                    group.addTask { (c, await apiRef.historyCached(code: c)) }
                }
            }
        }

        // 申购状态：每只一个请求，缓存 12h
        var subStatusMap: [String: SubStatus] = [:]
        await withTaskGroup(of: (String, SubStatus?).self) { group in
            var i = 0
            while i < min(4, codeList.count) {
                let c = codeList[i]; i += 1
                group.addTask { [apiRef] in (c, await apiRef.subStatusCached(code: c)) }
            }
            while let pair = await group.next() {
                if let st = pair.1 { subStatusMap[pair.0] = st }
                if i < codeList.count {
                    let c = codeList[i]; i += 1
                    group.addTask { [apiRef] in (c, await apiRef.subStatusCached(code: c)) }
                }
            }
        }

        var rows: [[String: Any]] = []
        var items: [(HoldingFund, FundHistory)] = []
        for f in funds where !f.code.isEmpty {
            let q = quotes[f.code] ?? FundQuote()
            let hist = histMap[f.code] ?? FundHistory(code: f.code)
            let ef = expandPlan(f, hist)
            rows.append(await computeFund(ef, q, hist, market, fxPct,
                                          seriesLimit: 60, withLots: false,
                                          subStatus: subStatusMap[f.code]))
            items.append((ef, hist))
        }
        rows = sortRows(rows)

        var totMV = 0.0
        for r in rows { totMV += fundNum(r["market_value"]) ?? 0 }
        var totCost = 0.0
        for r in rows { totCost += fundNum(r["cost"]) ?? 0 }
        let totProfit = totMV - totCost

        var totEst = 0.0
        var hasEst = false
        // 「参与预估的市值」：只有认得出跟踪指数的基金才有 est_profit。
        // 百分比必须用这个做分母 —— 用全部市值会让百分比被稀释（持仓里大半是 A 股基金时尤其严重）
        var estMV = 0.0
        for r in rows {
            if let v = fundNum(r["est_profit"]) {
                totEst += v
                hasEst = true
                estMV += fundNum(r["market_value"]) ?? 0
            }
        }
        let estCoverage = totMV > 0 ? estMV / totMV : 0

        // 按资产类型汇总（纯展示）
        var kindAgg: [String: [String: Any]] = [:]
        for r in rows {
            let k = (r["kind"] as? String) ?? "其他"
            var cur = kindAgg[k] ?? ["kind": k, "count": 0,
                                     "market_value": 0.0, "cost": 0.0]
            cur["count"] = (cur["count"] as? Int ?? 0) + 1
            cur["market_value"] = (cur["market_value"] as? Double ?? 0)
                + (fundNum(r["market_value"]) ?? 0)
            cur["cost"] = (cur["cost"] as? Double ?? 0) + (fundNum(r["cost"]) ?? 0)
            kindAgg[k] = cur
        }
        let kinds = kindAgg.values.sorted {
            ($0["market_value"] as? Double ?? 0) > ($1["market_value"] as? Double ?? 0)
        }

        // 全部买入流水（倒序）
        var tx: [[String: Any]] = []
        for r in rows {
            let lots = (r["lots"] as? [[String: Any]]) ?? []
            for l in lots {
                var t: [String: Any] = [:]
                t["date"] = l["date"] ?? NSNull()
                t["code"] = r["code"] ?? NSNull()
                t["name"] = r["name"] ?? NSNull()
                let platform = (r["platform"] as? String) ?? ""
                t["platform"] = platform.isEmpty ? "未标注" : platform
                t["amount"] = l["amount"] ?? NSNull()
                t["nav"] = l["nav"] ?? NSNull()
                t["shares"] = l["shares"] ?? NSNull()
                tx.append(t)
            }
        }
        tx = sortTransactions(tx)

        // 按基金公司汇总
        struct PlatformAgg {
            var platform: String
            var mv: Double
            var cost: Double
            var count: Int
            var lots: Int
        }
        var platList: [PlatformAgg] = []
        var platIndex: [String: Int] = [:]
        for r in rows {
            let raw = (r["platform"] as? String) ?? ""
            let key = raw.isEmpty ? "未标注" : raw
            let lotsCount = (r["lots_count"] as? Int) ?? 0
            if let i = platIndex[key] {
                platList[i].mv += fundNum(r["market_value"]) ?? 0
                platList[i].cost += fundNum(r["cost"]) ?? 0
                platList[i].count += 1
                platList[i].lots += lotsCount
            } else {
                platIndex[key] = platList.count
                platList.append(PlatformAgg(
                    platform: key,
                    mv: fundNum(r["market_value"]) ?? 0,
                    cost: fundNum(r["cost"]) ?? 0,
                    count: 1,
                    lots: lotsCount
                ))
            }
        }
        let sortedPlats = platList.enumerated().sorted { a, b in
            if a.element.mv != b.element.mv { return a.element.mv > b.element.mv }
            return a.offset < b.offset
        }.map { $0.element }

        let thisMonth = fundMonthString(now)
        let monthTx = tx.filter { (($0["date"] as? String) ?? "").hasPrefix(thisMonth) }
        var monthAmount = 0.0
        for t in monthTx { monthAmount += fundNum(t["amount"]) ?? 0 }

        let today = fundDayString(now)
        let byCode = Dictionary(funds.map { ($0.code, $0) }, uniquingKeysWith: { _, last in last })

        for i in rows.indices {
            guard let code = rows[i]["code"] as? String, let f = byCode[code] else {
                rows[i]["xirr"] = NSNull()
                rows[i]["xirr_days"] = 0
                continue
            }
            let flows = fundFlows(f, mv: fundNum(rows[i]["market_value"]), today: today)
            rows[i]["xirr"] = fundJSON(fundXIRR(flows))
            let first = flows.map { $0.0 }.min() ?? today
            rows[i]["xirr_days"] = max(0, Int(fundRound(fundDayDiff(first, today), 0)))
        }

        // 组合整体 XIRR
        var portFlows: [(String, Double)] = []
        for f in funds where !f.code.isEmpty {
            for lot in f.lots {
                guard lot.count >= 2, let d = fundStr(lot[0]), let amt = fundNum(lot[1]) else { continue }
                portFlows.append((String(d.prefix(10)), -amt))
            }
        }
        if totMV != 0 { portFlows.append((today, totMV)) }
        let portXIRR = fundXIRR(portFlows)
        let portFirst = portFlows.map { $0.0 }.min() ?? today
        let portDays = max(0, Int(fundRound(fundDayDiff(portFirst, today), 0)))

        let curve = buildCurve(items, days: 365, now: now)
        let risk = computeRisk(curve)

        var platforms: [[String: Any]] = []
        for p in sortedPlats {
            let profit = p.mv - p.cost
            var d: [String: Any] = [
                "platform": p.platform,
                "market_value": p.mv,
                "cost": p.cost,
                "count": p.count,
                "lots": p.lots,
                "profit": profit,
            ]
            d["profit_pct"] = fundJSON(p.cost != 0 ? Optional(profit / p.cost * 100) : nil)
            platforms.append(d)
        }

        let estProfitOut: Any = hasEst ? totEst : NSNull()
        let estPctOut: Any = (hasEst && estMV != 0) ? totEst / estMV * 100 : NSNull()
        var summary: [String: Any] = [
            "market_value": totMV,
            "cost": totCost,
            "profit": totProfit,
            "profit_pct": fundJSON(totCost != 0 ? Optional(totProfit / totCost * 100) : nil),
            "est_profit": estProfitOut,
            "est_mv": estMV,
            "est_coverage": estCoverage,
            "est_pct": estPctOut,
            "fund_count": rows.count,
            "platform_count": platforms.count,
            "lots_count": tx.count,
            "month_amount": monthAmount,
            "month_count": monthTx.count,
        ]
        summary["xirr"] = fundJSON(portXIRR)
        summary["xirr_days"] = portDays

        return [
            "updated": fundNowString(now),
            "market": market.jsonObject,
            "summary": summary,
            "curve": curve,
        "kinds": kinds,
        "max_drawdown": fundJSON(risk.maxDD),
        "max_drawdown_date": risk.maxDDDate ?? NSNull(),
        "volatility": fundJSON(risk.vol),
            "funds": rows,
            "platforms": platforms,
            "transactions": tx,
        ]
    }

    /// 对应 server.py 的 build_fund()
    func fundDetail(code: String, holdings: HoldingsConfig) async -> [String: Any]? {
        guard let f = holdings.funds.first(where: { $0.code == code }) else { return nil }
        let now = Date()
        let market: MarketData
        do {
            market = try await api.marketCached(ttl: TimeInterval(holdings.marketRefreshSeconds))
        } catch {
            market = MarketData.empty(now)
        }
        let quotes = await api.quotesCached(codes: [code], ttl: TimeInterval(holdings.refreshSeconds))
        let hist = await api.historyCached(code: code)
        let ef = expandPlan(f, hist)
        let st = await api.subStatusCached(code: code)
        var fund = await computeFund(ef, quotes[code] ?? FundQuote(), hist, market,
                                     fundFXPercent(market), seriesLimit: 0, withLots: true,
                                     subStatus: st)

        let today = fundDayString(now)
        let flows = fundFlows(f, mv: fundNum(fund["market_value"]), today: today)
        fund["xirr"] = fundJSON(fundXIRR(flows))
        let first = flows.map { $0.0 }.min() ?? today
        fund["xirr_days"] = max(0, Int(fundRound(fundDayDiff(first, today), 0)))

        return [
            "updated": fundNowString(now),
            "market": market.jsonObject,
            "fund": fund,
        ]
    }

    // ------------------------------------------------------------ 单只基金

    /// 对应 _compute_fund
    private func computeFund(_ f: HoldingFund, _ q: FundQuote, _ hist: FundHistory,
                             _ market: MarketData, _ fxPct: Double,
                             seriesLimit: Int, withLots: Bool,
                             subStatus: SubStatus? = nil) async -> [String: Any] {
        let code = f.code
        var shares = 0.0
        var cost = 0.0
        var lotsOut: [[String: Any]] = []

        for lot in f.lots {
            guard lot.count >= 2, let dateStr = fundStr(lot[0]),
                  let amount = fundNum(lot[1]) else { continue }
            var nav: Double? = lot.count > 2 ? fundNum(lot[2]) : nil
            // 第 4 位是基金公司确认的份额（短信/对账单里能拿到），优先于「金额 ÷ 净值」折算
            let confirmed: Double? = lot.count > 3 ? fundNum(lot[3]) : nil
            var navDate: String? = dateStr
            if nav == nil {
                let hit = fundNAVOn(hist.series, dateStr)
                nav = hit.nav
                navDate = hit.date
            }
            let sh: Double
            if let confirmed = confirmed {
                sh = confirmed
            } else if let nav = nav, nav != 0 {
                sh = amount / nav
            } else {
                sh = 0
            }
            shares += sh
            cost += amount
            var d: [String: Any] = [
                "date": dateStr,
                "amount": amount,
                "nav": fundJSON(nav),
                "nav_date": fundJSON(navDate),
                "shares": sh,
            ]
            d["cum_amount"] = 0.0
            d["cum_shares"] = 0.0
            // 第 5 位是 "plan" 表示这笔由定投计划自动生成
            if lot.count > 4, fundStr(lot[4]) == "plan" { d["auto"] = true }
            lotsOut.append(d)
        }
        // Python 的 sort 是稳定排序，这里补上原始下标做 tie-break
        lotsOut = lotsOut.enumerated().sorted { a, b in
            let ad = (a.element["date"] as? String) ?? ""
            let bd = (b.element["date"] as? String) ?? ""
            if ad != bd { return ad < bd }
            let aa = fundNum(a.element["amount"]) ?? 0
            let ba = fundNum(b.element["amount"]) ?? 0
            if aa != ba { return aa < ba }
            return a.offset < b.offset
        }.map { $0.element }

        // 累计投入 / 累计份额（前端流水表用）
        var cumA = 0.0
        var cumS = 0.0
        for i in lotsOut.indices {
            cumA += fundNum(lotsOut[i]["amount"]) ?? 0
            cumS += fundNum(lotsOut[i]["shares"]) ?? 0
            lotsOut[i]["cum_amount"] = cumA
            lotsOut[i]["cum_shares"] = cumS
        }

        // 允许直接写死份额和成本，优先级高于按买入金额推算的值
        var sharesSource = "lots"
        if let explicitShares = f.shares {
            shares = explicitShares
            sharesSource = "manual"
        }
        if let explicitCost = f.cost {
            cost = explicitCost
        }

        let nav = q.nav
        let mv: Double? = (nav != nil && nav != 0) ? shares * nav! : nil
        let profit: Double? = mv.map { $0 - cost }

        if withLots, let nav = nav, nav != 0 {
            for i in lotsOut.indices {
                let amt = fundNum(lotsOut[i]["amount"]) ?? 0
                let sh = fundNum(lotsOut[i]["shares"]) ?? 0
                let value = sh * nav
                let p = value - amt
                lotsOut[i]["value"] = value
                lotsOut[i]["profit"] = p
                lotsOut[i]["profit_pct"] = fundJSON(amt != 0 ? Optional(p / amt * 100) : nil)
            }
        }

        let est = await estimate(f, q, hist, market)
        let estPct = est.pct
        let ratio = est.beta ?? f.ratio
        let estProfit: Double? = (mv != nil && estPct != nil) ? mv! * estPct! / 100 : nil

        var series = hist.series
        if seriesLimit > 0 && series.count > seriesLimit {
            series = Array(series.suffix(seriesLimit))
        }

        let avgCostNav: Double? = shares != 0 ? cost / shares : nil
        let profitPct: Double? = (profit != nil && cost != 0) ? profit! / cost * 100 : nil
        let name = fundFirstNonEmpty([q.name, hist.name]) ?? code

        var out: [String: Any] = [
            "code": code,
            "name": name,
            "platform": f.platform,
            "track": f.track.uppercased(),
            "ratio": ratio,
            "shares": shares,
            "shares_source": sharesSource,
            "reconciled_at": fundJSON(f.reconciledAt),
            "cost": cost,
            "avg_cost_nav": fundJSON(avgCostNav),
            "nav": fundJSON(nav),
            "nav_date": fundJSON(q.navDate),
            "nav_chg": fundJSON(q.navChg),
            "market_value": fundJSON(mv),
            "profit": fundJSON(profit),
            "profit_pct": fundJSON(profitPct),
            "est_pct": fundJSON(estPct),
            "est_src": est.src,
            "est_profit": fundJSON(estProfit),
            "est_beta": fundJSON(est.beta),
            "est_beta_n": est.betaN,
            "est_from": fundJSON(est.from),
            "est_to": fundJSON(est.to),
            "est_days": est.days,
            "est_live": est.live,
            "perf": hist.perf,
            "lots": lotsOut,
            "lots_count": lotsOut.count,
            "kind": fundKind(name: name, track: f.track),
            "plans": f.plans.map(\.jsonObject),
            "skips": f.skips,
            "sgzt": subStatus?.text ?? NSNull(),
            "can_buy": subStatus?.canBuy ?? NSNull(),
            "min_buy": fundJSON(subStatus?.minBuy),
            "series": series.map { ["t": $0.t, "v": $0.v] as [String: Any] },
        ]
        if let first = lotsOut.first, let d = first["date"] {
            out["first_buy"] = d
        } else {
            out["first_buy"] = NSNull()
        }
        if let last = lotsOut.last, let d = last["date"] {
            out["last_buy"] = d
        } else {
            out["last_buy"] = NSNull()
        }
        return out
    }

    // -------------------------------------------------------------- 估值

    private func fundFXPercent(_ market: MarketData) -> Double {
        market.usdcny?.pct ?? 0.0
    }

    /// 对应 _est_for（旧模型，所有数据源都失败时兜底）
    private func estFor(_ f: HoldingFund, _ market: MarketData,
                        _ fxPct: Double) -> (pct: Double?, src: String, ratio: Double) {
        let track = f.track.uppercased()
        let ratio = f.ratio
        var base: Double? = nil
        var src = ""
        if track == "NDX" {
            base = market.nq?.pct
            src = "纳指100期货"
            if base == nil {
                base = market.ndx?.pct
                src = "纳斯达克100"
            }
        } else if track == "SPX" {
            base = market.es?.pct
            src = "标普500期货"
            if base == nil {
                base = market.spx?.pct
                src = "标普500"
            }
        }
        guard let b = base else { return (nil, "", ratio) }
        let v = ratio * b + fxPct
        if abs(v) >= 15 { return (nil, "", ratio) }
        return (v, src, ratio)
    }

    /// 对应 _beta_for：最近 60 个共同交易日，带截距一元回归
    private func betaFor(_ code: String, _ track: String,
                         _ navSeries: [NavPoint]) async -> BetaResult? {
        if track.isEmpty || navSeries.isEmpty { return nil }

        let key = "beta:\(code):\(track)"
        if let hit = api.cacheValue(key, maxAge: 12 * 3600) {
            if let b = hit as? BetaResult { return b }
            if hit is NSNull { return nil }
        }
        let computed = await computeBeta(track, navSeries)
        api.cacheStore(key, computed.map { $0 as Any } ?? NSNull())
        return computed
    }

    private func computeBeta(_ track: String, _ navSeries: [NavPoint]) async -> BetaResult? {
        let idx = await api.fetchIndexHistory(track: track)
        if idx.count < 30 { return nil }

        var navByDate: [String: Double] = [:]
        for p in navSeries {
            navByDate[fundDayString(TimeInterval(p.t))] = p.v
        }
        let dates = Array(navByDate.keys.filter { idx[$0] != nil }.sorted().suffix(61))
        if dates.count < 25 { return nil }

        var xs: [Double] = []
        var ys: [Double] = []
        for i in 0..<(dates.count - 1) {
            let a = dates[i]
            let b = dates[i + 1]
            guard let ia = idx[a], let ib = idx[b],
                  let na = navByDate[a], let nb = navByDate[b] else { continue }
            let ir = ib / ia - 1
            let fr = nb / na - 1
            if abs(ir) > 0.2 || abs(fr) > 0.2 { continue }   // 拆分/分红之类的脏数据剔除
            xs.append(ir)
            ys.append(fr)
        }
        let n = xs.count
        if n < 20 { return nil }

        var sx = 0.0
        for x in xs { sx += x }
        var sy = 0.0
        for y in ys { sy += y }
        let mx = sx / Double(n)
        let my = sy / Double(n)

        var variance = 0.0
        for x in xs { variance += (x - mx) * (x - mx) }
        if variance <= 0 { return nil }

        var cov = 0.0
        for i in 0..<n { cov += (xs[i] - mx) * (ys[i] - my) }
        let beta = cov / variance

        var ssTot = 0.0
        for y in ys { ssTot += (y - my) * (y - my) }
        var ssRes = 0.0
        for i in 0..<n {
            let d = ys[i] - (my + beta * (xs[i] - mx))
            ssRes += d * d
        }
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0.0

        if !(beta >= 0.30 && beta <= 1.25) { return nil }   // 明显离谱就放弃，退回配置值
        return BetaResult(beta: fundRound(beta, 4), n: n, r2: fundRound(r2, 4))
    }

    /// 对应 _estimate
    private func estimate(_ f: HoldingFund, _ q: FundQuote,
                          _ hist: FundHistory, _ market: MarketData) async -> EstimateResult {
        var info = EstimateResult()
        let track = f.track.uppercased()
        guard let pair = fundTrackIndex[track] else { return info }
        guard let navDate = q.navDate else { return info }

        let idx = await api.fetchIndexHistory(track: track)
        let baseD: String? = idx.isEmpty ? nil : idx.keys.filter { $0 <= navDate }.max()

        // 指数历史拿不到 -> 退回旧模型（只用当天期货）
        if baseD == nil {
            let (pct, src, ratio) = estFor(f, market, fundFXPercent(market))
            info.pct = pct
            info.src = src
            info.beta = ratio
            return info
        }

        let b = await betaFor(f.code, track, hist.series)
        let beta = b?.beta ?? f.ratio
        info.beta = fundRound(beta, 4)
        info.betaN = b?.n ?? 0

        let lastD = idx.keys.max()!
        let rIdx = idx[lastD]! / idx[baseD!]! - 1
        let nDays = idx.keys.filter { $0 > baseD! && $0 <= lastD }.count

        // 盘中延伸：期货报价日期比最后一根日线还新，说明又开了一场
        var fut: MarketPoint? = nil
        if track == "NDX" { fut = market.nq }
        else if track == "SPX" { fut = market.es }
        var live = 0.0
        if let fut = fut, let p = fut.pct, (fut.date ?? "") > lastD {
            live = p / 100.0
            info.live = true
        }
        let rTotal = (1 + rIdx) * (1 + live) - 1

        // 汇率：有历史就按同期累计，否则退化为当日变动
        let fxHist = await api.fetchFXHistory()
        let fxBase: String? = fxHist.isEmpty ? nil : fxHist.keys.filter { $0 <= baseD! }.max()
        let fxLast: String? = fxHist.keys.max()
        let rFx: Double
        if let fb = fxBase, let fl = fxLast, fb < fl {
            rFx = fxHist[fl]! / fxHist[fb]! - 1
        } else {
            rFx = fundFXPercent(market) / 100.0
        }

        let pct = beta * rTotal * 100 + rFx * 100
        if abs(pct) >= 15 { return info }

        info.pct = pct
        info.src = "\(pair.name) \(String(baseD!.dropFirst(5)))→\(String(lastD.dropFirst(5)))"
            + (info.live ? " + 盘中" : "")
        info.from = baseD
        info.to = lastD
        info.days = nDays
        return info
    }

    // -------------------------------------------------------------- 曲线

    /// 对应 build_curve：用净值历史反推每日市值和成本
    private func buildCurve(_ items: [(HoldingFund, FundHistory)],
                            days: Int, now: Date) -> [String: Any] {
        let cutoff = fundDayString(now.addingTimeInterval(-Double(days) * 86400))

        var navs: [String: [String: Double]] = [:]
        var navDates: [String: [String]] = [:]
        var navOrder: [String] = []
        for (f, hist) in items {
            var d: [String: Double] = [:]
            for p in hist.series {
                d[fundDayString(TimeInterval(p.t))] = p.v
            }
            if !d.isEmpty {
                if navs[f.code] == nil { navOrder.append(f.code) }
                navs[f.code] = d
                navDates[f.code] = d.keys.sorted()
            }
        }
        let empty: [String: Any] = [
            "dates": [String](),
            "mv": [Double](),
            "cost": [Double](),
        ]
        if navs.isEmpty { return empty }

        // 每只基金的买入事件，按日期升序
        struct CurveEvent {
            let date: String
            let amount: Double
            let shares: Double
        }
        var events: [String: [CurveEvent]] = [:]
        for (f, _) in items {
            guard let navd = navs[f.code] else { continue }
            let candidates = navDates[f.code] ?? []
            for lot in f.lots {
                guard lot.count >= 2, let rawDate = fundStr(lot[0]),
                      let amount = fundNum(lot[1]) else { continue }
                let date = String(rawDate.prefix(10))
                if amount <= 0 { continue }
                let nav: Double? = lot.count > 2 ? fundNum(lot[2]) : nil
                let confirmed: Double? = lot.count > 3 ? fundNum(lot[3]) : nil
                let shares: Double
                if let c = confirmed, c != 0 {
                    shares = c
                } else if let n = nav, n != 0 {
                    shares = amount / n
                } else if let later = candidates.first(where: { $0 >= date }),
                          let nv = navd[later] {
                    // 只给份额不给净值：用买入日之后第一个净值折算
                    shares = amount / nv
                } else {
                    shares = 0
                }
                events[f.code, default: []].append(
                    CurveEvent(date: date, amount: amount, shares: shares))
            }
        }
        for key in Array(events.keys) {
            events[key]!.sort { $0.date < $1.date }
        }

        // 所有出现过的净值日期（按时间升序），作为横轴
        var dateSet = Set<String>()
        for (_, d) in navs {
            for k in d.keys where k >= cutoff { dateSet.insert(k) }
        }
        let allDates = dateSet.sorted()
        if allDates.isEmpty { return empty }

        var cumSh: [String: Double] = [:]
        var cumAmt: [String: Double] = [:]
        var ptr: [String: Int] = [:]
        var pnav: [String: Int] = [:]
        for c in navOrder {
            cumSh[c] = 0
            cumAmt[c] = 0
            ptr[c] = 0
            pnav[c] = -1
        }

        var outD: [String] = []
        var outM: [Double] = []
        var outC: [Double] = []
        for d in allDates {
            var mv = 0.0
            for code in navOrder {
                let ev = events[code] ?? []
                var i = ptr[code] ?? 0
                while i < ev.count && ev[i].date <= d {
                    cumSh[code]! += ev[i].shares
                    cumAmt[code]! += ev[i].amount
                    i += 1
                }
                ptr[code] = i

                // 该基金「不晚于 d 的最近一个净值」
                let ds = navDates[code] ?? []
                var j = pnav[code] ?? -1
                while j + 1 < ds.count && ds[j + 1] <= d {
                    j += 1
                }
                pnav[code] = j
                if j >= 0, let sh = cumSh[code], sh != 0, let nv = navs[code]?[ds[j]] {
                    mv += sh * nv
                }
            }
            var costSum = 0.0
            for code in navOrder {
                costSum += cumAmt[code] ?? 0
            }
            outD.append(d)
            outM.append(fundRound(mv, 2))
            outC.append(fundRound(costSum, 2))
        }

        // 掐掉开头「还没开始买」的那些天，只保留一天让曲线从左下角起
        var start = 0
        while start < outC.count - 1 && outC[start] == 0 && outM[start] == 0 {
            start += 1
        }
        if start > 0 {
            start -= 1
            outD = Array(outD[start...])
            outM = Array(outM[start...])
            outC = Array(outC[start...])
        }

        return ["dates": outD, "mv": outM, "cost": outC]
    }

    // -------------------------------------------------------------- 排序

    /// Python 的 sort 是稳定排序，这里补上原始下标做 tie-break
    private func sortRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        let indexed = Array(rows.enumerated())
        return indexed.sorted { a, b in
            let av = fundNum(a.element["market_value"])
            let bv = fundNum(b.element["market_value"])
            if av == nil && bv != nil { return false }
            if av != nil && bv == nil { return true }
            let aa = av ?? 0
            let bb = bv ?? 0
            if aa != bb { return aa > bb }
            return a.offset < b.offset
        }.map { $0.element }
    }

    private func sortTransactions(_ tx: [[String: Any]]) -> [[String: Any]] {
        let indexed = Array(tx.enumerated())
        return indexed.sorted { a, b in
            let ad = (a.element["date"] as? String) ?? ""
            let bd = (b.element["date"] as? String) ?? ""
            if ad != bd { return ad > bd }
            let ac = (a.element["code"] as? String) ?? ""
            let bc = (b.element["code"] as? String) ?? ""
            if ac != bc { return ac > bc }
            return a.offset < b.offset
        }.map { $0.element }
    }
}
