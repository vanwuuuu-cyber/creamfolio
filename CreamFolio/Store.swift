import Foundation
import SwiftUI

/// 数据从哪来：本机自己算，还是连电脑上的服务器
///
/// - 本机：App 直接调天天基金 / 腾讯 / 新浪的公开接口，自己算份额、净值预估、β、XIRR，
///   持仓存在手机的 Documents 里。不需要电脑开着。
/// - 服务器：保留原来的 python3 server.py 模式，作为上游接口变动时的备用通道。
@MainActor
final class AppState: ObservableObject {
    @Published var dashboard: Dashboard?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    /// 本机模式（默认开）
    @Published var useLocal: Bool {
        didSet {
            guard useLocal != oldValue else { return }
            UserDefaults.standard.set(useLocal, forKey: AppState.localKey)
            Task { await load() }
        }
    }

    @Published var serverBase: String {
        didSet { UserDefaults.standard.set(serverBase, forKey: AppState.storageKey) }
    }

    /// 设置页显示的持仓文件说明
    var storageNote: String {
        let name = HoldingsStore.shared.fileURL.lastPathComponent
        if let n = dashboard?.summary.lotsCount {
            return "\(n) 笔 · \(name)"
        }
        return name
    }

    private static let storageKey = "serverBase"
    private static let localKey = "useLocal"

    private var refreshTask: Task<Void, Never>?
    private let session: URLSession
    /// 本机模式下的持仓缓存，避免每次刷新都读盘
    private var localHoldings: HoldingsConfig?

    init() {
        let saved = UserDefaults.standard.string(forKey: AppState.storageKey) ?? ""
        serverBase = saved.isEmpty ? "http://127.0.0.1:8848" : saved
        useLocal = (UserDefaults.standard.object(forKey: AppState.localKey) as? Bool) ?? true

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    var baseURL: URL? {
        let s = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s), u.scheme != nil else { return nil }
        return u
    }

    // MARK: - 自动刷新

    func startAutoRefresh(seconds: UInt64 = 60) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.load(silent: true)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - 加载

    func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        defer { isLoading = false }

