import SwiftUI
import UIKit

/// 品牌色板 —— 参考「Clearvest」风格：浅紫白画布 + 毛玻璃卡片 + 胶囊 + 薄荷/珊瑚徽章
/// 颜色全部走动态色，浅色/深色各一套，不再锁死 light。
enum Theme {
    private static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let canvas   = adaptive(UIColor(red: 0.957, green: 0.957, blue: 0.980, alpha: 1),
                                   UIColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 1))   // #F4F4FA / #0E0E13
    static let card     = adaptive(.white,
                                   UIColor(red: 0.102, green: 0.102, blue: 0.118, alpha: 1))    // 白 / #1A1A1E
    static let ink      = adaptive(UIColor(red: 0.031, green: 0.082, blue: 0.047, alpha: 1),
                                   UIColor(red: 0.953, green: 0.957, blue: 0.965, alpha: 1))    // #08150C / #F3F4F6
    static let teal     = adaptive(UIColor(red: 0.004, green: 0.600, blue: 0.475, alpha: 1),
                                   UIColor(red: 0.169, green: 0.827, blue: 0.659, alpha: 1))    // #019979 / #2BD3A8
    static let tealSoft = adaptive(UIColor(red: 0.878, green: 0.953, blue: 0.929, alpha: 1),
                                   UIColor(red: 0.071, green: 0.227, blue: 0.196, alpha: 1))
    static let coral    = adaptive(UIColor(red: 0.898, green: 0.302, blue: 0.310, alpha: 1),
                                   UIColor(red: 1.000, green: 0.478, blue: 0.478, alpha: 1))    // #E54D4F / #FF7A7A
    static let coralSoft = adaptive(UIColor(red: 0.988, green: 0.910, blue: 0.906, alpha: 1),
                                    UIColor(red: 0.227, green: 0.121, blue: 0.133, alpha: 1))
    static let purple   = adaptive(UIColor(red: 0.424, green: 0.318, blue: 1.000, alpha: 1),
                                   UIColor(red: 0.608, green: 0.525, blue: 1.000, alpha: 1))    // #6C51FF / #9B86FF
    static let peach    = adaptive(UIColor(red: 1.000, green: 0.886, blue: 0.706, alpha: 1),
                                   UIColor(red: 1.000, green: 0.827, blue: 0.604, alpha: 1))    // #FFE2B4 / #FFD39A
    static let muted    = adaptive(UIColor(red: 0.443, green: 0.443, blue: 0.502, alpha: 1),
                                   UIColor(red: 0.651, green: 0.651, blue: 0.698, alpha: 1))
    static let faint    = adaptive(UIColor(red: 0.639, green: 0.639, blue: 0.690, alpha: 1),
                                   UIColor(red: 0.486, green: 0.486, blue: 0.535, alpha: 1))
}

/// 外观设置：跟随系统 / 强制浅色 / 强制深色
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// 毛玻璃卡面：ultraThinMaterial 打底 + 一层很薄的白色渐变 + 顶部高光边。
/// 背景的奶油/蜜桃/淡紫会透上来，卡面不再是纯白，和参考图那种「半透明卡片」一致。
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    /// 白色覆膜的强度：0 = 全透，0.5 = 接近白卡
    var tint: Double = 0.30
    /// 额外叠一点蜜桃/淡紫，让卡面有冷暖层次
    var warm: Bool = true
    var material: Material = .thinMaterial

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        shape
            .fill(material)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: dark
                            ? [Color.white.opacity(0.055), Color.white.opacity(0.015)]
                            : [Color.white.opacity(tint + 0.08),
                               Color.white.opacity(tint * 0.52)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                if warm {
                    shape.fill(
                        LinearGradient(
                            colors: dark
                                ? [Theme.peach.opacity(0.05),
                                   Color.clear,
                                   Theme.purple.opacity(0.09)]
                                : [Theme.peach.opacity(0.14),
                                   Color.clear,
                                   Theme.purple.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: dark
                            ? [Color.white.opacity(0.24), Color.white.opacity(0.04)]
                            : [Color.white.opacity(0.85), Color.white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
    }
}

/// 毛玻璃卡片：大圆角、极淡阴影、卡面带背景色的半透明
struct SoftCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = 24
    /// 半透明：让页面渐变透上来（用在有渐变的页面上）
    var translucent: Bool = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                             tint: translucent ? 0.34 : 0.46)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.38 : 0.07),
                    radius: scheme == .dark ? 22 : 18, x: 0, y: 8)
    }
}

/// 涨跌徽章：薄荷底青绿字 / 淡粉底珊瑚红字
struct TrendBadge: View {
    let pct: Double?
    var text: String? = nil

    @EnvironmentObject private var privacy: PrivacyMode
    private var up: Bool { (pct ?? 0) >= 0 }

    @ViewBuilder
    var body: some View {
        if privacy.hidden {
            Text(PrivacyMode.mask)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        } else {
            normalBadge
        }
    }

    private var normalBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
            Text(text ?? Fmt.pct(pct))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(up ? Theme.teal : Theme.coral)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(up ? Theme.tealSoft : Theme.coralSoft, in: Capsule())
    }
}

/// 迷你折线：线 + 末端圆点 + 渐隐面积
struct Sparkline: View {
    let values: [Double]
    var up: Bool = true
    var height: CGFloat = 26
    var lineWidth: CGFloat = 1.6
    var dotSize: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let v = values.suffix(30)
            let lo = v.min() ?? 0
            let hi = v.max() ?? 1
            let span = max(hi - lo, 0.0001)
            let w = geo.size.width
            let h = geo.size.height
            let pts = v.enumerated().map { i, x in
                CGPoint(x: w * CGFloat(i) / CGFloat(max(v.count - 1, 1)),
                        y: h * (1 - CGFloat((x - lo) / span)))
            }
            let color = up ? Theme.teal : Theme.coral

            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.18), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .position(pts[pts.count - 1])
                }
            }
        }
        .frame(height: height)
    }
}

/// 胶囊按钮（深色填充 / 浅色描边）
struct PillButton: View {
    let title: String
    var dark: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dark ? Theme.canvas : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(dark ? Theme.ink : Theme.canvas, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}


extension Font {
    /// Urbanist（数字/英文）+ 苹方（中文自动回退）
    static func urbanist(_ size: CGFloat, _ weight: Word = .regular) -> Font {
        .custom(weight.postScript, size: size)
    }
    enum Word {
        case regular, medium, semiBold, bold
        var postScript: String {
            switch self {
            case .regular: return "Urbanist-Regular"
            case .medium: return "Urbanist-Medium"
            case .semiBold: return "Urbanist-SemiBold"
            case .bold: return "Urbanist-Bold"
            }
        }
    }
}


extension View {
    /// 全站统一的品牌页背景：渐变 + 隐藏列表默认底色
    func brandPage() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(CloudBackdrop().ignoresSafeArea())
    }
}
