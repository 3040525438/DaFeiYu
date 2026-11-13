import SwiftUI

/// 4pt 栅格。所有间距只从这里取，避免散落魔法数字。
enum DFSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum DFRadius {
    static let bubble: CGFloat = 16
    static let bubbleTail: CGFloat = 5
    static let card: CGFloat = 14
    static let panel: CGFloat = 20
    static let capsule: CGFloat = 999
}

/// 字阶：正文 15、次要 12、时间戳 10。
enum DFFont {
    static let navTitle = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 12)
    static let timestamp = Font.system(size: 10)
    static let number = Font.system(size: 22, weight: .bold).monospacedDigit()
}

/// 阴影：只向下，模糊半径 ≥ 2 倍 Y 偏移。
enum DFShadow {
    static let cardColor = DFColor.bubbleOtherShadow
    static let cardRadius: CGFloat = 18
    static let cardY: CGFloat = 6
}
