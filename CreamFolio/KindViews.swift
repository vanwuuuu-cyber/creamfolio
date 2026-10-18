import SwiftUI

/// 资产类型卡（参考图里 NVIDIA/GOOGL 那种）：类型名 · 市值 · 迷你走势 · 只数
struct KindCard: View {
    let kind: String
    let count: Int
    let marketValue: Double
    let series: [Double]
    let up: Bool
    let pct: Double?

    var body: some View {
        SoftCard(padding: 14, radius: 22) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("\(count) 只")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }

                Spacer(minLength: 4)

                Sparkline(values: series, up: up, height: 44,
                          lineWidth: 2.4, dotSize: 7)
                    .frame(width: 120)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 5) {
                    PrivacyText(text: Fmt.money(marketValue))
                        .font(.urbanist(17, .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    TrendBadge(pct: pct)
                }
            }
        }
    }
}

/// 可拖动的半透明基金卡
struct DraggableFundCard: View {
    let f: FundItem
    let seed: Int
    let totalMV: Double

    /// 在该组里的序号（用于横向排布）
    let index: Int

    /// 相对画布左上角的位置（画布很宽，靠横向滚动看其余）
    var pos: CGSize {
        let pair = index / 2
        let side = index % 2
        let x = 8.0 + Double(pair) * 176.0 + (side == 0 ? 0.0 : 88.0)
        let y = 8.0 + Double(side) * 92.0
        let jx = Double((index * 89) % 21) - 10
        let jy = Double((index * 131) % 25) - 12
        return CGSize(width: x + jx, height: y + jy)
    }
    /// 近大远小：0.84 ~ 1.10
    var scale: CGFloat {
        CGFloat(1.00 + Double((index * 53) % 51) / 100.0)
    }
    /// ±15°
    private var angle: Double { Double((index * 37) % 31) - 15 }
    private var share: Double {
        totalMV > 0 ? (f.marketValue ?? 0) / totalMV : 0
    }

    /// 每张卡的彩色光晕：参考图里那种绿/粉/紫的柔光，按序号轮换
    private var glow: Color {
        switch index % 3 {
        case 0: return Theme.purple
        case 1: return Theme.teal
        default: return Theme.coral
        }
    }

