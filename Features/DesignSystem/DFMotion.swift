import SwiftUI

/// 动效语义：视图只引用名字，时长与曲线集中管理。
enum DFMotion {
    static let messageIn = Animation.easeOut(duration: 0.20)
    static let pageSwitch = Animation.easeInOut(duration: 0.22)
    static let cardIn = Animation.easeOut(duration: 0.28)
    static let press = Animation.easeOut(duration: 0.12)
    /// 全 App 唯一允许弹性的地方（亲密度、纪念日）
    static let celebrate = Animation.spring(response: 0.6, dampingFraction: 0.78)
    static let caretBlink = Animation.easeInOut(duration: 0.55).repeatForever(autoreverses: true)

    /// 环境动效。开启「减弱动态效果」时返回 nil，视图据此关闭循环动画。
    static func ambient(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 7).repeatForever(autoreverses: true)
    }
}
