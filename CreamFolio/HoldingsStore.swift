import Foundation

// ==========================================================================
// 本地持仓存储：替代 fund-dashboard/holdings.json 与 server.py 的写操作
// 存到 App 的 Documents/holdings.json，结构和原来一致。
// ==========================================================================

enum HoldingsError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

final class HoldingsStore {
    static let shared = HoldingsStore()

    private let fileName = "holdings.json"
    private let fileManager = FileManager.default

    private init() {}

    /// Documents/holdings.json
    var fileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return docs.appendingPathComponent(fileName)
    }

    var hasSavedFile: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    // ------------------------------------------------------------ 读写

    /// 对应 load_config
    func load() -> HoldingsConfig {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HoldingsConfig()
        }
        return HoldingsConfig(json: obj)
    }

    /// 对应 save_config
    func save(_ cfg: HoldingsConfig) throws {
        let data = try JSONSerialization.data(withJSONObject: cfg.jsonObject(),
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        var out = data
        out.append(0x0A)
        try out.write(to: fileURL, options: .atomic)
    }

    /// 首次启动迁移：Documents 里没有 holdings.json 时，从旧 Python 服务拉一次。
    /// 地址取 App 里已保存的 serverBase（UserDefaults），尽力而为，失败就留空。
    func loadOrMigrate() async -> HoldingsConfig {
        if hasSavedFile { return load() }
        if let base = UserDefaults.standard.string(forKey: "serverBase"), !base.isEmpty,
           let cfg = await migrateFromServer(base) {
            return cfg
        }
        return load()
    }

    /// 从旧服务 /api/data 还原持仓。旧接口不暴露原始 lots 之外的字段，属于有损迁移。
    func migrateFromServer(_ base: String) async -> HoldingsConfig? {
        if hasSavedFile { return load() }
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty, let url = URL(string: b + "/api/data") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = obj["funds"] as? [[String: Any]] else { return nil }

        var funds: [HoldingFund] = []
        for row in rows {
            guard let code = fundStr(row["code"]) else { continue }
            let name = fundStr(row["name"]) ?? code
            var lots: [[Any]] = []
            for l in (row["lots"] as? [[String: Any]]) ?? [] {
                guard let d = fundStr(l["date"]), let amount = fundNum(l["amount"]) else { continue }
                var arr: [Any] = [d, amount]
                arr.append(fundNum(l["nav"]).map { $0 as Any } ?? NSNull())
                arr.append(fundNum(l["shares"]).map { $0 as Any } ?? NSNull())
                lots.append(arr)
            }
            var f = HoldingFund(
                code: code,
                name: name,
                platform: fundStr(row["platform"]) ?? "",
                track: fundStr(row["track"]) ?? "",
                ratio: fundNum(row["ratio"]) ?? 0.95,
                lots: lots
            )
            if (row["shares_source"] as? String) == "manual" {
                f.shares = fundNum(row["shares"])
                f.cost = fundNum(row["cost"])
            }
            funds.append(f)
        }

        let cfg = HoldingsConfig(funds: funds)
        try? save(cfg)
        return cfg
    }

    // ------------------------------------------------------------ 写操作

    /// 对应 add_fund：新增基金；名称 / 跟踪指数自动识别，已存在则直接返回
    @discardableResult
    func addFund(code rawCode: String, platform: String? = nil,
                 track: String? = nil) async throws -> HoldingFund {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
            throw HoldingsError.message("基金代码必须是 6 位数字")
        }

        var cfg = load()
        if let i = cfg.funds.firstIndex(where: { $0.code == code }) {
            if let platform = platform, !platform.isEmpty { cfg.funds[i].platform = platform }
            if let track = track, !track.isEmpty { cfg.funds[i].track = track }
            try save(cfg)
            return cfg.funds[i]
        }

        // 查一下名字；查不到说明代码不存在。网络异常时无法校验，就放过去。
        var info: FundQuote? = nil
        var checked = true
        do {
            info = try await FundAPI.shared.fetchQuotes(codes: [code])[code]
        } catch {
            checked = false
        }
        if checked && (info?.name ?? "").isEmpty {
            throw HoldingsError.message("查不到这个基金代码：\(code)")
        }

        let name = fundFirstNonEmpty([info?.name]) ?? code
        let resolvedTrack = fundFirstNonEmpty([track, guessTrack(name)]) ?? ""
        let fund = HoldingFund(
            code: code,
            name: name,
            platform: platform ?? "",
            track: resolvedTrack,
            ratio: 0.95,
            lots: []
        )
        cfg.funds.append(fund)
        try save(cfg)
        return fund
    }

    /// 对应 add_buy：记一笔买入，基金不存在时自动创建
    @discardableResult
    func addBuy(code rawCode: String, amount: Double, date: String? = nil) async throws -> [String: Any] {
        if amount <= 0 {
            throw HoldingsError.message("金额必须大于 0")
        }
        let dateStr = (date ?? fundDayString(Date()))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fundIsDate(dateStr) else {
            throw HoldingsError.message("日期格式应为 YYYY-MM-DD")
        }

        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        try await addFund(code: code, platform: nil, track: nil)   // 不存在则创建

        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        cfg.funds[i].lots.append([dateStr, amount])
        // 手写的 shares 会覆盖按 lots 推算的份额，这里清掉以免加了笔数还不生效
        cfg.funds[i].shares = nil
        cfg.funds[i].cost = nil
        try save(cfg)

        var total = 0.0
        for lot in cfg.funds[i].lots {
            total += fundNum(lot.count > 1 ? lot[1] : nil) ?? 0
        }
        return [
            "code": code,
            "name": cfg.funds[i].name,
            "date": dateStr,
            "amount": amount,
            "lots_count": cfg.funds[i].lots.count,
            "total_invested": total,
        ]
    }

    /// 记一笔卖出/赎回。
    /// 用「负数 lot」表示：[日期, -金额, 净值, -份额]。
    /// 这样份额、成本、XIRR、账户曲线全都自动正确 —— 因为它们本来就是求和。
    @discardableResult
    func addSell(code rawCode: String, amount: Double, date: String? = nil,
                 shares: Double? = nil) async throws -> [String: Any] {
        guard amount > 0 else {
            throw HoldingsError.message("赎回金额必须大于 0")
        }
        if let shares = shares, shares <= 0 {
            throw HoldingsError.message("赎回份额必须大于 0")
        }
        let dateStr = (date ?? fundDayString(Date()))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fundIsDate(dateStr) else {
            throw HoldingsError.message("日期格式应为 YYYY-MM-DD")
        }

        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }

        // 填了份额就顺手校验一下，别把持仓卖成负的
        if let shares = shares {
            let held = heldShares(cfg.funds[i])
            if held > 0 && shares > held + 0.0001 {
                throw HoldingsError.message(
                    String(format: "最多只能赎回 %.4f 份", held))
            }
        }

        var lot: [Any] = [dateStr, -fundRound(amount, 2)]
        if let shares = shares {
            lot.append(NSNull())                       // 净值留空，由引擎按当天查
            lot.append(-fundRound(shares, 4))
        }
        cfg.funds[i].lots.append(lot)
        cfg.funds[i].shares = nil
        cfg.funds[i].cost = nil
        try save(cfg)

        return [
            "code": code,
            "name": cfg.funds[i].name,
            "date": dateStr,
            "amount": amount,
            "lots_count": cfg.funds[i].lots.count,
        ]
    }

    /// 当前持有份额（用于卖出校验）。拿不到净值的买入按 0 计，宁松不严。
    func heldShares(_ f: HoldingFund) -> Double {
        var total = 0.0
        for lot in f.lots {
            if lot.count > 3, let s = fundNum(lot[3]) {
                total += s
            } else if lot.count > 1, let a = fundNum(lot[1]) {
                let nav = lot.count > 2 ? fundNum(lot[2]) : nil
                if let nav = nav, nav != 0 {
                    total += a / nav
                }
            }
        }
        return total
    }

    /// 对应 remove_lot：删除某一笔买入
    @discardableResult
    func removeLot(code: String, date: String, amount: Double) throws -> [String: Any] {
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        for (j, lot) in cfg.funds[i].lots.enumerated() {
            guard lot.count >= 2, fundStr(lot[0]) == date,
                  let v = fundNum(lot[1]) else { continue }
            if abs(v - amount) < 0.005 {
                cfg.funds[i].lots.remove(at: j)
                try save(cfg)
                return ["removed": true, "lots_count": cfg.funds[i].lots.count]
            }
        }
        throw HoldingsError.message("没找到这一笔记录")
    }

    /// 对应 remove_fund：整只基金移除（连同买入记录）
    @discardableResult
    func removeFund(code: String) throws -> [String: Any] {
        var cfg = load()
        let before = cfg.funds.count
        cfg.funds.removeAll { $0.code == code }
        if cfg.funds.count == before {
            throw HoldingsError.message("没有这只基金")
        }
        try save(cfg)
        return ["removed": true, "fund_count": cfg.funds.count]
    }

    /// 对应 set_manual：直接写死份额 / 成本 / 平台 / 跟踪指数。
    /// shares 传 nil 表示改回按买入记录推算。
    @discardableResult
    func setManual(code: String, shares: Double?, cost: Double?,
                   platform: String? = nil, track: String? = nil,
                   ratio: Double? = nil) throws -> HoldingFund {
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }

        if let shares = shares {
            if shares < 0 { throw HoldingsError.message("份额不能为负") }
            cfg.funds[i].shares = fundRound(shares, 4)
        } else {
            cfg.funds[i].shares = nil
        }

        if let cost = cost {
            cfg.funds[i].cost = fundRound(cost, 2)
        } else {
            cfg.funds[i].cost = nil
        }

        if let platform = platform { cfg.funds[i].platform = platform }
        if let track = track { cfg.funds[i].track = track }
        if let ratio = ratio { cfg.funds[i].ratio = ratio }

        try save(cfg)
        return cfg.funds[i]
    }

    /// 新增 / 修改一个定投生效段（同一天已有就覆盖金额）
    @discardableResult
    func addPlan(code: String, start: String, amount: Double) throws -> HoldingFund {
        // 允许填 0：表示「从这天起停止」（基金暂停申购、外汇额度用完等）
        guard amount >= 0 else { throw HoldingsError.message("定投金额不能为负数") }
        guard fundIsDate(start) else { throw HoldingsError.message("日期格式应为 YYYY-MM-DD") }
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        var plans = cfg.funds[i].plans.filter { $0.start != start }
        plans.append(PlanSegment(start: start, amount: fundRound(amount, 2)))
        cfg.funds[i].plans = plans.sorted { $0.start < $1.start }
        try save(cfg)
        return cfg.funds[i]
    }

    /// 标记「这天定投没买成」—— 计划本该买，但实际失败了
    @discardableResult
    func addSkip(code: String, date: String) throws -> HoldingFund {
        guard fundIsDate(date) else { throw HoldingsError.message("日期格式应为 YYYY-MM-DD") }
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        if !cfg.funds[i].skips.contains(date) {
            cfg.funds[i].skips.append(date)
            cfg.funds[i].skips.sort()
        }
        try save(cfg)
        return cfg.funds[i]
    }

    /// 取消「这天没买成」的标记，让定投记录重新生成
    @discardableResult
    func removeSkip(code: String, date: String) throws -> HoldingFund {
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        cfg.funds[i].skips.removeAll { $0 == date }
        try save(cfg)
        return cfg.funds[i]
    }

    /// 删除某个生效段
    @discardableResult
    func removePlan(code: String, start: String) throws -> HoldingFund {
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        cfg.funds[i].plans.removeAll { $0.start == start }
        try save(cfg)
        return cfg.funds[i]
    }

    /// 改跟踪指数。传空字符串表示「不估算」—— 这一点 addFund 做不到，
    /// 因为它在 track 为空时会退回 guessTrack() 的结果。
    @discardableResult
    func setTrack(code: String, track: String) throws -> HoldingFund {
        var cfg = load()
        guard let i = cfg.funds.firstIndex(where: { $0.code == code }) else {
            throw HoldingsError.message("没有这只基金")
        }
        cfg.funds[i].track = track.trimmingCharacters(in: .whitespaces)
        try save(cfg)
        return cfg.funds[i]
    }
}