        if useLocal {
            await loadLocal()
        } else {
            await loadRemote()
        }
    }

    private func loadLocal() async {
        let cfg = await holdings()
        let obj = await PortfolioEngine.shared.dashboard(holdings: cfg)
        do {
            let d = try Self.decode(Dashboard.self, from: obj)
            dashboard = d
            lastUpdated = Date()

            // 引擎对网络错误是宽容的（会返回空行情继续算），
            // 所以「有持仓却一个市值都算不出来」只可能是行情没拿到 ——
            // 这时必须明确告诉用户，否则看起来像持仓丢了。
            if !d.funds.isEmpty && d.funds.allSatisfy({ $0.marketValue == nil }) {
                errorMessage = "拿不到行情数据，检查一下网络。持仓没丢，都存在手机本地。"
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = "本地数据解析失败：\(error.localizedDescription)"
        }
    }

    private func loadRemote() async {
        guard let base = baseURL else {
            errorMessage = "服务器地址无效，请到「设置」里填写电脑的局域网地址"
            return
        }
        do {
            let d: Dashboard = try await get(base.appendingPathComponent("api/data"))
            dashboard = d
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 取本机持仓；首次启动时把内置的真实持仓写进 Documents
    private func holdings() async -> HoldingsConfig {
        if let cached = localHoldings { return cached }
        let cfg: HoldingsConfig
        if HoldingsStore.shared.hasSavedFile {
            cfg = HoldingsStore.shared.load()
        } else if let seed = Self.bundledSeed() {
            try? HoldingsStore.shared.save(seed)
            cfg = seed
        } else {
            cfg = await HoldingsStore.shared.loadOrMigrate()
        }
        localHoldings = cfg
        return cfg
    }

    private static func bundledSeed() -> HoldingsConfig? {
        guard let url = Bundle.main.url(forResource: "holdings-seed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return HoldingsConfig(json: obj)
    }

    /// 本机写操作之后：重新读盘 + 重算
    private func reloadLocal() async {
        localHoldings = HoldingsStore.shared.load()
        await load(silent: true)
    }

    // MARK: - 单只基金详情

    func fundDetail(code: String) async throws -> FundItem {
        if useLocal {
            let cfg = await holdings()
            guard let obj = await PortfolioEngine.shared.fundDetail(code: code, holdings: cfg) else {
                throw URLError(.fileDoesNotExist)
            }
            return try Self.decode(FundDetailResponse.self, from: obj).fund
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        let r: FundDetailResponse = try await get(base.appendingPathComponent("api/fund/\(code)"))
        return r.fund
    }

    // MARK: - 解码

    private static func decode<T: Decodable>(_ type: T.Type, from obj: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let e = try? JSONDecoder().decode(APIErrorBody.self, from: data) { throw e }
            throw URLError(.badServerResponse)
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    @discardableResult
    private func post(_ url: URL, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let e = try? JSONDecoder().decode(APIErrorBody.self, from: data) { throw e }
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - 写操作

    /// 记一笔买入（基金不存在会自动创建）
    func addBuy(code: String, amount: Double, date: String) async throws {
        if useLocal {
            _ = try await HoldingsStore.shared.addBuy(code: code, amount: amount, date: date)
            await reloadLocal()
            return
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        _ = try await post(base.appendingPathComponent("api/buy"),
                           ["code": code, "amount": amount, "date": date])
        await load(silent: true)
    }

    /// 记一笔卖出/赎回
    func addSell(code: String, amount: Double, date: String, shares: Double?) async throws {
        if useLocal {
            _ = try await HoldingsStore.shared.addSell(
                code: code, amount: amount, date: date, shares: shares)
            await reloadLocal()
            return
        }
        // 服务器模式还不支持卖出
        throw URLError(.unsupportedURL)
    }

    /// 删除某一笔买入
    func removeLot(code: String, date: String, amount: Double) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.removeLot(code: code, date: date, amount: amount)
            await reloadLocal()
            return
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        _ = try await post(base.appendingPathComponent("api/lot/remove"),
                           ["code": code, "date": date, "amount": amount])
        await load(silent: true)
    }

    /// 整只基金移除（连同买入记录）
    func removeFund(code: String) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.removeFund(code: code)
            await reloadLocal()
            return
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        _ = try await post(base.appendingPathComponent("api/fund/remove"), ["code": code])
        await load(silent: true)
    }

    /// 直接写死份额 / 成本（传 nil 表示改回按买入记录推算）
    func setManual(code: String, shares: Double?, cost: Double?) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.setManual(code: code, shares: shares, cost: cost)
            await reloadLocal()
            return
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        var body: [String: Any] = ["code": code]
        body["shares"] = shares.map { $0 as Any } ?? NSNull()
        body["cost"] = cost.map { $0 as Any } ?? NSNull()
        _ = try await post(base.appendingPathComponent("api/manual"), body)
        await load(silent: true)
    }

    /// 新增基金（不记买入）
    func addFund(code: String, platform: String) async throws {
        if useLocal {
            _ = try await HoldingsStore.shared.addFund(code: code, platform: platform)
            await reloadLocal()
            return
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        _ = try await post(base.appendingPathComponent("api/fund"),
                           ["code": code, "platform": platform])
        await load(silent: true)
    }

    /// 新增 / 修改定投计划的一个生效段
    func addPlan(code: String, start: String, amount: Double) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.addPlan(code: code, start: start, amount: amount)
            await reloadLocal()
            return
        }
        throw URLError(.unsupportedURL)
    }

    /// 标记某天的定投没买成
    func addSkip(code: String, date: String) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.addSkip(code: code, date: date)
            await reloadLocal()
            return
        }
        throw URLError(.unsupportedURL)
    }

    /// 取消某天的「没买成」标记
    func removeSkip(code: String, date: String) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.removeSkip(code: code, date: date)
            await reloadLocal()
            return
        }
        throw URLError(.unsupportedURL)
    }

    /// 删除某个定投生效段
    func removePlan(code: String, start: String) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.removePlan(code: code, start: start)
            await reloadLocal()
            return
        }
        throw URLError(.unsupportedURL)
    }

    /// 改跟踪指数（空字符串 = 不估算）
    func setTrack(code: String, track: String) async throws {
        if useLocal {
            _ = try HoldingsStore.shared.setTrack(code: code, track: track)
            await reloadLocal()
            return
        }
        // 服务器模式只能在 holdings.json 里手改
        throw URLError(.unsupportedURL)
    }

    /// 搜索基金（添加时用）
    func searchFunds(_ keyword: String) async throws -> [FundSearchResult] {
        if useLocal {
            let items = try await FundAPI.shared.searchFunds(keyword: keyword)
            return items.map {
                FundSearchResult(code: $0.code, name: $0.name, type: $0.type, company: $0.company)
            }
        }
        guard let base = baseURL else { throw URLError(.badURL) }
        var comps = URLComponents(url: base.appendingPathComponent("api/search"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [QueryItem(name: "q", value: keyword)]
        guard let url = comps?.url else { throw URLError(.badURL) }
        let r: FundSearchResponse = try await get(url)
        return r.results
    }

    /// 清空本机持仓（调试用）
    func resetLocalHoldings() async {
        localHoldings = nil
        try? FileManager.default.removeItem(at: HoldingsStore.shared.fileURL)
        await load()
    }
}

private typealias QueryItem = URLQueryItem
