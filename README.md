# CreamFolio · 原生 iOS App（SwiftUI）

一个自用的基金持仓看板，原生版本。四个页签：**持仓 / 日历 / 市场 / 设置**；流水从持仓页右上角的流水按钮进入，点基金进详情页，详情页再分 **概览 / 走势 / 明细** 三个标签。

数据直接来自天天基金的公开接口，份额、市值、XIRR、账户曲线全部在 `PortfolioEngine` 里本机算完，**不需要任何后端**。另外还留了一个可选的 Python 后端模式（`server.py`，不包含在本仓库），作为上游接口变动时的备用通道。

> **这个仓库里没有任何人的持仓数据。** `holdings-seed.json` 是空模板，`holdings.json` 和 `screenshots/` 都被 `.gitignore` 排除。怎么换成你自己的持仓，见下面「数据与隐私」一节。
>
> 包名仍保留 `com.dafan.fundboard`：这样从旧版本覆盖升级时，手机里的 `Documents/holdings.json`
> 不会被当成新 App 丢掉。改 bundle id 之前记得先导出/迁移持仓文件。

---

## 数据与隐私

这个仓库是**纯代码**，不含任何人的持仓：

| 可能泄露数据的东西 | 怎么处理 |
|---|---|
| `CreamFolio/holdings-seed.json` | 已换成空的 `"funds": []` 模板，首装就是一个空账户 |
| `Documents/holdings.json`（App 里真实的持仓） | 只存在手机本地，`.gitignore` 排除 |
| `screenshots/`（截图里有真实金额） | 未入库 |
| `holdings.backup-*.json` / `sms_export.csv` | `.gitignore` 排除 |

数据流向也很简单：App 直接请求天天基金的公开接口（净值、历史净值、指数行情、汇率、基金搜索），
本机算完就完事，**不经过任何自建服务器**，也没有账号体系。

### 加上你自己的持仓

克隆下来跑起来，账户是空的。三种加法，按省事程度排：

**1. 在 App 里加（推荐，什么都不用改）**

| 位置 | 做法 |
|---|---|
| 持仓页右上角 `+` | 填 6 位基金代码 + 金额（+ 日期），名称自动查出来 |
| 基金详情页 `⋯` | 再买一笔 / 管理买入记录 / 删除这只基金 |
| 管理买入记录页 | 左滑删掉某一笔，右上角 `+` 继续加 |

懒得逐笔记，就切到「直接填份额」只维护当前持有份额；或者用「定投计划」，让 App 按交易日
自动生成买入记录（金额、生效日期都可分段改）。

**2. 改 `CreamFolio/holdings-seed.json`（想一次性导入）**

```json
{
  "refresh_seconds": 60,
  "market_refresh_seconds": 30,
  "funds": [
    {
      "code": "012345",
      "name": "某只纳斯达克100ETF联接(QDII)A",
      "platform": "支付宝",
      "track": "NDX",
      "ratio": 0.95,
      "lots": [["2026-01-05", 100.0], ["2026-02-05", 100.0, 1.6234]]
    }
  ]
}
```

- `track`：`NDX` = 纳斯达克100，`SPX` = 标普500，留空就不做盘中预估
- `ratio`：股票仓位系数，QDII 指数联接一般 0.93~0.97
- `lots`：`[日期, 金额]` 或 `[日期, 金额, 确认净值]`；只写金额时按当天净值自动折算份额
- 这个文件是**首装种子**，只在 App 第一次启动、手机里还没有 `holdings.json` 时读一次。
  装好之后改它不会生效 —— 要改就改 App 里的持仓，或者删掉 App 重装。

**3. 接可选后端**（电脑常开，网页版和 App 共用同一份持仓）

`server.py` 在另一个项目 `fund-dashboard/` 里，本仓库没带。用法见那个项目的 README：
App 的「设置 → 数据源 → 服务器」填电脑的局域网地址（形如 `http://192.168.1.23:8848`）即可。

> **别把自己的 `holdings.json` 提交上去。** fork 之后想保留自己的持仓、又想跟着上游更新的话，
> 把持仓留在手机里，或者放到 `holdings-seed.local.json`（已在 `.gitignore` 里）。
> `git status` 里看到 `holdings.json` 就该警觉了。

---

## 一、工程结构

```
CreamFolio/
├── CreamFolio.xcodeproj/             Xcode 工程
│   └── xcshareddata/xcschemes/      已配好共享 scheme，命令行也能直接 build
├── Config/Info.plist                只放 ATS 例外，其余键由 Xcode 生成
└── CreamFolio/                       源码目录（Xcode 16+ 同步组，加文件不用手动改工程）
    ├── CreamFolioApp.swift           App 入口 + TabView
    ├── Models.swift                 Codable 数据模型（和 server.py 的 JSON 同构）
    ├── Store.swift                  AppState：本机 / 服务器双模式、60 秒自动刷新
    ├── FundAPI.swift                ★ 直接抓上游：净值、历史、指数日线、行情(GBK)、汇率、搜索
    ├── PortfolioEngine.swift        ★ 计算：份额/市值、β 回归、净值滞后连乘预估、XIRR、账户曲线
    ├── HoldingsStore.swift          ★ 本地持仓读写（Documents/holdings.json）
    ├── holdings-seed.json           ★ 首装模板（空 funds 数组，不含任何真实持仓）
    ├── Components.swift             卡片、数字格式化、行情行、错误视图
    ├── EquityChart.swift            收益走势图（市值 vs 投入 + XIRR）
    ├── PortfolioView.swift          持仓页
    ├── AddEntryView.swift           添加持仓（输入代码 / 选择基金 / 直接填份额）
    ├── LotManagerView.swift         买入记录管理（左滑删除）
    ├── FlowView.swift               流水页
    ├── MarketView.swift             市场页
    ├── FundDetailView.swift         基金详情页（概览 / 走势 / 明细 + 底部悬浮卡 + Swift Charts）
    ├── SettingsView.swift           数据源切换 + 服务器地址配置
    └── Assets.xcassets/             App 图标（1024×1024，满幅不透明）+ 强调色
```

