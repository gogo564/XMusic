import SwiftUI
import UIKit

/// 全局主题：预设主题色 + 深色/浅色跟随系统或手动切换。
/// iOS 15 无系统动态色板，这里用一套精选颜料保证任意深浅下文字对比清晰。
enum ThemeColor: String, CaseIterable, Identifiable {
    case sodaPurple   // 汽水瓶紫
    case appleBlue
    case musicRed
    case forestGreen
    case sunsetOrange
    case oceanTeal
    case rosePink
    case graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sodaPurple: return "汽水紫"
        case .appleBlue: return "系统蓝"
        case .musicRed: return "音乐红"
        case .forestGreen: return "森林绿"
        case .sunsetOrange: return "日落橙"
        case .oceanTeal: return "海洋青"
        case .rosePink: return "玫瑰粉"
        case .graphite: return "石墨灰"
        }
    }

    var color: Color {
        switch self {
        case .sodaPurple: return Color(red: 0.55, green: 0.36, blue: 0.95)   // #8C5CF2 汽水紫
        case .appleBlue: return Color(red: 0.00, green: 0.48, blue: 1.00)    // 系统蓝
        case .musicRed: return Color(red: 0.91, green: 0.30, blue: 0.24)     // 音乐红
        case .forestGreen: return Color(red: 0.20, green: 0.62, blue: 0.36)  // 森林绿
        case .sunsetOrange: return Color(red: 0.95, green: 0.51, blue: 0.13) // 日落橙
        case .oceanTeal: return Color(red: 0.00, green: 0.60, blue: 0.60)    // 海洋青
        case .rosePink: return Color(red: 0.90, green: 0.40, blue: 0.52)     // 玫瑰粉
        case .graphite: return Color(red: 0.36, green: 0.38, blue: 0.42)     // 石墨灰
        }
    }

    var uiColor: UIColor { UIColor(color) }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var color: ThemeColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: Keys.color) }
    }
    @Published var mode: ThemeMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            applyMode()
        }
    }
    /// 界面是否深色（跟随系统或手动模式的最终结果）
    @Published private(set) var isDark: Bool

    private enum Keys {
        static let color = "themeColor"
        static let mode = "themeMode"
    }

    private init() {
        let savedColor = UserDefaults.standard.string(forKey: Keys.color).flatMap(ThemeColor.init(rawValue:)) ?? .sodaPurple
        color = savedColor
        let savedMode = UserDefaults.standard.string(forKey: Keys.mode).flatMap(ThemeMode.init(rawValue:)) ?? .system
        mode = savedMode
        isDark = UITraitCollection.current.userInterfaceStyle == .dark
        applyMode()
    }

    /// 跟随系统模式：监听 trait 变化
    func updateForSystemAppearance() {
        guard mode == .system else { return }
        isDark = UITraitCollection.current.userInterfaceStyle == .dark
        AppDelegate.refreshGlobalAppearance(dark: isDark)
    }

    private func applyMode() {
        switch mode {
        case .light:
            isDark = false
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .forEach { $0.overrideUserInterfaceStyle = .light }
        case .dark:
            isDark = true
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .forEach { $0.overrideUserInterfaceStyle = .dark }
        case .system:
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .forEach { $0.overrideUserInterfaceStyle = .unspecified }
            isDark = UITraitCollection.current.userInterfaceStyle == .dark
        }
        // 深/浅切换后刷新全局 appearance，让 List 背景实时跟随纯黑/白色
        // （传参而不是取 .shared：init→applyMode 时 shared 的 dispatch_once 尚未完成，取它会递归崩溃）
        AppDelegate.refreshGlobalAppearance(dark: isDark)
    }

    /// 主题色（点缀层）——纯黑极简模式下去彩色：深色=近白点缀，亮色=深灰点缀。
    /// 不再随用户主题色（themeColor 仍保留仅供记录/未来扩展，UI 层统一中性）。
    var accent: Color {
        isDark ? Color(white: 0.78) : Color(white: 0.13)
    }
    /// 主题色的柔和底（选中 chip / 图标小面积底）——纯黑白自适应，主题色只做内容不占大面积
    var accentSurface: Color {
        isDark ? Color(white: 0.12) : Color(uiColor: .systemGray5)
    }
    /// 卡片/分组底色（按深浅自适应，纯黑白高对比；深色=纯黑月亮模式）
    var cardBackground: Color {
        isDark ? Color.black : Color(uiColor: .systemGray6)
    }
    /// 次级底色（按钮胶囊未选中）
    var chipBackground: Color {
        isDark ? Color(white: 0.10) : Color(uiColor: .systemGray5)
    }
    /// 分隔/描边
    var separator: Color {
        isDark ? Color(white: 1.0).opacity(0.10) : Color(white: 0.08)
    }
    /// 主文字
    var primaryText: Color {
        isDark ? .white : Color(uiColor: .label)
    }
    var secondaryText: Color {
        isDark ? Color.white.opacity(0.62) : Color(uiColor: .secondaryLabel)
    }
    /// 页面主体背景：深色=纯黑，亮色=系统分组灰（月亮模式：整页黑）
    var pageBackground: Color {
        isDark ? Color.black : Color(uiColor: .systemGroupedBackground)
    }
    /// 渐变封面主体用：accent 派生比
    var gradientStart: Color { accent }
    var gradientEnd: Color { Color(hue: color.uiColor.hueComponent, saturation: 0.85, brightness: 0.45, opacity: 1) }
}

extension UIColor {
    var hueComponent: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }
}

/// 统一的章节标题（替代旧 emoji 标题）：左侧主题色竖条 + 标题文字，可选副标题说明
struct SectionHeader: View {
    let title: String
    var icon: String? = nil
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: 4, height: 18)
            if let icon = icon {
                Image(systemName: icon)
                    .font(.title3.bold())
                    .foregroundColor(Color.accentColor)
            }
            Text(title)
                .font(.title3.bold())
                .foregroundColor(.primary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

/// 主题色胶囊按钮（音源切换、tag 筛选通用）
struct ThemeChip: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void
    let theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.chipBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}