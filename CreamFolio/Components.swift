import SwiftUI

// ============================================================================
// 公共组件 —— 全部使用系统语义色与系统字体，自动跟随浅色 / 深色模式
// ============================================================================

// MARK: - 数字格式化

enum Fmt {
    static func num(_ v: Double?, _ d: Int = 2) -> String {
        guard let v, v.isFinite else { return "--" }
        return v.formatted(.number.precision(.fractionLength(d)).grouping(.automatic))
    }

    static func money(_ v: Double?, _ d: Int = 2) -> String {
        guard v != nil else { return "--" }
        return "¥" + num(v, d)
    }

    static func signed(_ v: Double?, _ d: Int = 2) -> String {
        guard let v, v.isFinite else { return "--" }
        return (v >= 0 ? "+" : "") + num(v, d)
    }

    static func pct(_ v: Double?, _ d: Int = 2) -> String {
        guard let v, v.isFinite else { return "--" }
        return (v >= 0 ? "+" : "") + num(v, d) + "%"
    }

    /// 涨跌配色：红涨绿跌（国内习惯，和天天基金等 App 一致）
    static func tone(_ v: Double?) -> Color {
        guard let v, v.isFinite else { return .secondary }
        return v > 0 ? .red : (v < 0 ? .green : .secondary)
    }

    static func shortDate(_ s: String?) -> String {
        guard let s, s.count >= 10 else { return s ?? "--" }
        return String(s.suffix(5))
    }

    static func weekday(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return "" }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let i = Calendar.current.component(.weekday, from: d) - 1
        return (i >= 0 && i < names.count) ? names[i] : ""
    }
}

// MARK: - 大号金额

// MARK: - 行情行

struct QuoteRow: View {
    let title: String
    let quote: MarketQuote?
    var isFX = false

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.pct(quote?.pct))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Fmt.tone(quote?.pct))
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        guard let q = quote else { return "--" }
        if isFX, let pips = q.pips {
            return Fmt.signed(pips, 0) + " 点"
        }
        guard let p = q.price else { return "--" }
        return Fmt.num(p, p > 1000 ? 2 : 4)
    }
}

// MARK: - 错误提示

struct InlineError: View {
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("数据获取失败")
                Text(text).font(.caption).foregroundStyle(.secondary)
                Text("检查电脑上的 python3 server.py 是否在运行，以及「设置」里的地址是否正确。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

// ============================================================================
// 卡片 —— 「安静的画布」：颜色只给数据，不拿来装饰界面
//   参考 Copilot Money 的原则：画布后退，让数字承担视觉重量。
//   卡面是半透明毛玻璃（GlassSurface），让背景的奶油/淡紫透上来；
//   文字用语义色，压在玻璃上仍然清楚。
// ============================================================================

enum CardStyle {
    /// 卡面：比画布抬升一档，颜色交给系统
    static let surface = Theme.card

    /// 选中 / 展开时轻微提亮
    static let surfaceHi = Theme.canvas

    /// 平台标识色：只用作小字标，绝不铺满整张卡
    static let accents: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.95),
        Color(red: 0.62, green: 0.45, blue: 0.92),
        Color(red: 0.36, green: 0.66, blue: 0.62),
        Color(red: 0.80, green: 0.62, blue: 0.36),
        Color(red: 0.52, green: 0.56, blue: 0.64),
        Color(red: 0.86, green: 0.48, blue: 0.42),
    ]

    static func accent(_ i: Int) -> Color {
        accents[((i % accents.count) + accents.count) % accents.count]
    }
}

struct WalletCard<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = 24
    var highlighted = false
    /// 半透明：让页面渐变透上来
    var translucent = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GlassSurface(
                    shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                    tint: highlighted ? 0.62 : (translucent ? 0.34 : 0.46)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.07),
                    radius: scheme == .dark ? 22 : 18, x: 0, y: 8)
    }
}

/// 列表里的单行玻璃卡：流水 / 行情用它替换系统白底行
struct GlassRow<Content: View>: View {
    var padding: CGFloat = 14
    var radius: CGFloat = 20
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(.horizontal, padding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                             tint: 0.36)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.05),
                    radius: 12, x: 0, y: 5)
    }
}

extension View {
    /// 让 List 的一行变成独立的玻璃卡，而不是系统分组白底
    func glassListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// 卡片上的圆形字标（用平台色轻染，是一张卡上唯一的彩色元素）
struct CardAvatar: View {
    let text: String
    var tint: Color = .accentColor
    var size: CGFloat = 24

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/// 卡片上的小标签
struct CardCaption: View {
    let text: String
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .scaledFont(size, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .lineLimit(2)
    }
}

/// 卡片上的次级数值
struct CardValue: View {
    let text: String
    var size: CGFloat = 17
    /// 笔数这类非金额信息不需要跟着隐藏
    var sensitive: Bool = true

    @EnvironmentObject private var privacy: PrivacyMode

    var body: some View {
        Text(privacy.hidden && sensitive ? PrivacyMode.mask : text)
            .font(.urbanist(size, .semiBold))
            .foregroundStyle(.primary)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}

/// 卡片上的主数字：字距收紧，是整页的视觉锚点
struct CardHeroValue: View {
    let text: String
    var size: CGFloat = 42

