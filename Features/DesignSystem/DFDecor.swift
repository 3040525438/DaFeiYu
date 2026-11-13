import SwiftUI

/// 鱼鳞暗纹：Canvas 绘制，零图片资源，尺寸自适应。
/// 只用于页面头部，并向下淡出；不得进入正文卡片内部。
struct DFScaleBackdrop: View {
    var opacity: Double = 0.16

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var row = 0
            var y: CGFloat = 12
            while y < size.height + 24 {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : -12
                while x < size.width + 24 {
                    path.move(to: CGPoint(x: x, y: y))
                    path.addQuadCurve(
                        to: CGPoint(x: x + 24, y: y),
                        control: CGPoint(x: x + 12, y: y - 12)
                    )
                    x += 24
                }
                y += 12
                row += 1
            }
            context.stroke(path, with: .color(DFColor.primary.opacity(opacity)), lineWidth: 1)
        }
        .mask(
            LinearGradient(
                colors: [.black, .black.opacity(0.35), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

/// 柔光光斑：两个模糊圆，给纯色底一点呼吸感。
/// 只放在页面顶部或角色背后，不进正文区域。
struct DFSoftGlow: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(DFColor.lilac.opacity(0.30))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: 130, y: -80)
            Circle()
                .fill(DFColor.primary.opacity(0.22))
                .frame(width: 200, height: 200)
                .blur(radius: 28)
                .offset(x: -120, y: 20)
        }
        .allowsHitTesting(false)
    }
}

/// 角色标记：把角色最小化为可识别的小方块，用于导航与头像。
/// 表情变化时只换内部图形，外框保持不变。
struct DFCharacterMark: View {
    var size: CGFloat = 31

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
            .fill(DFColor.brandMark)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "fish.fill")
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
                    .stroke(DFColor.sheen, lineWidth: 1)
            )
    }
}