## 二、怎么跑起来

### 不需要后端了

App 有两种数据源，在「设置 → 数据源」切换：

| | 本机（默认） | 服务器 |
|---|---|---|
| 数据从哪来 | App 自己调上游公开接口 | 电脑上的 `python3 server.py` |
| 需要电脑开着 | **不需要** | 需要 |
| 持仓存哪 | 手机 `Documents/holdings.json` | 电脑的 `fund-dashboard/holdings.json` |

**本机模式**下直接 Xcode 跑起来就能看，手机上也不需要连同一个 WiFi。
服务器模式保留着作为备用通道 —— 万一上游接口变动、本机引擎出问题，切过去还能用。
它依赖另一个项目里的 `fund-dashboard/server.py`，本仓库不包含；只用本机模式的话完全不用管。

### 真机安装

真机第一次运行需要在「设置 → 通用 → VPN与设备管理」里信任开发者证书。

### 在 Xcode 里

```bash
open CreamFolio.xcodeproj
```

1. 左上角选模拟器（比如 **iPhone 17 Pro**）
2. `Cmd + R`

模拟器里网络和你的 Mac 是共享的，所以 **默认地址 `http://127.0.0.1:8848` 直接就能连上**，不用改配置（仅服务器模式需要）。

### 3. 装到真机上

1. Xcode → Settings → Accounts → 加上你的 Apple ID
2. 选中 CreamFolio target → Signing & Capabilities → Team 选你的个人团队
3. 把 Bundle Identifier 改成唯一的（比如 `com.你的名字.fundboard`，免费账号不能用别人用过的）
4. iPhone 用数据线连上 Mac，顶部设备选你的 iPhone，`Cmd + R`
5. iPhone 上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书
6. **App 里的「设置」页把地址改成电脑的局域网 IP**，例如 `http://192.168.1.23:8848`（模拟器能连 127.0.0.1，真机不行）

> 免费 Apple ID 签的 App **7 天后会打不开**，重新 `Cmd + R` 一次即可续期。

### 4. 在 App 里添加持仓

不用碰 `holdings.json`，也不用开终端。三个入口：

| 位置 | 能做什么 |
|---|---|
| **持仓页右上角 `+`** | 记一笔买入，或直接填份额（见下） |
| **基金详情页右上角 `⋯`** | 再买一笔 / 管理买入记录 / 删除这只基金 |
| **管理买入记录页** | 左滑删除某一笔，右上角 `+` 继续加 |

`+` 打开的「添加持仓」有三种模式：

- **输入代码**（默认）—— 只填 **6 位基金代码 + 金额**（+ 日期）。填完代码会自动查出基金名称让你确认，
  是买完立刻记一笔最快的路径。代码不存在会直接报错，不会建出垃圾基金。
- **选择基金** —— 从已持有的基金里挑（或搜一只新的）→ 日期 → 金额（有 ¥5 / ¥10 / ¥20 / ¥50 快捷键）。
- **直接填份额** —— 懒得记每一笔，只维护「我持有多少份」。填了之后看板直接用这个数，
  不再按买入记录推算。

三种模式下面都有同一个「**在哪儿买的**」区块：

- 一排快选胶囊：`支付宝` / `天天基金` + 你已经用过的平台（自动追加）
- 一个输入框，可以自己填（比如「招商银行」「券商」）
- 不填就退回基金公司的名字，保持以前的行为

> **同一只基金只归一个平台。** 数据模型里平台是基金级别的属性，不是每笔买入级别的。
> 如果同一只基金在支付宝和基金公司 App 都买过，目前只能选一个平台记，或者拆成两条不同代码（A/C 份额）分别记。
> 真要做「一只基金跨多个平台」得把平台下沉到每笔买入，那是另一个量级改动。

份额按「金额 ÷ 当日净值」自动折算；如果要精确到分（比如支付宝有费率折扣），
用「直接填份额」把**确认份额**填进去，成本就是准的。

搜索框里可以直接搜一只**你还没持有**的基金（比如输入「纳斯达克 100」），
保存时会自动加入持仓，跟踪指数（NDX / SPX）也会自动识别。

> **注意 Bundle ID**：这个工程里 `PRODUCT_BUNDLE_IDENTIFIER = com.dafan.fundboard`。
> 如果你在别处又装过一个旧版本（比如 `com.local.fundboard`），
> `xcrun simctl launch com.local.fundboard` 启动的是**旧的那个**，
> 看起来就像「代码改了没生效」。用 `xcrun simctl listapps booted | grep -i fundboard`
> 确认一下有几个、分别是什么 ID。

## 三、和网页版的区别

| | 网页版（PWA） | 原生版 |
|---|---|---|
| 安装 | Safari 添加到主屏幕 | Xcode 自签 |
| 有效期 | 永久 | 免费账号 7 天，需重签 |
| 图表 | 手写 SVG | Swift Charts（原生交互、可缩放） |
| 刷新 | 前台 60 秒 | 前台 60 秒（iOS 后台不允许常驻刷新的 App） |
| 数据源 | 同一套 `/api/data`、`/api/fund/<code>` | 同左 |

功能上两者等价。原生版的优势是图表和手势更顺，以及有真正的 `TabView` / `NavigationStack` 体验。

## 四、几个实现上的注意点