    @EnvironmentObject private var privacy: PrivacyMode

    var body: some View {
        Text(privacy.hidden ? PrivacyMode.mask : text)
            .font(.urbanist(size, .bold))
            .tracking(-1.1)
            .foregroundStyle(.primary)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
    }
}

/// 涨跌小圆点：唯一允许出现在「标签旁」的颜色
struct ToneDot: View {
    let value: Double?
    var size: CGFloat = 6

    @EnvironmentObject private var privacy: PrivacyMode

    var body: some View {
        Circle()
            .fill(privacy.hidden ? Color.secondary.opacity(0.45) : Fmt.tone(value))
            .frame(width: size, height: size)
    }
}

// ============================================================================
// 卡片进详情的缩放转场（iOS 18+ 的 zoom transition，低版本自动退化为普通 push）
// ============================================================================

extension View {
    @ViewBuilder
    func cardSource(id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: ns)
        } else {
            self
        }
    }

    @ViewBuilder
    func cardDestination(id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            self
        }
    }
}

// ============================================================================
// 载入动画：红色折线一帧一帧往上走
//   用「逐帧跳」而不是平滑描边，看起来像序列帧（flipbook）而不是进度条。
//   纯矢量绘制，深浅色都清晰，也不用塞一堆 PNG。
// ============================================================================

struct RisingChartLoader: View {
    var caption: String? = "载入中…"

    /// 归一化坐标（0…1，y 越小位置越高）
    private static let shape: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.86),
        CGPoint(x: 0.11, y: 0.74),
        CGPoint(x: 0.22, y: 0.81),
        CGPoint(x: 0.33, y: 0.62),
        CGPoint(x: 0.44, y: 0.69),
        CGPoint(x: 0.55, y: 0.46),
        CGPoint(x: 0.66, y: 0.53),
        CGPoint(x: 0.77, y: 0.30),
        CGPoint(x: 0.88, y: 0.37),
        CGPoint(x: 1.00, y: 0.12),
    ]

    /// 一共多少帧（= 折线多少段）
    private let frames = 10

    @State private var frame = 0
    @State private var showHint = false

    var body: some View {
        VStack(spacing: 14) {
            chart
                .frame(width: 152, height: 72)

            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if showHint {
                Text("第一次打开要抓十几只基金的历史净值，会慢一些")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        // 撑出一个接近半屏的高度，让它在列表行里也落在视觉中心
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
        .task { await loop() }
    }

    private var chart: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = Self.shape.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let t = CGFloat(frame) / CGFloat(frames)

            let line = Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
            }

            // 折线下方的面积，随帧从左往右刷出来
            let area = Path { p in
                p.move(to: CGPoint(x: 0, y: h))
                for pt in pts { p.addLine(to: pt) }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
            }

            ZStack(alignment: .topLeading) {
                area
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.30), Color.red.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(0, w * t), height: h)
                    }

                line
                    .trim(from: 0, to: t)
                    .stroke(
                        Color.red,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: Color.red.opacity(0.45), radius: 5)
            }
        }
    }

    @MainActor
    private func loop() async {
        // 超过 6 秒还在转，说明是首次冷启动，给一句解释
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showHint = true }
        }

        while !Task.isCancelled {
            for i in 0...frames {
                if Task.isCancelled { return }
                // 每帧只给 50ms 的过渡，本质还是「跳帧」
                withAnimation(.linear(duration: 0.05)) { frame = i }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            // 画满之后停顿一下，然后直接跳回第 0 帧 —— 序列帧循环就该是「啪」地重来
            try? await Task.sleep(nanoseconds: 360_000_000)
            if Task.isCancelled { return }
            frame = 0
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}


// ============================================================================
// 让卡片里的固定字号也跟随系统动态字体
//   直接写 .scaledFont(42) 是不缩放的 —— 用户在系统里调大字体时，
//   列表行会变大、卡片纹丝不动。统一走这个修饰器。
// ============================================================================

struct ScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let mono: Bool
    @ScaledMetric private var scale: CGFloat

    init(size: CGFloat, weight: Font.Weight, design: Font.Design,
         mono: Bool, relativeTo style: Font.TextStyle) {
        self.size = size
        self.weight = weight
        self.design = design
        self.mono = mono
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: style)
    }

    func body(content: Content) -> some View {
        let base = Font.system(size: size * scale, weight: weight, design: design)
        return content.font(mono ? base.monospacedDigit() : base)
    }
}

extension View {
    /// 固定字号 + 跟随动态字体。relativeTo 决定它跟哪一档缩放。
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    mono: Bool = false,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design,
                            mono: mono, relativeTo: style))
    }
}


// ============================================================================
// 调试钩子（只有 DEBUG 构建才读环境变量）
//   FB_TAB / FB_FUND / FB_ADD / FB_FAN / FB_FLOW
// ============================================================================

enum DebugHooks {
    static func env(_ key: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[key]
        #else
        return nil
        #endif
    }

    static func isOn(_ key: String) -> Bool {
        env(key) == "1"
    }
}