    var body: some View {
        NavigationLink(value: PortfolioRoute.fund(f.code)) {
            VStack(alignment: .leading, spacing: 5) {
                Text(f.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Sparkline(values: f.seriesValues,
                          up: (f.profitPct ?? 0) >= 0, height: 20)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    PrivacyText(text: Fmt.money(f.marketValue))
                        .font(.urbanist(13, .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    PrivacyText(text: "占 \(Int((share * 100).rounded()))%")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                }
                TrendBadge(pct: f.profitPct)
            }
            .padding(11)
            .frame(width: 140, height: 110, alignment: .topLeading)
            .background {
                GlassSurface(
                    shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
                    tint: 0.36
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [glow.opacity(0.22), Color.clear, Color.white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            // 彩色柔光用 shadow 做，不会像 blur 那样把整片背景糊成一块
            .shadow(color: glow.opacity(0.42), radius: 26, x: 0, y: 10)
            .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .rotationEffect(.degrees(angle))
        .zIndex(Double(scale))
    }
}

/// 点类型卡进来：上面卡片云，下面汇总 + 明细
struct KindFundsView: View {
    let kind: String
    @EnvironmentObject var state: AppState

    private var funds: [FundItem] {
        (state.dashboard?.funds ?? [])
            .filter { ($0.kind ?? "其他") == kind }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
    }
    private var totalMV: Double {
        state.dashboard?.summary.marketValue ?? 0
    }
    private var mv: Double { funds.reduce(0) { $0 + ($1.marketValue ?? 0) } }
    private var cost: Double { funds.reduce(0) { $0 + ($1.cost ?? 0) } }
    private var profit: Double { mv - cost }
    private var profitPct: Double? { cost > 0 ? profit / cost * 100 : nil }

    /// 画布宽度：每 2 张占 300pt
    private var canvasWidth: CGFloat {
        let pairs = CGFloat((min(funds.count, 8) + 1) / 2)
        return max(pairs * 176 + 40, 340)
    }

    private var cloudHeight: CGFloat { 260 }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 上半：整片卡片云可以整体拖动
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(funds.prefix(8).enumerated()), id: \.element.id) { idx, f in
                            let card = DraggableFundCard(f: f, seed: idx,
                                                         totalMV: totalMV, index: idx)
                            card
                                .offset(x: card.pos.width, y: card.pos.height)
                        }
                    }
                    .frame(width: canvasWidth, height: cloudHeight, alignment: .topLeading)
                }
                .frame(height: cloudHeight)
                .scrollClipDisabled()
                .background {
                    // 云层后面的暖光；用 background，不参与布局，不会把卡片挤歪
                    RadialGradient(
                        colors: [Theme.peach.opacity(0.46),
                                 Theme.purple.opacity(0.15),
                                 Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 160
                    )
                    .blur(radius: 24)
                    .allowsHitTesting(false)
                }
                .padding(.top, 24)

                // 下半：汇总
                SoftCard(padding: 16, radius: 22, translucent: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(kind) · 汇总")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                            Spacer()
                            PrivacyText(text: "占组合 \(Int((mv / max(totalMV, 1) * 100).rounded()))%")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.faint)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("市值").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                PrivacyText(text: Fmt.money(mv)).font(.urbanist(19, .bold))
                                    .foregroundStyle(Theme.ink)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("投入").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                PrivacyText(text: Fmt.money(cost)).font(.urbanist(15, .medium))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            TrendBadge(pct: profitPct,
                                       text: "\(Fmt.signed(profit))  \(Fmt.pct(profitPct))")
                        }
                    }
                }

                // 明细
                VStack(alignment: .leading, spacing: 8) {
                    Text("明细 · \(funds.count) 只")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                    ForEach(funds) { f in
                        NavigationLink(value: PortfolioRoute.fund(f.code)) {
                            SoftCard(padding: 13, radius: 18, translucent: true) {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(f.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        HStack(spacing: 0) {
                                            Text("\(f.code) · ")
                                            PrivacyText(text: "占 \(Int(((f.marketValue ?? 0) / max(totalMV, 1) * 100).rounded()))%")
                                        }
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(Theme.faint)
                                    }
                                    Spacer(minLength: 6)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        PrivacyText(text: Fmt.money(f.marketValue))
                                            .font(.urbanist(15, .semiBold))
                                            .foregroundStyle(Theme.ink)
                                        TrendBadge(pct: f.profitPct)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(CloudBackdrop().ignoresSafeArea())
        .navigationTitle(kind)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// 卡片云背后的柔和渐变 —— 参考图那种奶油/蜜桃/淡紫的雾面感。
/// 卡片是半透明的，渐变透上来才有纵深感。
struct CloudBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.canvas
            // 右上：蜜桃暖调（顶部保持奶油色，卡片才不会被紫色压灰）
            RadialGradient(colors: [Theme.peach.opacity(dark ? 0.20 : 0.82), Theme.peach.opacity(0)],
                           center: UnitPoint(x: 0.90, y: 0.02),
                           startRadius: 0, endRadius: 330)
            // 中下部：淡紫（底部卡和内容卡透出一点紫，参考图也是这个走向）
            RadialGradient(colors: [Theme.purple.opacity(dark ? 0.34 : 0.30), Theme.purple.opacity(0)],
                           center: UnitPoint(x: 0.48, y: 0.72),
                           startRadius: 0, endRadius: 380)
            // 左下：极淡青
            RadialGradient(colors: [Theme.teal.opacity(dark ? 0.16 : 0.14), Theme.teal.opacity(0)],
                           center: UnitPoint(x: 0.05, y: 1.0),
                           startRadius: 0, endRadius: 280)
            // 底部轻微提亮，避免发灰（深色模式不提亮）
            if !dark {
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.28)],
                               startPoint: .center, endPoint: .bottom)
            }
        }
    }
}