- **ATS**：iOS 默认禁止明文 HTTP。`Config/Info.plist` 里开了 `NSAllowsLocalNetworking`，只对 localhost 和私有网段（192.168/10/172.16-31）放行，不是全局关闭 ATS。
- **局域网权限**：真机首次连电脑时 iOS 会弹「是否允许访问本地网络」，要允许。`NSLocalNetworkUsageDescription` 已配好文案。
- **键名映射**：`JSONDecoder` 用 `.convertFromSnakeCase`，`market_value` → `marketValue`、`profit_pct` → `profitPct`，和 Python 端字段一一对应。
- **Swift 版本**：工程固定 `SWIFT_VERSION = 5.0`（Swift 5 语言模式），避免 Swift 6 严格并发检查带来的额外改动。
- **部署目标**：iOS 17.0（Swift Charts 需要 16+，用 17 是为了 `Grid`、`LabeledContent` 等 API）。
- **键盘收起**：设置页和添加页都配了三条路 —— 下滑列表（`.scrollDismissesKeyboard`）、键盘上方常驻的「完成」按钮（`ToolbarItemGroup(placement: .keyboard)`）、return 键（`.onSubmit`）。不要用 `simultaneousGesture(TapGesture())` 去实现「点空白收键盘」，它会连点在输入框上的那一下也一起吞掉，键盘刚弹出就被收回去。
- **`@FocusState` 而不是 `UIApplication.shared.sendAction`**：前者是 SwiftUI 原生做法，不会在 iPad / 多窗口场景下把别的输入框一起收掉。

### 定投计划

多只基金每天买、金额会变的场景，逐笔手记一天 9 笔、一年 2500 笔，不现实。
所以加了「定投计划」：设置一次，之后自动生成买入记录。

**数据结构**：计划是「按生效日期分段」的

```json
"plans": [
  { "start": "2026-09-01", "amount": 10 },   // 9-01 起每交易日 10 元
  { "start": "2026-10-20", "amount": 20 }    // 10-20 起改成 20 元
]
```

改金额 = 加一段新的，**历史记录不受影响**。

**停止（金额填 0）**：基金暂停申购、外汇额度用完、公司限购都会让定投失败。
再存一段「金额 = 0」就表示从那天起不再生成：

```
XXXXXX   2026-10-08 起  ¥10
XXXXXX   2026-10-14 起  ¥0     ← 10-14 起暂停申购，这里停止
```

详情页的「定投计划」会显示「已停止」。实测这种配置下**不会生成任何多余记录**。

**单日失败不用改计划**：某天余额不足/限额/系统故障，计划却已经生成了记录时，
去「管理买入记录」把那天那条**左滑删掉** —— 它会记进 `skips`（例外日期），以后不再生成。
想撤销就在「定投计划 → 例外日期」里左滑恢复。

> 三种情况分清楚：
>
> | 情况 | 做法 | 操作量 |
> |---|---|---|
> | **单日没买成** | 左滑删那条记录（进例外日期） | 1 次滑动 |
> | **连续几天失败** | 加「停止段」+「恢复段」，**不用逐天删** | 2 段 |
> | **永久停止**（暂停申购、额度用完） | 只加「停止段」 | 1 段 |
>
> 连续失败的例子：
> ```
> 10-08 起 ¥10     ← 正常
> 10-12 起 ¥0      ← 12、13 号申购失败
> 10-14 起 ¥10     ← 14 号恢复
> ```
> 实测：10-12、10-13 被跳过，10-14 起恢复生成，其它交易日照常。

**展开规则**（`expandPlan`）：

| 规则 | 为什么 |
|---|---|
| 只在该基金**有净值的交易日**生成 | 净值序列本身就是交易日历，周末/节假日/停牌自动跳过 |
| 金额取「生效日期不晚于当天」的**最后一段** | 分段改额 |
| **跳过已经手动记过的日期** | 否则从手记切到定投会算两遍 |
| 生成的 lot 带第 5 位标记 `"plan"` | 界面上标「定投」，且**不允许直接删**（它不在 holdings.json 里） |

展开发生在**引擎里**（`dashboard` / `fundDetail` 取到历史净值之后），
所以 `holdings.json` 里始终是干净的原始计划，不会越跑越肿。

实测：给一只已有 10-09 / 10-12 / 10-13 三笔手记的基金加「10-08 起每天 ¥10」→
只补生成了 10-08、10-14、10-15 三天，记录笔数 3 → **6**，投入和份额同步增加，不会重复计算。

### 卖出 / 赎回

用「**负数 lot**」表示：`[日期, -金额, 净值, -份额]`。

这么记的好处是**引擎一行都不用改** —— 份额、成本、XIRR、账户曲线本来就是求和：

| 指标 | 卖出后的效果 |
|---|---|
| 持有份额 | 自动减少 |
| 累计投入 | 自动减少（成本按净投入算，不是税务口径） |
| XIRR | 卖出那笔变成**正现金流**，年化自动重算 |
| 账户曲线 | 「投入」线会往下折，能看出赎回过 |

添加页顶部有 `买入 / 卖出` 切换。卖出时：
- 填**赎回金额**（必填）+ **赎回份额**（选填）
- 填了份额会校验「不能卖超」，留空则按「金额 ÷ 当天净值」折算
- 卖出模式下「直接填份额」被禁用（那是整体覆盖，语义冲突）

### 断网时不能装作没事

引擎对网络错误是**宽容**的（`quotesCached` / `historyCached` 失败会返回空值继续算），
所以断网冷启动会得到一个「所有基金市值都是 `--`」的空账户 —— 看起来像持仓丢了。

现在 `AppState.loadLocal()` 会检测这种情况：**有持仓却一个市值都算不出来**，就明确提示
「拿不到行情数据，检查一下网络。持仓没丢，都存在手机本地」，持仓页顶部还会挂一条橙色横幅。

### 冷启动并发拉历史

十几只基金要各拉一次 `pingzhongdata`。串行要 8~10 秒，现在用 `withTaskGroup` 并发，
**同时最多 4 个**（再多东财会限流），实测冷启动到出数据约 6 秒。

