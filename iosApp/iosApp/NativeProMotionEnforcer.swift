import QuartzCore
import UIKit

/// 强制 120Hz（ProMotion 高刷）控制器。
///
/// 原理：持有一个常驻的 `CADisplayLink`，并将其 `preferredFrameRateRange` 锁定在
/// 120Hz（最小 120 / 最大 120 / 期望 120）。displayLink 被添加到主 RunLoop 后，
/// 系统会持续以该目标帧率驱动渲染管线，从而避免 App 在长时间无交互/滚动降速时
/// 被系统自动降到 60Hz，保证信息流/评论等滑动场景始终满帧。
///
/// 仅在 ProMotion 设备上生效（非 ProMotion 设备该范围会被系统忽略）。
@MainActor
enum NativeProMotionEnforcer {
    private static var displayLink: CADisplayLink?
    private static var isEnabled = false

    /// 应用当前设置（App 启动与开关变化时调用）
    static func apply(enabled: Bool) {
        isEnabled = enabled
        update()
    }

    /// 由偏好 setter 调用：开关变化即时启停
    static func update(enabled: Bool) {
        isEnabled = enabled
        update()
    }

    private static func update() {
        if isEnabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private static func startIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: ProMotionDisplayLinkTarget.instance, selector: #selector(ProMotionDisplayLinkTarget.tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 120,
                maximum: 120,
                preferred: 120
            )
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private static func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// CADisplayLink 需要 ObjC 可派发的 target；用单例避免闭包持有环
private final class ProMotionDisplayLinkTarget: NSObject {
    static let instance = ProMotionDisplayLinkTarget()

    @objc func tick() {
        // 空实现：仅维持 displayLink 处于激活状态即可锁定帧率
    }
}
