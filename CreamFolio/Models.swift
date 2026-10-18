import Foundation

// MARK: - 行情

struct MarketQuote: Decodable {
    let name: String?
    let price: Double?
    let pct: Double?
    let time: String?
    let prev: Double?
    let pips: Double?
}

struct Market: Decodable {
    let updated: String?
    let ndx: MarketQuote?
    let spx: MarketQuote?
    let ixic: MarketQuote?
    let nq: MarketQuote?
    let es: MarketQuote?
    let usdcny: MarketQuote?
}

// MARK: - 基金

struct SeriesPoint: Decodable, Identifiable {
    let t: Int
    let v: Double
    var id: Int { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

struct Lot: Decodable, Identifiable {
    let date: String
    let amount: Double
    let nav: Double?
    let navDate: String?
    let shares: Double
    let cumAmount: Double
    let cumShares: Double
    let value: Double?
    let profit: Double?
    let profitPct: Double?
    /// true 表示这笔由定投计划自动生成，不能直接删
    let auto: Bool?
    var id: String { "\(date)-\(amount)" }
}

/// 定投计划的一个生效段（只读，给界面用）
struct FundPlan: Decodable, Identifiable {
    let start: String
    let amount: Double
    var id: String { start }
}

struct FundItem: Decodable, Identifiable {
    let code: String
    let name: String
    let platform: String
    let track: String
    let ratio: Double
    let shares: Double
    let cost: Double
    let avgCostNav: Double?
    let nav: Double?
    let navDate: String?
    let navChg: Double?
    let marketValue: Double?
    let profit: Double?
    let profitPct: Double?
    let estPct: Double?
    let estSrc: String?
    let estProfit: Double?
    let estBeta: Double?
    let estBetaN: Int?
    let estFrom: String?
    let estTo: String?
    let estDays: Int?
    let estLive: Bool?
    let perf: [String: Double]
    let lots: [Lot]
    let lotsCount: Int
    let firstBuy: String?
    let lastBuy: String?
    let series: [SeriesPoint]
    /// 这只基金的资金加权年化（XIRR）
    let xirr: Double?
    let xirrDays: Int?
    /// 定投计划（按生效日期分段）
    let plans: [FundPlan]?
    /// 定投本该买但实际没买成的日期
    let skips: [String]?
    /// 资产大类（美股 / 黄金白银 / A股指数 / 主动混合 / 港股 / 红利）
    let kind: String?
    /// 申购状态文字，比如「暂停申购(单日投资上限10元)」
    let sgzt: String?
    /// 现在还能不能买
    let canBuy: Bool?
    let minBuy: Double?

    var id: String { code }
    var seriesValues: [Double] { series.map(\.v) }
}

// MARK: - 汇总

struct PlatformSummary: Decodable, Identifiable {
    let platform: String
    let marketValue: Double
    let cost: Double
    let count: Int
    let lots: Int
    let profit: Double
    let profitPct: Double?
    var id: String { platform }
}

struct Transaction: Decodable, Identifiable {
    let date: String
    let code: String
    let name: String
    let platform: String
    let amount: Double
    let nav: Double?
    let shares: Double
    var id: String { "\(date)-\(code)-\(amount)" }
}

struct Summary: Decodable {
    let marketValue: Double
    let cost: Double
    let profit: Double
    let profitPct: Double?
    let estProfit: Double?
    let estPct: Double?
    let fundCount: Int
    let platformCount: Int
    let lotsCount: Int
    let monthAmount: Double
    let monthCount: Int
    /// 资金加权年化收益率（XIRR），0.15 表示 15%
    let xirr: Double?
    /// XIRR 覆盖了多少天。太短（< 30 天）时年化会失真，界面上要提示
    let xirrDays: Int?
    /// 参与净値预估的市值（只有认得出跟踪指数的基金才算）
    let estMv: Double?
    /// 预估覆盖率 0…1
    let estCoverage: Double?
    /// 最大回撤（负数，百分比）
    let maxDrawdown: Double?
    let maxDrawdownDate: String?
    /// 年化波动率（百分比）
    let volatility: Double?
}

/// 按资产大类的汇总
struct KindSummary: Decodable, Identifiable {
    let kind: String
    let count: Int
    let marketValue: Double
    let cost: Double
    var id: String { kind }
    var profit: Double { marketValue - cost }
}

/// 账户历史曲线：按每日净值反推的市值与累计投入
struct Curve: Decodable {
    let dates: [String]
    let mv: [Double]
    let cost: [Double]

    var isEmpty: Bool { dates.isEmpty }
}

// MARK: - 接口响应

struct Dashboard: Decodable {
    let updated: String
    let market: Market
    let summary: Summary
    let curve: Curve?
    let kinds: [KindSummary]?
    let funds: [FundItem]
    let platforms: [PlatformSummary]
    let transactions: [Transaction]
}

struct FundDetailResponse: Decodable {
    let updated: String
    let market: Market
    let fund: FundItem
}

struct APIErrorBody: Decodable, Error, LocalizedError {
    let error: String
    var errorDescription: String? { error }
}

// MARK: - 基金搜索 / 写操作

struct FundSearchResult: Decodable, Identifiable {
    let code: String
    let name: String
    let type: String
    let company: String
    var id: String { code }

    init(code: String, name: String, type: String = "", company: String = "") {
        self.code = code
        self.name = name
        self.type = type
        self.company = company
    }
}

struct FundSearchResponse: Decodable {
    let results: [FundSearchResult]
}