### 调试钩子

`FB_TAB` / `FB_FUND` / `FB_DETAILTAB` / `FB_DETAILSCROLL` / `FB_ADD` / `FB_FAN` / `FB_FLOW` 统一走 `DebugHooks.env()`，
**Release 构建里恒返回 nil** —— 不会把调试入口带到正式包里。

### 收益口径：为什么用 XIRR

你是每天小额定投的。**简单收益率在定投场景下会误导人**：

- 第 1 天投 10 块，第 8 天投 1000，算「累计收益 ÷ 累计投入」等于把最后一天的权重和第一天的权重当成一样
- 真正该问的是「**我这笔钱实际年化多少**」—— 这就是 XIRR（资金加权内部收益率）

后端 `xirr()` 用二分法解 NPV = 0：每笔买入记为负现金流，当前市值记为正现金流。

**但年化有个陷阱**：你现在只投了 9 天，亏 1.84% 年化出来是 −73%，纯属数学噪音。所以接口同时返回 `xirr_days`，前端逻辑是：

| 持有天数 | 界面显示 |
|---|---|
| < 30 天 | 「只投了 N 天，年化会严重失真，别当真」 |
| ≥ 30 天 | 「年化 −X% · N 天」 |

单只基金的详情页同理：不满 30 天就显示「持有满 30 天才算得准」。

### 收益日历

按天看赚亏，数据同样**不用后端额外给**，直接从 `curve` 反推：

```
当天盈亏 = 当天市值 − 昨天市值 − (当天累计投入 − 昨天累计投入)
```

**减去投入增量这一步是关键**：否则「买入那天」市值凭空涨了一大笔，会被误算成赚了。

验证：把所有交易日的盈亏加起来，正好等于「市值 − 累计投入」，和「持有收益」完全一致。

界面：**日 / 周 / 月 / 年 四档粒度** + `¥ / %` 切换，红涨绿跌。

| 粒度 | 布局 | 翻页 |
|---|---|---|
| **日** | 7 列月历（周日打头），每格 = 当天盈亏；今天单独描边 | 按月 |
| **周** | 列表，每行 = 一个月内的一周（如 `10/11 – 10/17`）+ 合计 + 交易日数 | 按月 |
| **月** | 一年 12 格（4×3），每格 = 当月合计 | 按年 |
| **年** | 列表，每年一行 | 按年 |

右上角有「**今天**」按钮：翻到过去之后点一下回到当前周期。
它**始终占位、只改强调色**（当前周期时变灰不可点），避免按钮出现/消失把标题挤得左右跳。

不能翻到未来。没有净值的日子（周末、节假日、还没更新）显示「—」，且**不计入交易日数**。
> 注意：建仓之前的那些天也不显示 0.00 而是「—」—— 曲线第一个点是零点，不是真的交易日。

三个粒度的合计必须能对上，实测：
- 周合计 = 该月内各周之和
- 月合计 = 该年 12 个月之和
- 年合计 = 日粒度所有交易日盈亏之和
- 全都等于「持有收益」✅

> 一个小坑：曲线第一个点是「建仓前」的零点（市值 0、成本 0），直接数天数会多算一天。
> 现在数交易日时会检查 `cost > 0`，只算真正建过仓的日子。

### 收益曲线：不用每日快照

画账户历史曲线通常要每天定时记一次总资产。这里不需要 —— **用净值历史反推**：

```
某一天的账户市值 = Σ(那天持有的份额 × 那天的净值)
```

份额由买入记录决定（买入日之后固定），净值来自天天基金的历史序列，所以任意历史日期都能算，补历史也能画。

后端 `build_curve()` 的做法：
1. 每只基金建 `{日期: 净值}` 和排序后的日期表
2. 每笔买入折算成份额（有确认份额就用确认份额，否则 金额 ÷ 买入日净值）
3. 遍历所有净值日期，用三个指针（买入事件 / 净值 / 累计值）单调推进，避免每格重算
4. 掐掉开头「还没开始买」的全 0 段

实测十几只基金 × 两百多个交易日 < 0.2 秒。


## 五、界面风格：系统原生 + 「安静的画布」

两层视觉：**分组列表**负责信息，**卡片**负责数值。

### 一条设计原则

