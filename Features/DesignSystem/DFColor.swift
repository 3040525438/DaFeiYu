import SwiftUI
import UIKit

/// 语义色令牌。
/// 视图层只引用「用途」，不写死色值；深浅色由系统 colorScheme 自动解析，
/// 因此不要在视图里判断 `colorScheme == .dark`。
enum DFColor {
    // 页面与容器
    static let canvas = dynamic(light: 0xFBF9F5, dark: 0x121A23)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1B2531)
    static let surfaceAlt = dynamic(light: 0xF3F0E9, dark: 0x202B38)

    // 文字
    static let ink = dynamic(light: 0x253140, dark: 0xE7EDF4)
    static let inkMuted = dynamic(light: 0x7C8899, dark: 0x92A2B3)

    // 品牌
    static let primary = dynamic(light: 0x6E92B8, dark: 0x7FA4C8)
    static let primaryDeep = dynamic(light: 0x55799E, dark: 0x95B6D6)
    static let lilac = dynamic(light: 0xB7ABDD, dark: 0x9C90C8)
    static let accentPink = dynamic(light: 0xF0C6CE, dark: 0xC99AA6)

    // 线与状态
    static let hairline = dynamic(light: 0xEDE7DC, dark: 0x26313F)
    /// 发送失败气泡的 1px 暖灰描边
    static let warmHairline = dynamic(light: 0xE4DCD0, dark: 0x3A4453)
    static let danger = dynamic(light: 0xC4635A, dark: 0xE0897F)
    static let success = dynamic(light: 0x5E9C82, dark: 0x7FBFA4)
    static let warning = dynamic(light: 0xC99A45, dark: 0xE0B76A)

    // 低透明度底色（装饰与标签，禁用在大段文字下方）
    static let primarySoft = primary.opacity(0.13)
    static let lilacSoft = lilac.opacity(0.16)
    static let pinkSoft = accentPink.opacity(0.28)
    static let dangerSoft = danger.opacity(0.16)
    /// 内高光与浅描边
    static let sheen = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.10)

    // 气泡
    static let bubbleOther = surface
    static let bubbleOtherShadow = dynamic(light: 0x2B3A4A, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.45)

    /// 己方气泡渐变：与设计稿一致，135°
    static let bubbleMe = LinearGradient(
        colors: [
            dynamic(light: 0x6E92B8, dark: 0x4B6C90),
            dynamic(light: 0x83A7C9, dark: 0x5C80A6)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 角色标记渐变（头像、鱼形标记）
    static let brandMark = LinearGradient(
        colors: [
            dynamic(light: 0xB7ABDD, dark: 0x6F639C),
            dynamic(light: 0x6E92B8, dark: 0x4A6A8C)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    /// 由 0xRRGGBB 生成颜色，alpha 单独传入，避免与位运算混淆。
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
