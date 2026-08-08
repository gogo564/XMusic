import SwiftUI
import UIKit

// 汽水式三模式侧边栏（对齐 SidebarContainerViewController + ModeSelectCollectionView）：
// 从右侧滑出的半透明面板，三个模式卡片（推荐/新鲜/熟悉）+ 换一换 + 回到默认推荐。
// 遮罩点击关闭，支持右缘手势呼出（由父视图用 DragGesture 驱动）。

struct ModeSidebarView: View {
    let mode: RecommendMode
    let onSelect: (RecommendMode) -> Void
    let onRefresh: () -> Void
    let onBackToDefault: () -> Void
    let onClose: () -> Void

    @State private var hasAppeared = false

    private let width: CGFloat = 300

    var body: some View {
        ZStack {
            // 遮罩
            Color.black.opacity(hasAppeared ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .animation(.easeInOut(duration: 0.22), value: hasAppeared)

            // 侧边栏面板
            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(RecommendMode.allCases) { m in
                            modeCard(m)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                Spacer(minLength: 0)

                footer
            }
            .frame(width: width, height: UIScreen.main.bounds.height)
            .background(
                LinearGradient(
                    colors: [
                        Color(uiColor: UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)),
                        Color(uiColor: UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .offset(x: hasAppeared ? 0 : width)
            .animation(.easeInOut(duration: 0.25), value: hasAppeared)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.25)) { hasAppeared = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("听歌模式")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            }
            Text("切换模式，换个心情听歌")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 8)
    }

    private func modeCard(_ m: RecommendMode) -> some View {
        let isSelected = m == mode
        return Button(action: { onSelect(m) }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isSelected ? [Color(hex: 0xFF3B5C), Color(hex: 0xFC5C7D)] : [Color.white.opacity(0.12), Color.white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                    Image(systemName: m.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.7))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(m.rawValue)
                        .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                        .foregroundColor(.white)
                    Text(modeSubtitle(m))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? Color(hex: 0xFF3B5C) : .white.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(isSelected ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color(hex: 0xFF3B5C).opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func modeSubtitle(_ m: RecommendMode) -> String {
        switch m {
        case .recommend: return "综合你的口味智能推荐"
        case .fresh: return "听点没听过的歌"
        case .familiar: return "回味熟悉的旋律"
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))

            // 换一换（对齐 ModeSelectRefreshButtonCell）
            Button(action: onRefresh) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                    Text("换一换")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 回到默认推荐（对齐 BackToDefaultButton）
            Button(action: onBackToDefault) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                    Text("回到默认推荐")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 30)
        }
        .background(Color.clear)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
