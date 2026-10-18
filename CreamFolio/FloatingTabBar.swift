import SwiftUI

/// 悬浮胶囊导航条 —— 参考图底部那一条：一个深色选中项 + 几个圆形图标
struct FloatingTabBar: View {
    @Binding var selection: Int
    var items: [(icon: String, title: String)]

    @Namespace private var pill
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                let on = selection == idx
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        selection = idx
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: on ? .semibold : .medium))
                        if on {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(on ? Theme.canvas : Theme.muted)
                    .padding(.horizontal, on ? 20 : 0)
                    .frame(height: 48)
                    .frame(width: on ? nil : 48)
                    .background {
                        if on {
                            Capsule()
                                .fill(Theme.ink)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        } else {
                            Circle().fill(Theme.card)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == idx ? .isSelected : [])
            }
        }
        .padding(7)
        .background {
            GlassSurface(shape: Capsule(), tint: 0.24)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10),
                radius: 18, x: 0, y: 8)
    }
}

/// 预览页：只验证组件本身，不碰现有导航
struct TabBarPreviewView: View {
    @State private var sel = 0

    private let items = [
        ("chart.pie.fill", "持仓"),
        ("calendar", "日历"),
        ("chart.line.uptrend.xyaxis", "市场"),
        ("gearshape.fill", "设置"),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    SoftCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("估算总市值").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            Text("¥26,816.91").font(.urbanist(34, .bold))
                                .foregroundStyle(Theme.ink)
                            TrendBadge(pct: -4.13, text: "-37.11  -4.13%")
                        }
                    }
                    ForEach(0..<3, id: \.self) { i in
                        SoftCard(padding: 14, radius: 20) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(["东财启和混合 C", "中航机遇领航 A", "博时黄金 ETF"][i])
                                        .font(.system(size: 15, weight: .medium))
                                    Text("示例数据").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                TrendBadge(pct: [0.44, -22.71, 6.2][i])
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }

            FloatingTabBar(selection: $sel, items: items)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .navigationTitle("悬浮导航预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