> **颜色只给数据，不拿来装饰界面。** —— 参考 [Copilot Money](https://blakecrosley.com/guides/design/copilot-money)（Apple Design Award 提名）的做法

早期版本给主卡做了大面积斜向渐变、给每家公司卡片配了不同渐变，结果颜色全花在「外壳」上，反而让数字失去重量，整体发灰发杂。现在改成：**卡面是一层很薄的毛玻璃，只让背景的奶油/淡紫透上来一点；彩色元素仍然只有涨跌数字和一个 6pt 小圆点。**

### 卡片

| 特征 | 实现 |
|---|---|
| 卡面 | `GlassSurface`：`.thinMaterial` / `.ultraThinMaterial` 打底，再覆一层白色半透明渐变 + 顶部高光边。背景的蜜桃/淡紫会透上来，**不是纯白实心块** |
| 文字 | 全部用语义色（`.primary` / `.secondary` / `.tertiary`），保证压在毛玻璃上仍然清楚 |
| 卡内结构 | 小标签（`CardCaption`）→ 主数字（`CardHeroValue`，42pt、字距 −1.1）→ 分隔线 → 底部并列的次要字段 |
| 浮在画布上 | 卡片行用 `.listRowBackground(Color.clear)` + 隐藏分隔线；卡片用 18pt 半径的轻阴影浮起来 |
| 背景 | `CloudBackdrop`：右上蜜桃、中下淡紫、左下极淡青的雾面渐变。卡片透上来的颜色就是它 |
| 颜色 | 只有涨跌用红/绿（`Fmt.tone`），加上「估算总市值」旁边一个 6pt 的 `ToneDot` |

### 深色模式

- `Theme` 的颜色全部是动态色：`canvas` / `card` / `ink` / `tealSoft` / `coralSoft` 各有一套。
  深色下 `Theme.ink` 变浅，按钮前景反过来用 `Theme.canvas`，避免「白底白字」。
- `GlassSurface` 深色下换成低白覆膜 + 深色 material，白色高光边降到 0.24；
  `CloudBackdrop` 深色下减弱蜜桃、保留紫光，不再铺底部白。
- 去掉了 `.preferredColorScheme(.light)`，状态栏、导航栏、Form、Swift Charts 都跟随系统。
- 设置 → 外观可以选「跟随系统 / 浅色 / 深色」，存 `@AppStorage("appAppearance")`，根部用 `preferredColorScheme` 应用。
- 深浅色截图未入库（里面有真实金额），在 App 里切一下就能看到。

### 隐私模式（小眼睛）

- 持仓页标题栏第一个按钮就是小眼睛：**显示时是睁眼、隐藏时是闭眼**（Tabler Icons 的
  [eye](https://tabler.io/icons/icon/eye) / [eye-closed](https://tabler.io/icons/icon/eye-closed)，MIT），
  点一下切换账户金额显示；设置 → 隐私里也有「隐藏账户金额」开关，开关图标也跟着睁眼/闭眼，
  两边共用 `PrivacyMode` 和 `UserDefaults("hideAccountAmounts")`，下次启动保持。
- 隐藏时统一显示 `••••`，并把涨跌颜色收成中性灰，避免从颜色看出方向：
  - 持仓：估算总市值、较最新净值、按最新净值、持有收益、成本、类型卡市值/收益率/占比；
  - 收益走势：年化、最大回撤、波动率、Y 轴刻度；
  - 流水：累计投入、平均每笔、本月投入、每天合计、每笔金额；
  - 日历：日/月/周/年的收益金额和色块；
  - 基金详情：持仓市值、累计收益、份额、平均成本、XIRR、定投金额、买卖明细金额；
  - 设置当前状态里的总市值；
  - 资产类型详情页的汇总、基金卡市值和占比。
- **不隐藏**的是公开行情和账户结构：基金名称/代码、最新净值、基金当日涨跌、交易笔数、基金只数，
  以及收益走势的曲线形状（只把数字刻度藏起来）。编辑/添加弹窗仍然显示输入金额，因为要填。
- 实现是 `PrivacyMode: ObservableObject` + `PrivacyText`，以及 `CardHeroValue` / `CardValue` /
  `TrendBadge` / `ToneDot` 内部读取环境对象；切换时只改显示，不动数据、不重建页面。
- 两个眼睛图标是 24×24 SVG（模板渲染，保持矢量），放在 `EyeOpen.imageset` / `EyeClosed.imageset`；
  Tabler 的 MIT 许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 截图未入库，理由同上。

### 资产类型卡片云

`KindFundsView` 里「基金列表上方」的那片卡片云，是参考图里浮动卡片效果的落点：

- 每张卡是 `DraggableFundCard`：`GlassSurface` + 同色渐变 + 彩色 `.shadow`（紫 / 青 / 珊瑚按 index 轮换），
  卡片之间有 ±15° 旋转、近大远小和错位，故意排得不规则。
- 外层横向 `ScrollView` 加了 `.scrollClipDisabled()`，光晕可以溢出云层边界，不会被切出一条直线。
- 云层后面垫一层很淡的蜜桃/淡紫 `RadialGradient`（用 `background`，不参与布局）。
- 持仓页的 `KindCard` 走势图放大到 120×44，线宽 2.4、端点 7pt，面积渐变保留。
- ⚠️ 踩过的坑：一开始用 `RoundedRectangle().fill(color).blur(radius: 26)` 做光晕，
  它参与了 ZStack 的布局，把整片云挤歪、裁出硬边；改用 `.shadow(color:...)`，只影响绘制，不影响布局。

卡片分工：
- **总资产主卡** —— 估算总市值 / 较最新净值 / 按最新净值 / 持有收益。
- **每个平台一张小卡** —— 只有一个**用平台色轻染的首字母圆标**（南 / 摩 / 广…），卡面本身是中性色。
  默认**扇形叠放**（横向重叠 26pt），点一下放大并筛选下方基金列表，再点取消；右上角「展开 / 叠放」可切平铺。
- **流水页** 累计投入卡、**基金详情页** 单只基金卡，同一套组件。
- **流水 / 行情的单行** 改成 `GlassRow` 玻璃卡，不再用系统白底行；设置 Form 也加了 `CloudBackdrop` 背景。

### 导航与排序

- **底部四个页签**：持仓 / 日历 / 市场 / 设置。底部用自定义 `FloatingTabBar`
  （选中项展开成深色胶囊 + 文字，未选中是圆形图标），原生 tab bar 隐藏；
  流水页保留底部导航；详情 / 资产类型页隐藏主条，把底部让给内容。
- **流水是标题栏里的独立按钮**（`receipt` 账单图标，不是 list/菜单图标），排序在旁边单独的 `arrow.up.and.down.text.horizontal` 菜单里，`+` 仍然是一键添加；push 进同一个 `NavigationStack`，
  所以 `FlowView` 里不再自带 `NavigationStack`（否则会出现两层导航栏）。
- **所有跳转统一走 `path`**：定义了 `enum PortfolioRoute { case fund(String); case flow }`。
  ⚠️ 踩过的坑：一开始流水用 `navigationDestination(isPresented:)`，和 `NavigationStack(path:)` 混用，
  表现是「第一次能打开，返回后再点没反应」—— 因为栈是 path 驱动的，`isPresented` 那条路不在 path 里，
  pop 之后状态再也复位不了。全部纳进 path 就好了。
- **左侧大标题 + 真吸顶**：大标题 34pt「持仓」和流水 / 排序 / ＋ 三个 46pt 入口在同一行，
  搜索栏在下面；整块放在 `ScrollView` 内容顶部，随内容一起滚走。
  滚动超过约 150pt 后，一个**固定覆盖层**淡入：22pt 小标题 + 同一行按钮 + 搜索 + 毛玻璃。
  覆盖层是 `ZStack` 里压在 ScrollView 上，不参与滚动布局，只切换 `opacity` / `allowsHitTesting`，
  不改 `safeAreaInset`、不改滚动几何；所以内容区真的变大，也不会再触发布局循环。
  状态栏区域用 `Theme.canvas` 的透明渐变压暗，不再铺独立材质条，深色下不会出现一块灰色；
  吸顶层的材质也用 `Theme.canvas` 轻染，和页面背景连成一片。
  系统 `.searchable` 在 iOS 27 会把大标题挤成居中 inline，所以不用它；push 出去的流水 / 类型 / 详情页
  各自把导航栏设回 `.visible`，返回键不受影响。
  ⚠️ 之前让 `safeAreaInset` 高度随滚动变化、再配合 `onScrollGeometryChange`，触发了 AttributeGraph
  更新循环，系统 watchdog 报 `0x8BADF00D` 闪退；现在滚动只控制覆盖层透明度，不动任何布局。
- **底部悬浮条可访问性**：每个 tab 有 `accessibilityLabel` / `isSelected`，点击带轻触觉反馈。

- **「我的基金」可按收益率排序**：标题栏 ↕ 菜单里的「排序」，选项是
  `市值`（默认）/ `收益率 高→低` / `收益率 低→高` / `名称`。
  选择记在 `@AppStorage("fundSort")`，下次打开还是这个顺序；没有收益率数据的基金会排到最后。

筛选时列表用 `.animation(.snappy, value: platformFilter)` 带动画增删行，不会瞬间跳变。

### 详情页标题

导航栏标题用 `ToolbarItem(placement: .principal)` 自定义成两行：

```
012345
某某纳斯达克100ETF发起式联接(QDII)A
```

两行都设了 `.lineLimit(1)` + `.minimumScaleFactor(0.55)`，**名称太长时自动缩小字号而不是截断成省略号**。
实测最长的「招商纳斯达克100ETF发起式联接(QDII)A」和「广发纳斯达克100ETF联接人民币(QDII)A」
都能完整显示，字号只缩了一点点。

### 详情页分标签

原来详情页是一根长列表：持仓卡 → 9 行数据 → 走势图 → 阶段涨幅 → 买入明细。一屏根本看不完，
而且「我的持仓」「基金走势」「买卖记录」三件事混在一起。现在按参考图拆成三个标签 + 一张底部悬浮卡：

| 标签 | 回答的问题 | 里面有什么 |
|---|---|---|
| **概览** | 我这笔持仓怎么样 | 累计投入、持有份额、平均成本、最新净值、资金加权年化、定投计划、申购状态、首次/最近买入 |
| **走势** | 这只基金本身表现如何 | 区间选择器 + Swift Charts 走势图（成本虚线）、区间涨跌 / 最高 / 最低 / 现价相对成本、阶段涨幅 |
| **明细** | 每一笔钱是什么时候、按什么净值买的 | 逐笔买入记录、确认净值说明（没有记录时直接给「再买一笔」） |

页面结构从上到下是：

```
持仓卡（跟着滚，会滚出屏幕）
标签栏（吸顶）
当前标签的内容卡片们
最近净值 + 再买一笔 / 定投计划（底部悬浮卡，不随内容滚动）
```

实现上：

- 顶部用 `LazyVStack(pinnedViews: [.sectionHeaders])`，标签栏放在 `Section` 的 header 里，
  所以它一开始在持仓卡下面，滚到导航栏下方就自动吸住。
- 吸顶后内容会从标签下面穿过去，所以用 `PreferenceKey` 读标签栏的 `minY`，
  一旦小于 0 就给标签栏垫一层 `.ultraThinMaterial` + 底部分隔线。没吸顶时不垫，保持参考图那种干净的渐变。
- 原来的 `List` 换成了 `ScrollView` + `DetailCard`（毛玻璃、22pt 圆角、高光边、轻阴影），
  这样顶部卡片才能和标签一起进入同一个滚动容器。行高、分隔线、区段标题都自己排，
  标题用 18pt 深色（参考图里的「Company Details / Stock Performance」也是深色标题）。
- **底部悬浮卡**用 `overlay(alignment: .bottom)` 挂在页面上，显示最新净值、当日涨跌、
  净值日期 · 代码，两个按钮是「再买一笔」和「定投计划」，右上角 ⓘ 弹出净值/估算依据说明。
  卡面是 `.ultraThinMaterial` + 白色覆膜，压在走势图上会透出一点红/紫，不是一块死白。
  它盖在内容上，所以滚动内容底部留了 210pt，最后一行仍能滚到卡片上方。
- 这一页用 `.toolbar(.hidden, for: .tabBar)` 把全局底部导航藏掉，把底部让给悬浮卡（参考图也是这个结构），
  返回持仓页后导航条自动回来。
- 切标签时用 `ScrollViewReader`：吸顶状态就滚到标签栏，没吸顶就回到顶部；
  不再用 `List.id(tab)` 整页重建。
- ⚠️ 踩过的坑：`Chart` 放进滚动容器后，绘图区会画到自己的 `frame` 外面，盖住下面的
  「N 个交易日 / 平均成本」一行。加 `.clipped()` 裁掉，不要试图用 padding 绕过去。
- 调试：`FB_DETAILTAB=trend|lots` 直接打开某一页；`FB_DETAILSCROLL=1` 启动后自动滚到标签栏（看吸顶），
  用来看吸顶毛玻璃和底部卡片的叠放效果（见文末启动参数）。

### 转场

基金行 → 详情页用 iOS 18 的 **zoom transition**（`matchedTransitionSource` + `.navigationTransition(.zoom)`），卡片从列表位置放大铺开，和钱包点卡的手感一致。iOS 17 上自动退化为普通 push（`cardSource` / `cardDestination` 做了可用性判断）。

### 载入动画

`RisingChartLoader`：红色折线从左侧一帧一帧往右上走。

- **逐帧推进**而不是平滑描边 —— 每帧 80ms 跳一格，10 帧画满，停 360ms 后直接跳回第 0 帧重来。读起来像 flipbook（序列帧），不是进度条。
- **纯矢量**（`Path` + `.trim` + 遮罩），没有塞一堆 PNG 序列帧 —— 深浅色都清晰，包里不增加任何图片。
- 折线下方的面积随进度从左往右刷出来，线本身带一点红色辉光。
- 超过 6 秒还在转，会补一句「第一次打开要抓十几只基金的历史净值，会慢一些」—— 冷启动确实要十几秒，什么都不说会让人以为卡死。
- 用 `minHeight: 420` 把它撑到视觉中心，不然贴在导航栏下面很难看。

> 踩过的坑：状态更新必须 `@MainActor`。`View` 的普通方法不是 MainActor 隔离的，在 `.task` 里直接改 `@State` 会出现「动画不动、折线完全不显示」——而且不报任何错。

### 分组列表

| 方面 | 做法 |
|---|---|
| 列表 | `List` + `.insetGrouped`，和「设置」「健康」同款 |
| 颜色 | 全部走系统语义色（`.primary` / `.secondary` / `.tertiary`），卡片和列表不各搞一套 |
| 深浅色 | 完全跟随系统：深色下深灰卡浮在近黑底上，浅色下白卡浮在浅灰底上 |
| 字体 | 全部跟随系统动态字体：卡片里的固定字号走 `scaledFont()`（内部 `@ScaledMetric`），主数字按 `.largeTitle` 档缩放 |
| 数字 | 金额统一 `.monospacedDigit()` |
| 控件 | 原生 `NavigationStack`、`LabeledContent`、`ContentUnavailableView`、`Picker(.segmented)`、SF Symbols |
| 强调色 | AccentColor = 系统蓝 `#007AFF` |
| 涨跌配色 | **红涨绿跌**（国内习惯），统一走 `Fmt.tone()` |
| 走势图 | 列表行不放迷你图，只在详情页用 Swift Charts 画完整走势 |

> 没照搬「钱包」的**垂直卡片堆叠**：那样会互相遮挡，而用的人需要一眼看到所有基金。改成「主卡 + 平台卡横向扇形排」，保留卡片语言但不牺牲可读性。

### App 图标

奶油/淡紫渐变底 + 深色毛玻璃圆角卡，卡里是**三段环形（薄荷 / 蜜桃 / 珊瑚）+ 中心 ¥**。
环形代表基金配置，¥ 代表资金，颜色和 App 的卡片、徽章、涨跌语义同一套。

参考了 [FundMF 的 fintech 图标](https://dribbble.com/shots/27224603-FundMF-Fintech-App-Branding-Mobile-Icon-Design)
和 [3D glass finance 图标](https://promptbase.firebaseapp.com/app/3d-glass-finance-object-icon) 的玻璃质感，最终用脚本自己画，
避免直接用别人的版权素材。

图标用脚本生成（1024×1024，4 倍超采样抗锯齿，不带圆角，遮罩交给 iOS）：

- 背景：奶油 `#FFF9F1 → #E7E2FF` 对角渐变 + 蜜桃/淡紫/薄荷柔光
- 卡片：深墨绿 `#0A1811 → #162C21` 圆角矩形 + 白色高光边 + 左上玻璃反光
- 环形：薄荷 `#2BD3A8` / 蜜桃 `#FFD39A` / 珊瑚 `#FF7A7A`，圆头分段，中间留 ¥
- 内容控制在画布中部，给 iOS 的圆角遮罩留出安全区

## 六、已经验证到什么程度

**已经真实编译、安装、在模拟器里跑起来，深浅色逐页截图确认。**

| 验证项 | 结果 |
|---|---|
| `xcodebuild` 编译（iOS 27 模拟器 / iPhone 17） | ✅ BUILD SUCCEEDED |
| 安装 + 启动 | ✅ 正常 |
| 从后端拉真实数据 | ✅ 多只基金 / 多家公司 / 数十笔买入 |
| 持仓 · 日历 · 市场 · 设置 四个页签 + 流水页 | ✅ 逐个截图确认 |
| 浅色模式 / 深色模式 | ✅ 两套都截图确认；默认跟随系统，也可在设置里手动切 |
| 基金详情页 Swift Charts 走势图 + 成本虚线 | ✅ 正常绘制 |
| 持仓页 `+` → 「添加持仓」sheet | ✅ 弹出并正常渲染 |
| 后端写接口（买入 / 删除 / 手动份额 / 搜索） | ✅ curl 逐个验证，含错误分支 |
| 完整类型检查（真实 iOS 27 SDK） | ✅ 零错误、零警告 |
| `project.pbxproj` / `Info.plist` / `.xcscheme` / `Contents.json` | ✅ 全部通过语法校验 |

### 本机引擎 vs Python 后端：逐位一致

本机引擎（`FundAPI` + `PortfolioEngine`）是从 `server.py` 逐函数移植的，验证方式不是「看起来差不多」，而是拿同一份 `holdings.json` 各算一遍，递归对比 JSON：

| 对比项 | 结果 |
|---|---|
| 十几只基金的 `market_value` / `shares` / `cost` / `profit` / `est_pct` / `est_beta` | ✅ **浮点逐位相同** |
| `summary` 全部字段（含 `est_profit` / `xirr` / `xirr_days`） | ✅ 相同 |
| `curve` 7 个点 | ✅ 整条数组相同 |
| `/api/fund/<code>` 全量详情（623 个净值点 + lots + xirr） | ✅ 相同 |
| 基金搜索结果 | ✅ 相同 |
| 非时间戳字段的差异数 | **0** |

唯一不同的两个字段是 `updated` 和 `market.updated` 这两个墙钟时间字符串。

**关掉服务器后实测**：`pkill server.py` 之后 App 依然启动，总市值 / 涨跌 / 持有收益与服务器模式完全一致。

`HoldingsStore` 的 `addBuy` / `removeLot` / `setManual` / `addFund` / `removeFund` 及错误文案另有 28 项测试全通过。**从数值层面看，不再需要电脑。**

### 已知限制

- 东财的汇率历史接口（`push2his` / `133.USDCNH`）目前对本机返回空，所以汇率只按当日变动计算 —— Python 和 Swift 两边行为一致，不是移植差异。
- `fetchDividends` 已实现（东财 F10），但 Python 端没有对应函数，无对照；目前只有 `Data:null`。
- 从旧服务器 `migrateFromServer` 是有损的（只能反推 `[date, amount, nav, shares]`）。
- `HoldingsStore` 保存时会丢掉 `holdings.json` 顶层的 `_说明` 注释键（不影响计算）。
- 网络失败时 Swift 比 Python 宽容：Python 会 500，Swift 会退回空行情继续算，不会白屏。

> 模拟器**无法用命令点击**（`simctl` 没有 tap），所以「点按钮→弹 sheet」这条路径是用 `FB_ADD=1` 环境变量走同一条 `.sheet(isPresented:)` 代码触发的，详情页的三个标签也是用 `FB_DETAILTAB=trend|lots` 分别启动截图的，内容渲染已确认；标签切换的点击手感、左滑删除、键盘收起、滚动到底部这类**手势**行为没法自动验证，需要你上手试一下。

截图没有随仓库发布 —— 界面里全是作者真实的持仓金额。想看图自己跑起来截：

```bash
xcrun simctl io booted screenshot shot.png
```

## 七、从命令行编译运行

```bash
cd CreamFolio
xcodebuild -project CreamFolio.xcodeproj -scheme CreamFolio -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./build \
  MODULE_CACHE_DIR="$PWD/.cache/modules" \
  CODE_SIGNING_ALLOWED=NO build

APP="$PWD/build/Build/Products/Debug-iphonesimulator/CreamFolio.app"
xcrun simctl boot "iPhone 17" 2>/dev/null
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.local.fundboard
xcrun simctl io booted screenshot shot.png
```

### 调试用启动参数

`RootView` 和 `PortfolioView` 会读这几个环境变量，方便自动化进到指定页面：

```bash
SIMCTL_CHILD_FB_FLOW=1      xcrun simctl launch booted com.dafan.fundboard   # 直接进流水页（push）
SIMCTL_CHILD_FB_TAB=calendar xcrun simctl launch booted com.dafan.fundboard  # 直接进日历页
SIMCTL_CHILD_FB_CAL=year    xcrun simctl launch booted com.dafan.fundboard   # 日历页直接停在「年」视图
SIMCTL_CHILD_FB_PLAN=1      xcrun simctl launch booted com.dafan.fundboard   # 详情页自动弹「定投计划」
SIMCTL_CHILD_FB_DETAILTAB=trend xcrun simctl launch booted com.dafan.fundboard # 详情页直接停在「走势」（trend / lots）
SIMCTL_CHILD_FB_DETAILSCROLL=1 xcrun simctl launch booted com.dafan.fundboard # 详情页启动后自动滚到标签栏（看吸顶）
SIMCTL_CHILD_FB_KINDROUTE=主动混合 xcrun simctl launch booted com.dafan.fundboard # 按正常 push 进资产类型页（带返回键）
SIMCTL_CHILD_FB_TAB=market  xcrun simctl launch booted com.dafan.fundboard   # 直接进市场页
SIMCTL_CHILD_FB_FUND=012345 xcrun simctl launch booted com.dafan.fundboard   # 直接进某只基金详情
SIMCTL_CHILD_FB_ADD=1       xcrun simctl launch booted com.dafan.fundboard   # 启动后自动弹「添加持仓」
```

### 纯类型检查（改代码后想快速验证）

```bash
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
  -typecheck -sdk "$SDK" -target arm64-apple-ios17.0-simulator -swift-version 5 \
  -module-cache-path ./.cache/module -Xcc -fmodules-cache-path=./.cache/clang \
  -disable-sandbox -Xfrontend -disable-sandbox CreamFolio/*.swift
```

## 八、Xcode 27 的几个变化（踩过的坑）

- **Simulator.app 没有了**，换成了 `Xcode.app/Contents/Applications/DeviceHub.app`。命令行操作仍然用 `xcrun simctl`，而且**无头也能跑**：设备能启动、App 能安装运行、截图用 `xcrun simctl io booted screenshot`。也就是说看不到图形模拟器窗口也能完整验证。

- **悬浮式标签栏**：主界面不再用系统 `TabView` 的 tab bar。`RootView` 用 `ZStack` 把 `FloatingTabBar`
  叠在 `TabView` 上，原生 bar 隐藏；各页底部按悬浮条高度留了 92pt 内容边距，最后一行能滚出来。
  设置里的「预览悬浮导航」入口已删除（主界面已经在用这套组件）；`TabBarPreviewView` 只保留作调试预览（`FB_PREVIEW=1`）。

- **`-disable-sandbox`**：只有在被沙箱限制的 shell（比如 AI agent 的执行环境）里编译才需要加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`，原因是 Swift 宏插件服务器无法完成自我沙箱化。你在自己的终端或 Xcode 里正常编译不需要这个参数。
