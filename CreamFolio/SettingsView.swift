import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var privacy: PrivacyMode
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    @State private var draft = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false
    @FocusState private var addressFocused: Bool

    /// 收起键盘。点背景、滑动、键盘上的「完成」都会调它。
    private func hideKeyboard() {
        addressFocused = false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("外观", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { a in
                            Text(a.label).tag(a.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("外观")
                } footer: {
                    Text("跟随系统会随手机的深色模式自动切换；也可以在这里固定浅色或深色。")
                }

                Section {
                    Toggle(isOn: $privacy.hidden) {
                        HStack(spacing: 10) {
                            Image(privacy.hidden ? "EyeClosed" : "EyeOpen")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                            Text("隐藏账户金额")
                        }
                    }
                } header: {
                    Text("隐私")
                } footer: {
                    Text("打开后总资产、收益、流水金额、日历收益都会显示为 ••••；持仓页标题栏的小眼睛也能随时切换。")
                }

                Section {
                    Picker("数据源", selection: $state.useLocal) {
                        Text("本机").tag(true)
                        Text("服务器").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if state.useLocal {
                        LabeledContent("持仓文件", value: state.storageNote)
                    }
                } header: {
                    Text("数据源")
                } footer: {
                    Text(state.useLocal
                         ? "本机模式：App 直接调天天基金、腾讯、新浪的公开接口，自己算份额、净值预估、β 和收益。不需要电脑开着，也不需要联网除行情以外的东西。"
                         : "服务器模式：连你电脑上跑的 python3 server.py。下面填地址。")
                }

                if !state.useLocal {
                    Section {
                        TextField("http://192.168.1.23:8848", text: $draft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .font(.callout.monospaced())
                            .focused($addressFocused)
                            .submitLabel(.done)
                            .onSubmit(hideKeyboard)

                        Button {
                            hideKeyboard()
                            state.serverBase = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await state.load() }
                        } label: {
                            Text("保存并刷新").frame(maxWidth: .infinity)
                        }

                        Button {
                            hideKeyboard()
                            Task { await testConnection() }
                        } label: {
                            HStack {
                                Text("测试连接")
                                if testing { Spacer(); ProgressView() }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(testing || draft.trimmingCharacters(in: .whitespaces).isEmpty)

                        if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(testOK ? Color.green : Color.red)
                        }
                    } header: {
                        Text("服务器地址")
                    } footer: {
                        Text("你电脑上 python3 server.py 启动后打印的那个地址。\n模拟器里用 http://127.0.0.1:8848 就能连上；真机需要填电脑的局域网 IP（形如 http://192.168.x.x:8848），并保证手机和电脑在同一个 WiFi。")
                    }
                }

                Section("当前状态") {
                    LabeledContent("数据源", value: state.useLocal ? "本机" : "服务器")
                    LabeledContent("上次更新", value: state.lastUpdated.map {
                        $0.formatted(date: .omitted, time: .standard)
                    } ?? "--")
                    if let d = state.dashboard {
                        LabeledContent("基金数", value: "\(d.summary.fundCount) 只")
                        LabeledContent("记录笔数", value: "\(d.summary.lotsCount) 笔")
                        LabeledContent("总市值", value: privacy.money(d.summary.marketValue))
                    }
                    if let e = state.errorMessage {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Text("下一份净值预估 = 从最新净值日的指数收盘累计到现在（中间每天连乘，再叠加盘中期货）× 该基金的 β + 同期美元兑人民币变动。β 用最近 60 个交易日自动校准。这是本工具合成的估算，不是基金公司公布的官方估值。")
                    Text("QDII 基金投的是美股，A 股交易时段美股休市，净值天然滞后 1 个交易日：你白天看到的净值是昨夜美股的结果，今天的买入按今夜美股收盘后的净值确认。")
                } header: {
                    Text("关于预估")
                }

                Section {
                    Text("净值与历史走势：天天基金（东方财富）公开接口")
                    Text("指数 / 外盘期货 / 汇率：新浪财经")
                    Text("本工具只读取公开行情数据，不涉及任何基金账号、密码或持仓接口。")
                } header: {
                    Text("数据来源")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CloudBackdrop().ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 92)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            // 收键盘的三条路：下滑、键盘上的「完成」、键盘上的 return 键
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成", action: hideKeyboard)
                }
            }
        }
        .onAppear { draft = state.serverBase }
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        defer { testing = false }

        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s)?.appendingPathComponent("api/data") else {
            testOK = false
            testResult = "地址格式不对"
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                testOK = false
                testResult = "服务器返回异常状态码"
                return
            }
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            let d = try dec.decode(Dashboard.self, from: data)
            testOK = true
            testResult = "连接成功 · \(d.summary.fundCount) 只基金 · 总市值 \(privacy.money(d.summary.marketValue))"
        } catch {
            testOK = false
            testResult = "连接失败：\(error.localizedDescription)"
        }
    }
}
