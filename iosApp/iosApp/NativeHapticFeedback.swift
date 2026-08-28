import SwiftUI
import UIKit

enum NativeHapticStrength: String, CaseIterable, Identifiable {
    case light
    case standard
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "轻"
        case .standard: return "标准"
        case .strong: return "强"
        }
    }
}

struct NativeHapticFeedbackConfiguration: Equatable {
    var isEnabled = true
    var strength = NativeHapticStrength.standard
}

enum NativeHapticFeedbackEvent: Equatable {
    case selection
    case commit
    case longPress
    case dismiss
    case navigationBoundary
    case refreshSucceeded
    case refreshIgnored
    case strengthPreview
}

struct NativeHapticFeedbackAction {
    private let configuration: NativeHapticFeedbackConfiguration
    private let perform: @MainActor (NativeHapticFeedbackEvent, NativeHapticStrength) -> Void

    init(
        configuration: NativeHapticFeedbackConfiguration,
        perform: @escaping @MainActor (NativeHapticFeedbackEvent, NativeHapticStrength) -> Void
    ) {
        self.configuration = configuration
        self.perform = perform
    }

    @MainActor
    func callAsFunction(_ event: NativeHapticFeedbackEvent) {
        guard configuration.isEnabled else { return }
        perform(event, configuration.strength)
    }

    @MainActor
    func previewStrength(_ strength: NativeHapticStrength) {
        guard configuration.isEnabled else { return }
        perform(.strengthPreview, strength)
    }

    @MainActor
    static func live(configuration: NativeHapticFeedbackConfiguration) -> Self {
        Self(configuration: configuration) { event, strength in
            NativeHapticFeedbackPerformer.perform(event, strength: strength)
        }
    }

    static let disabled = Self(
        configuration: .init(isEnabled: false),
        perform: { _, _ in }
    )
}

@MainActor
private enum NativeHapticFeedbackPerformer {
    // 复用 generator 实例（Apple 推荐）：避免每次新建导致系统节流“吃掉”反馈、时机漂移
    private static var impactLight: UIImpactFeedbackGenerator?
    private static var impactMedium: UIImpactFeedbackGenerator?
    private static var impactHeavy: UIImpactFeedbackGenerator?
    private static var selection: UISelectionFeedbackGenerator?
    private static var notification: UINotificationFeedbackGenerator?

    static func perform(_ event: NativeHapticFeedbackEvent, strength: NativeHapticStrength) {
        switch event {
        case .selection, .refreshIgnored:
            // 最轻：选择反馈（点赞/切换等）
            selectionGenerator().selectionChanged()
        case .commit:
            // 柔和主反馈：用轻-中强度，避免 heavy 的生硬感
            impactGenerator(style: impactStyle(for: strength)).impactOccurred(intensity: 0.4)
        case .longPress:
            impactGenerator(style: impactStyle(for: strength)).impactOccurred(intensity: 0.5)
        case .dismiss:
            impactGenerator(style: impactStyle(for: strength)).impactOccurred(intensity: 0.3)
        case .navigationBoundary:
            // 边界提示：中等强度，柔和
            impactGenerator(style: impactStyle(for: strength)).impactOccurred(intensity: 0.5)
        case .refreshSucceeded:
            notificationGenerator().notificationOccurred(.success)
        case .strengthPreview:
            impactGenerator(style: impactStyle(for: strength)).impactOccurred(intensity: 0.6)
        }
    }

    private static func impactStyle(
        for strength: NativeHapticStrength
    ) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch strength {
        case .light: return .light
        case .standard: return .medium
        case .strong: return .heavy
        }
    }

    private static func impactGenerator(
        style: UIImpactFeedbackGenerator.FeedbackStyle
    ) -> UIImpactFeedbackGenerator {
        switch style {
        case .light:
            if let generator = impactLight { return generator }
            let generator = UIImpactFeedbackGenerator(style: .light)
            impactLight = generator
            return generator
        case .heavy:
            if let generator = impactHeavy { return generator }
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy = generator
            return generator
        default:
            if let generator = impactMedium { return generator }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            impactMedium = generator
            return generator
        }
    }

    private static func selectionGenerator() -> UISelectionFeedbackGenerator {
        if let generator = selection { return generator }
        let generator = UISelectionFeedbackGenerator()
        selection = generator
        return generator
    }

    private static func notificationGenerator() -> UINotificationFeedbackGenerator {
        if let generator = notification { return generator }
        let generator = UINotificationFeedbackGenerator()
        notification = generator
        return generator
    }
}

enum NativeHapticStrengthSelectionPolicy {
    static func shouldPreview(
        current: NativeHapticStrength,
        selected: NativeHapticStrength,
        isHapticsEnabled: Bool
    ) -> Bool {
        isHapticsEnabled && current != selected
    }
}

struct NativeRefreshHapticPolicy {
    static func shouldEmit(
        previousSuccessfulRefreshAt: Date?,
        currentSuccessfulRefreshAt: Date?
    ) -> Bool {
        guard previousSuccessfulRefreshAt != nil,
              currentSuccessfulRefreshAt != nil
        else { return false }
        return currentSuccessfulRefreshAt != previousSuccessfulRefreshAt
    }
}

private struct NativeHapticFeedbackEnvironmentKey: EnvironmentKey {
    static let defaultValue = NativeHapticFeedbackAction.disabled
}

extension EnvironmentValues {
    var nativeHapticFeedback: NativeHapticFeedbackAction {
        get { self[NativeHapticFeedbackEnvironmentKey.self] }
        set { self[NativeHapticFeedbackEnvironmentKey.self] = newValue }
    }
}
