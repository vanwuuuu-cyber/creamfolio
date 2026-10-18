import Foundation

// ==========================================================================
// 数据抓取层：逐函数对照 fund-dashboard/server.py
// 只依赖 Foundation，macOS 命令行可直接编译验证。
// ==========================================================================

// MARK: - 基础工具

/// 对应 server.py 的 _num：能转成有限 Double 就返回，否则 nil
func fundNum(_ x: Any?) -> Double? {
    guard let x = x, !(x is NSNull) else { return nil }
    if let d = x as? Double { return d.isFinite ? d : nil }
    if let i = x as? Int { return Double(i) }
    if let n = x as? NSNumber {
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    if let s = x as? String {
        guard let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite else { return nil }
        return d
    }
    return nil
}

/// 宽松取字符串（JSON 里可能是 NSNumber）
func fundStr(_ x: Any?) -> String? {
    guard let x = x, !(x is NSNull) else { return nil }
    if let s = x as? String { return s }
    if let n = x as? NSNumber { return n.stringValue }
    return nil
}

/// nil -> NSNull，方便拼出和 Python json.dumps 一样的 null
func fundJSON(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
func fundJSON(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
func fundJSON(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }

/// Python 风格的真值判断（0 / nil 为假）
func fundTruthy(_ v: Double?) -> Bool {
    guard let v = v else { return false }
    return v != 0
}

func fundFirstNonEmpty(_ values: [String?]) -> String? {
    for v in values {
        if let v = v, !v.isEmpty { return v }
    }
    return nil
}

/// 本地时区格式化（和 Python time.localtime / strftime 一致）
let fundDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

let fundSecondFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

let fundMonthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM"
    return f
}()

/// GB18030（GBK 的超集），新浪行情必须用它解码
let fundGB18030: String.Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

func fundDayString(_ date: Date) -> String { fundDayFormatter.string(from: date) }
func fundDayString(_ ts: TimeInterval) -> String {
    fundDayFormatter.string(from: Date(timeIntervalSince1970: ts))
}
func fundNowString(_ date: Date = Date()) -> String { fundSecondFormatter.string(from: date) }
func fundMonthString(_ date: Date) -> String { fundMonthFormatter.string(from: date) }
func fundDate(_ s: String) -> Date? { fundDayFormatter.date(from: String(s.prefix(10))) }
func fundIsDate(_ s: String) -> Bool {
    s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
}

/// 正则分组提取（group[0] 是整段，1... 是捕获组）
func fundRegexGroups(_ pattern: String, _ text: String,
                     options: NSRegularExpression.Options = []) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
    return matches.map { m in
        (0..<m.numberOfRanges).map { i -> String in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

func fundFirstGroup(_ pattern: String, _ text: String,
                    options: NSRegularExpression.Options = []) -> String? {
    guard let first = fundRegexGroups(pattern, text, options: options).first, first.count > 1 else {
        return nil
    }
    return first[1]
}

/// Python round(x, digits)：用 C 的 "%.Nf" 做十进制舍入（四舍六入五取偶），
/// 和 CPython 对浮点的结果一致。例：round(20.125, 2)=20.12、round(2.675, 2)=2.67。
/// 注意必须用不带 locale 的 String(format:)，带 locale 的版本会按最短描述舍入。
func fundRound(_ v: Double, _ digits: Int) -> Double {
    if !v.isFinite { return v }
    if abs(v) >= 1e15 { return v }
    let text = String(format: "%.\(digits)f", v)
    if let out = Double(text) { return out }
    // 极端情况下系统 locale 可能给出逗号小数点
    return Double(text.replacingOccurrences(of: ",", with: ".")) ?? v
}

/// 内存缓存：对应 server.py 的 cached()，支持取过期值兜底
final class FundCache {
    private var store: [String: (Date, Any)] = [:]
    private let lock = NSLock()

    func fresh(_ key: String, _ ttl: TimeInterval) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = store[key], Date().timeIntervalSince(hit.0) < ttl else { return nil }
        return hit.1
    }

    func any(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return store[key]?.1
    }

    func set(_ key: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        store[key] = (Date(), value)
    }
}

// MARK: - 数据模型

struct SubStatus {
    var text: String      // "暂停申购(单日投资上限10元)"
    var canBuy: Bool
    var minBuy: Double?
}

struct FundQuote {
    var name: String?
    var nav: Double?
    var navDate: String?
    var navChg: Double?
    /// QDII 基金东财不给盘中估值，恒为 nil
    var est: Double?
    var estChg: Double?

    init(name: String? = nil, nav: Double? = nil, navDate: String? = nil,
         navChg: Double? = nil, est: Double? = nil, estChg: Double? = nil) {
        self.name = name
        self.nav = nav
        self.navDate = navDate
        self.navChg = navChg
        self.est = est
        self.estChg = estChg
    }
}

struct NavPoint {
    let t: Int          // 秒级时间戳
    let v: Double
}

struct FundHistory {
    var code: String
    var name: String?
    var series: [NavPoint]
    var perf: [String: Double]

    init(code: String, name: String? = nil, series: [NavPoint] = [], perf: [String: Double] = [:]) {
        self.code = code
        self.name = name
        self.series = series
        self.perf = perf
    }
}

enum MarketPointKind {
    case index
    case future
    case fx
}

struct MarketPoint {
    var kind: MarketPointKind
    var name: String?
    var price: Double?
    var pct: Double?
    var time: String?
    var date: String?
    var prev: Double?
    var pips: Double?

    init(kind: MarketPointKind, name: String? = nil, price: Double? = nil, pct: Double? = nil,
         time: String? = nil, date: String? = nil, prev: Double? = nil, pips: Double? = nil) {
        self.kind = kind
        self.name = name
        self.price = price
        self.pct = pct
        self.time = time
        self.date = date
        self.prev = prev
        self.pips = pips
    }

    /// 字段和 server.py 的 idx() / fut() / fx() 返回值逐一对齐
    var jsonObject: [String: Any] {
        switch kind {
        case .index, .future:
            return [
                "name": fundJSON(name),
                "price": fundJSON(price),
                "pct": fundJSON(pct),
                "time": fundJSON(time),
                "date": fundJSON(date),
            ]
        case .fx:
            return [
                "name": fundJSON(name),
                "price": fundJSON(price),
                "prev": fundJSON(prev),
                "pct": fundJSON(pct),
                "pips": fundJSON(pips),
            ]
        }
    }
}

struct MarketData {
    var updated: String
    var ndx: MarketPoint?
    var spx: MarketPoint?
    var ixic: MarketPoint?
    var nq: MarketPoint?
    var es: MarketPoint?
    var usdcny: MarketPoint?

    var jsonObject: [String: Any] {
        return [
            "updated": updated,
            "ndx": ndx.map { $0.jsonObject as Any } ?? NSNull(),
            "spx": spx.map { $0.jsonObject as Any } ?? NSNull(),
            "ixic": ixic.map { $0.jsonObject as Any } ?? NSNull(),
            "nq": nq.map { $0.jsonObject as Any } ?? NSNull(),
            "es": es.map { $0.jsonObject as Any } ?? NSNull(),
            "usdcny": usdcny.map { $0.jsonObject as Any } ?? NSNull(),
        ]
    }

    static func empty(_ date: Date = Date()) -> MarketData {
        MarketData(updated: fundNowString(date))
    }
}

struct FundSearchItem {
    let code: String
    let name: String
    let type: String
    let company: String

    var jsonObject: [String: Any] {
        ["code": code, "name": name, "type": type, "company": company]
    }
}

enum FundAPIError: LocalizedError {
    case badURL(String)
    case badJSON(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "URL 不合法: \(u)"
        case .badJSON(let u): return "返回内容不是 JSON: \(u)"
        }
    }
}

// MARK: - 指数 / 汇率常量

/// track -> (腾讯美股代码, 东财 secid, 中文名)
let fundTrackIndex: [String: (tx: String, em: String, name: String)] = [
    "NDX": ("usNDX", "100.NDX100", "纳指100"),
    "SPX": ("us.INX", "100.SPX", "标普500"),
    "IXIC": ("usIXIC", "100.NDX", "纳斯达克"),
]

let fundFXSecid = "133.USDCNH"

// MARK: - 抓取

final class FundAPI {
    static let shared = FundAPI()

    private let cache = FundCache()
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    private let defaultReferer = "https://fund.eastmoney.com/"

    private let sinaSymbols = ["gb_ndx", "gb_inx", "gb_ixic", "hf_NQ", "hf_ES", "fx_susdcny"]

    private init() {}

    // ---------------------------------------------------------------- 底层

    /// 对应 server.py 的 _fetch：带 UA / Referer，失败重试 3 次
    /// 申购状态（暂停/限大额/正常）+ 单日限额。东财 FundBaseTypeInformation。
    /// 缓存 12 小时 —— 状态不会一天变好几次。
    func subStatusCached(code: String) async -> SubStatus? {
        let key = "sub:" + code
        if let fresh = cache.fresh(key, 12 * 3600) as? SubStatus { return fresh }
        let url = "https://fundmobapi.eastmoney.com/FundMApi/FundBaseTypeInformation.ashx"
            + "?FCODE=\(code)&deviceid=x&plat=Android&product=EFund&version=1"
        guard let text = try? await fetchText(url, referer: "https://fund.eastmoney.com/"),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["Datas"] as? [String: Any] else { return nil }
        let st = SubStatus(
            text: (d["SGZT"] as? String) ?? "",
            canBuy: (d["BUY"] as? Bool) ?? true,
            minBuy: fundNum(d["MINSG"])
        )
        cache.set(key, st)
        return st
    }

    private func fetchText(_ urlString: String, referer: String? = nil,
                           encoding: String.Encoding? = nil,
                           timeout: TimeInterval = 15) async throws -> String {
        guard let url = URL(string: urlString) else { throw FundAPIError.badURL(urlString) }
        var lastError: Error = FundAPIError.badURL(urlString)

        for attempt in 1...3 {
            do {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: timeout)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                req.setValue(referer ?? defaultReferer, forHTTPHeaderField: "Referer")

                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                if let encoding = encoding,
                   let text = String(data: data, encoding: encoding) {
                    return text
                }
                if let text = String(data: data, encoding: .utf8) { return text }
                if let text = String(data: data, encoding: fundGB18030) { return text }
                return String(decoding: data, as: UTF8.self)
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        throw lastError
    }

    private func jsonObject(_ text: String, _ tag: String) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw FundAPIError.badJSON(tag)
        }
        return obj
    }

    private func cachedDict(_ key: String, _ ttl: TimeInterval,
                            _ compute: () async -> [String: Double]) async -> [String: Double] {
        if let fresh = cache.fresh(key, ttl) as? [String: Double] { return fresh }
        let value = await compute()
        cache.set(key, value)
        return value
    }

    // 给 PortfolioEngine 用的缓存直通口（β 用）
    func cacheValue(_ key: String, maxAge: TimeInterval) -> Any? { cache.fresh(key, maxAge) }
    func cacheAny(_ key: String) -> Any? { cache.any(key) }
    func cacheStore(_ key: String, _ value: Any) { cache.set(key, value) }

    // ---------------------------------------------------------- 1. 批量行情

    /// 对应 fetch_quotes
    func fetchQuotes(codes: [String]) async throws -> [String: FundQuote] {
        if codes.isEmpty { return [:] }
        let url = "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo"
            + "?pageIndex=1&pageSize=200&plat=Android&appType=ttjj&product=EFund"
            + "&Version=1&deviceid=dsh-fund-dashboard&Fcodes=" + codes.joined(separator: ",")
        let text = try await fetchText(url)
        let obj = try jsonObject(text, "quotes")
        var out: [String: FundQuote] = [:]
        for item in (obj["Datas"] as? [Any]) ?? [] {
            guard let d = item as? [String: Any], let code = fundStr(d["FCODE"]) else { continue }
            out[code] = FundQuote(
                name: fundStr(d["SHORTNAME"]),
                nav: fundNum(d["NAV"]),
                navDate: fundStr(d["PDATE"]),
                navChg: fundNum(d["NAVCHGRT"]),
                est: fundNum(d["GSZ"]),
                estChg: fundNum(d["GSZZL"])
            )
        }
        return out
    }

    /// fetch_quotes + TTL 缓存（行情 60s，配置里可改）
    func quotesCached(codes: [String], ttl: TimeInterval) async -> [String: FundQuote] {
        if codes.isEmpty { return [:] }
        let key = "quotes:" + codes.sorted().joined(separator: ",")
        if let fresh = cache.fresh(key, ttl) as? [String: FundQuote] { return fresh }
        do {
            let value = try await fetchQuotes(codes: codes)
            cache.set(key, value)
            return value
        } catch {
            return (cache.any(key) as? [String: FundQuote]) ?? [:]
        }
    }

    // ------------------------------------------------------ 2. 历史净值

    /// 对应 fetch_history
    func fetchHistory(code: String) async throws -> FundHistory {
        let url = "https://fund.eastmoney.com/pingzhongdata/\(code).js"
        let text = try await fetchText(url, referer: "https://fund.eastmoney.com/\(code).html")

        var out = FundHistory(code: code)
        if let name = fundFirstGroup(#"var fS_name\s*=\s*"([^"]*)""#, text) {
            out.name = name
        }
        if let body = fundFirstGroup(#"var Data_netWorthTrend\s*=\s*(\[.*?\]);"#, text,
                                     options: [.dotMatchesLineSeparators]),
           let arr = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [Any] {
            for item in arr {
                guard let d = item as? [String: Any],
                      let ts = fundNum(d["x"]), let nav = fundNum(d["y"]),
                      ts > 0, ts < 1e15 else { continue }
                out.series.append(NavPoint(t: Int(ts) / 1000, v: nav))
            }
        }
        let perfKeys: [(String, String)] = [
            ("syl_1y", "近1月"), ("syl_3y", "近3月"),
            ("syl_6y", "近6月"), ("syl_1n", "近1年"),
        ]
        for (key, label) in perfKeys {
            let pattern = #"var "# + key + #"\s*=\s*"?(-?[\d.]+)"?"#
            if let s = fundFirstGroup(pattern, text), let v = Double(s) {
                out.perf[label] = v
            }
        }
        return out
    }

    /// 对应 build() 里的 hist 缓存（6h）
    func historyCached(code: String, ttl: TimeInterval = 6 * 3600) async -> FundHistory {
        let key = "hist:" + code
        if let fresh = cache.fresh(key, ttl) as? FundHistory { return fresh }
        do {
            let value = try await fetchHistory(code: code)
            cache.set(key, value)
            return value
        } catch {
            return (cache.any(key) as? FundHistory) ?? FundHistory(code: code)
        }
    }

    // -------------------------------------------------- 3. 新浪指数 / 期货 / 汇率

    /// 对应 fetch_market。响应是 GBK，必须 GB18030 解码。
    func fetchMarket() async throws -> MarketData {
        let url = "https://hq.sinajs.cn/list=" + sinaSymbols.joined(separator: ",")
        let text = try await fetchText(url, referer: "https://finance.sina.com.cn",
                                       encoding: fundGB18030)
        var raw: [String: String] = [:]
        for line in text.components(separatedBy: CharacterSet.newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let groups = fundRegexGroups(#"^var hq_str_([^=]+)="(.*)";"#, trimmed).first,
                  groups.count >= 3 else { continue }
            raw[groups[1]] = groups[2]
        }

        func idx(_ sym: String) -> MarketPoint? {
            let f = (raw[sym] ?? "").components(separatedBy: ",")
            if f.count < 3 { return nil }
            let time = f.count > 3 ? f[3] : ""
            return MarketPoint(
                kind: .index,
                name: f[0],
                price: fundNum(f[1]),
                pct: fundNum(f[2]),
                time: time,
                date: f.count > 3 ? String(f[3].prefix(10)) : ""
            )
        }

        func fut(_ sym: String) -> MarketPoint? {
            // 外盘期货字段：0最新 1买价 2卖价 3昨结算 4最高 5最低 6时间 7昨收 8今开
            let f = (raw[sym] ?? "").components(separatedBy: ",")
            if f.count < 9 { return nil }
            let price = fundNum(f[0])
            var prev = fundNum(f[7])
            if prev == nil || prev == 0 { prev = fundNum(f[3]) }
            var pct: Double? = nil
            if let p = price, let q = prev, p != 0, q != 0 {
                pct = (p / q - 1) * 100
            }
            if let p = pct, abs(p) > 15 { pct = nil }   // 脏数据保护
            return MarketPoint(
                kind: .future,
                name: f.count > 13 ? f[13] : sym,
                price: price,
                pct: pct,
                time: f.count > 6 ? f[6] : "",
                date: f.count > 12 ? f[12] : ""
            )
        }

        func fx(_ sym: String) -> MarketPoint? {
            // 外汇字段：1昨收 ... 8最新价
            let f = (raw[sym] ?? "").components(separatedBy: ",")
            if f.count < 10 { return nil }
            var last = fundNum(f[8])
            var prev = fundNum(f[1])
            if last == nil {
                last = fundNum(f[1])
                prev = fundNum(f[2])
            }
            var pct: Double? = nil
            if let a = last, let b = prev, a != 0, b != 0 {
                pct = (a / b - 1) * 100
            }
            var pips: Double? = nil
            if let a = last, let b = prev, a != 0, b != 0 {
                pips = (a - b) * 10000
            }
            return MarketPoint(
                kind: .fx,
                name: f[9],
                price: last,
                pct: pct,
                time: "",
                date: "",
                prev: prev,
                pips: pips
            )
        }

        return MarketData(
            updated: fundNowString(),
            ndx: idx("gb_ndx"),
            spx: idx("gb_inx"),
            ixic: idx("gb_ixic"),
            nq: fut("hf_NQ"),
            es: fut("hf_ES"),
            usdcny: fx("fx_susdcny")
        )
    }

    /// fetch_market + TTL 缓存（30s，配置里可改）；失败回退旧数据，没有旧数据则抛错
    func marketCached(ttl: TimeInterval) async throws -> MarketData {
        if let fresh = cache.fresh("market", ttl) as? MarketData { return fresh }
        do {
            let value = try await fetchMarket()
            cache.set("market", value)
            return value
        } catch {
            if let stale = cache.any("market") as? MarketData { return stale }
            throw error
        }
    }

    // ------------------------------------------------ 4. 指数历史（腾讯 / 东财）

    /// 腾讯美股日线：[[日期, 开, 收, 高, 低, 量...], ...] -> {日期: 收盘}
    private func tencentKline(_ sym: String, lmt: Int) async throws -> [String: Double] {
        let url = "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get"
            + "?_var=k&param=\(sym),day,,,\(lmt),qfq"
        let text = try await fetchText(url, referer: "https://gu.qq.com/")
        // JSONP：剥掉 "k=" 前缀
        var body = text
        if let i = text.firstIndex(of: "=") {
            body = String(text[text.index(after: i)...])
        }
        let obj = try jsonObject(body, "tencent:" + sym)
        let data = obj["data"] as? [String: Any]
        let node = data?[sym] as? [String: Any]
        var out: [String: Double] = [:]
        for row in (node?["day"] as? [[Any]]) ?? [] {
            guard row.count >= 3, let date = fundStr(row[0]), let close = fundNum(row[2]),
                  close != 0 else { continue }
            out[date] = close
        }
        return out
    }

    /// 东财日线："日期,开,收,高,低,..." -> {日期: 收盘}
    private func emKline(_ secid: String, lmt: Int) async throws -> [String: Double] {
        let url = "https://push2his.eastmoney.com/api/qt/stock/kline/get"
            + "?secid=\(secid)&fields1=f1,f2,f3,f4,f5&fields2=f51,f52,f53,f54,f55"
            + "&klt=101&fqt=1&end=20500101&lmt=\(lmt)"
        let text = try await fetchText(url, referer: "https://quote.eastmoney.com/")
        let obj = try jsonObject(text, "em:" + secid)
        let data = obj["data"] as? [String: Any]
        var out: [String: Double] = [:]
        for item in (data?["klines"] as? [Any]) ?? [] {
            guard let line = item as? String else { continue }
            let p = line.components(separatedBy: ",")
            guard p.count >= 3, let close = fundNum(p[2]), close != 0 else { continue }
            out[p[0]] = close
        }
        return out
    }

    /// 对应 fetch_index_history：腾讯优先，东财兜底，都失败返回 [:]（3h 缓存）
    func fetchIndexHistory(track: String, lmt: Int = 260) async -> [String: Double] {
        guard let pair = fundTrackIndex[track.uppercased()] else { return [:] }
        return await cachedDict("idx:" + pair.tx, 3 * 3600) {
            do {
                let d = try await self.tencentKline(pair.tx, lmt: lmt)
                if d.count >= 30 { return d }
            } catch {
                // 腾讯失败，走东财
            }
            do {
                let d = try await self.emKline(pair.em, lmt: lmt)
                if d.count >= 30 { return d }
            } catch {
                // 都失败
            }
            return [:]
        }
    }

    /// 对应 fetch_fx_history：拿不到返回 [:]（3h 缓存，不抛错）
    func fetchFXHistory(lmt: Int = 120) async -> [String: Double] {
        return await cachedDict("fx:hist", 3 * 3600) {
            do {
                let d = try await self.emKline(fundFXSecid, lmt: lmt)
                return d.count >= 20 ? d : [:]
            } catch {
                return [:]
            }
        }
    }

    // ------------------------------------------------------------ 5. 搜索

    /// 对应 search_funds
    func searchFunds(keyword: String, limit: Int = 20) async throws -> [FundSearchItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty { return [] }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        let encoded = kw.addingPercentEncoding(withAllowedCharacters: allowed) ?? kw
        let url = "https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx"
            + "?m=1&key=" + encoded
        let text = try await fetchText(url, referer: "https://fund.eastmoney.com/")
        let obj = try jsonObject(text, "search")
        var out: [FundSearchItem] = []
        for item in (obj["Datas"] as? [Any]) ?? [] {
            guard let d = item as? [String: Any], let code = fundStr(d["CODE"]),
                  code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else { continue }
            let fb = d["FundBaseInfo"] as? [String: Any] ?? [:]
            let name = fundFirstNonEmpty([fundStr(fb["SHORTNAME"]), fundStr(d["NAME"])]) ?? code
            out.append(FundSearchItem(
                code: code,
                name: name,
                type: fundStr(fb["FTYPE"]) ?? "",
                company: fundStr(fb["JJGS"]) ?? ""
            ))
            if out.count >= limit { break }
        }
        return out
    }

    // ---------------------------------------------- 6. 分红（server.py 没有，可选）

    /// 对应东财 F10 分红送配。server.py 未实现此接口，字段原样返回给调用方。
    func fetchDividends(code: String) async throws -> [[String: Any]] {
        let url = "https://api.fund.eastmoney.com/f10/FHSP?fundCode=\(code)"
        let text = try await fetchText(url, referer: "https://fundf10.eastmoney.com/")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return []
        }
        return obj["Data"] as? [[String: Any]] ?? []
    }
}
