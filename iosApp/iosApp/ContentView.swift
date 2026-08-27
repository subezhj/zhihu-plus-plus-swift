import SwiftUI

struct AppHostView: View {
    let hostModel: HostModel
    @ObservedObject private var router: AppRouter
    @ObservedObject private var appLock: NativeAppLockCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(hostModel: HostModel) {
        self.hostModel = hostModel
        _router = ObservedObject(wrappedValue: hostModel.router)
        _appLock = ObservedObject(wrappedValue: hostModel.appLock)
    }

    var body: some View {
        ZStack {
            NativeAppShell(
                hostModel: hostModel,
                isAppUnlocked: appLock.state == .unlocked
            )
            if appLock.state != .unlocked {
                NativeAppLockGate(coordinator: appLock, disableUnavailableLock: { hostModel.setAppLock(false) })
            }
        }
        .onAppear {
            let dynamicDark = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 25.0 / 255.0, green: 25.0 / 255.0, blue: 25.0 / 255.0, alpha: 1.0)
                    : .systemBackground
            }

            // Enable high-performance shared URL cache for lightning fast image loading and instant reuse
            URLCache.shared = URLCache(
                memoryCapacity: 100 * 1024 * 1024,
                diskCapacity: 500 * 1024 * 1024,
                diskPath: "zhihu_plus_media_cache"
            )

            // Configure global UIWindow background so no default black root shines through
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                window.backgroundColor = dynamicDark
            }

            let tabAppearance = UITabBarAppearance()
            tabAppearance.configureWithTransparentBackground()
            tabAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            tabAppearance.shadowColor = UIColor.separator.withAlphaComponent(0.15)
            UITabBar.appearance().standardAppearance = tabAppearance
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance

            let navAppearance = UINavigationBarAppearance()
            navAppearance.configureWithDefaultBackground()
            navAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            navAppearance.shadowColor = UIColor.separator.withAlphaComponent(0.15)
            navAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
            navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

            UINavigationBar.appearance().standardAppearance = navAppearance
            UINavigationBar.appearance().compactAppearance = navAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
            UINavigationBar.appearance().compactScrollEdgeAppearance = navAppearance
        }
        .fullScreenCover(item: $router.presentedModal, onDismiss: hostModel.modalDidDismiss) { modal in
            switch modal {
            case .login:
                NativeLoginView(
                    accountStore: hostModel.accountStore,
                    onClose: router.dismissModal,
                    onLoginSuccess: hostModel.loginCompleted
                )
            case let .qrAuthorization(request):
                QrAuthorizationView(request: request, onClose: router.dismissModal)
            case let .riskControl(request):
                RiskControlView(
                    request: request,
                    onClose: { hostModel.cancelRiskControl($0) },
                    onCompleted: { cookiesJSON in
                        try await hostModel.completeRiskControl(request, cookiesJSON: cookiesJSON)
                    }
                )
                .id(request.requestId)
            }
        }
        .alert(item: $router.riskControlFailure) { failure in
            Alert(
                title: Text("无法打开安全验证"),
                message: Text(failure.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .alert(item: $router.externalURLFailure) { failure in
            Alert(
                title: Text("无法打开链接"),
                message: Text(failure.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .task { await appLock.unlockIfNeeded() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await appLock.unlockIfNeeded() }
            case .inactive, .background:
                hostModel.protectForBackground()
            @unknown default:
                hostModel.protectForBackground()
            }
        }
    }
}

private struct NativeAppLockGate: View {
    @ObservedObject var coordinator: NativeAppLockCoordinator
    let disableUnavailableLock: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.tint)
                Text("知乎++ 已锁定").font(.title2.bold())
                if case let .failed(message) = coordinator.state {
                    Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button {
                    Task { await coordinator.unlockIfNeeded() }
                } label: {
                    Label("解锁", systemImage: "faceid")
                        .frame(minWidth: 140, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.state == .unlocking)
                if !coordinator.settingPresentation.canEnable {
                    Button("关闭不可用的 App 锁", action: disableUnavailableLock)
                        .buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
        .accessibilityIdentifier("native_app_lock_gate")
    }
}

// MARK: - Global Liquid Glass System

public struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let isProminent: Bool
    let ignoreToggle: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nativeContentPresentation) private var presentation

    public init(shape: S, isProminent: Bool = false, ignoreToggle: Bool = false) {
        self.shape = shape
        self.isProminent = isProminent
        self.ignoreToggle = ignoreToggle
    }

    public func body(content: Content) -> some View {
        if !ignoreToggle && !presentation.liquidGlassEnabled {
            content.background {
                shape
                    .fill(Color.nativeSecondarySystemGroupedBackground)
            }
        } else if isProminent {
            content.background {
                ZStack {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(colorScheme == .dark ? 0.95 : 0.90),
                                    Color.accentColor.opacity(colorScheme == .dark ? 0.80 : 0.75)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    shape
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.5 : 0.4),
                                    Color.white.opacity(0.15)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
                .compositingGroup()
            }
        } else if #available(iOS 26.0, *) {
            // Apple iOS 26 原生液态玻璃（Liquid Glass）：按容器形状裁剪的真玻璃材质，
            // 取代旧的 ultraThinMaterial 模拟，与系统导航栏/工具栏保持一致的高斯模糊
            content
                .containerShape(shape)
                .glassEffect(.regular)
        } else {
            content.background {
                ZStack {
                    shape
                        .fill(.ultraThinMaterial)

                    // Lightweight subtle specular rim stroke (Apple standard)
                    shape
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.35 : 0.6),
                                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.15)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            }
        }
    }
}

public extension View {
    func liquidGlass<S: Shape>(in shape: S, isProminent: Bool = false, ignoreToggle: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, isProminent: isProminent, ignoreToggle: ignoreToggle))
    }

    func liquidGlassCapsule(isProminent: Bool = false, ignoreToggle: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: Capsule(), isProminent: isProminent, ignoreToggle: ignoreToggle))
    }

    func liquidGlassCircle(isProminent: Bool = false, ignoreToggle: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: Circle(), isProminent: isProminent, ignoreToggle: ignoreToggle))
    }

    func liquidGlassCard(cornerRadius: CGFloat = 16, isProminent: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), isProminent: isProminent, ignoreToggle: false))
    }

    @ViewBuilder
    func nativeFeedCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(NativeFeedCardModifier(cornerRadius: cornerRadius))
    }

    /// 统一的全 App 信息流卡片容器修饰器：自动包含标准内边距、圆角背景与 List 外部外边距
    func nativeFeedCardItem(cornerRadius: CGFloat = 14) -> some View {
        self
            .nativeFeedCard(cornerRadius: cornerRadius)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// 信息流卡片间距标准：卡片间上/下边距均为 6pt（视觉间距 12pt）。
/// 首页/收藏等页面首卡距顶栏的间距应与卡片间间距保持一致（12pt）。
public enum NativeHomeFeedCardSpacing {
    public static let standardTopInset: CGFloat = 6
    public static let standardBottomInset: CGFloat = 6
    /// 首卡距顶栏间距 = 卡片间间距（6 + 6 = 12pt）
    public static let firstCardTopInset: CGFloat = 12
}

private struct NativeFeedCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.nativeContentPresentation) private var presentation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch presentation.feedCardStyle {
        case .standard:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.nativeSecondarySystemGroupedBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05), lineWidth: 0.5)
                        )
                )
        case .lightLiquidGlass:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.nativeSecondarySystemGroupedBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                        )
                )
        case .plain:
            content
                .padding(.vertical, 10)
        }
    }
}

// MARK: - Standard Ultra-Thin Divider

public struct NativeThinDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(maxWidth: .infinity)
            .frame(height: 0.5)
    }
}

// MARK: - Global Theme Colors

public extension Color {
    /// 基础内容/文章阅读器背景：浅色为 #EDEDED (237, 237, 237)，深色为 #181818 (24, 24, 24)
    static let nativeSystemBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0, alpha: 1.0)
            : UIColor(red: 237.0 / 255.0, green: 237.0 / 255.0, blue: 237.0 / 255.0, alpha: 1.0)
    })

    /// 信息流列表/分组底层背景 (Canvas Background)：浅色为 #EDEDED (237, 237, 237)，深色为 #181818 (24, 24, 24)
    static let nativeSystemGroupedBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0, alpha: 1.0)
            : UIColor(red: 237.0 / 255.0, green: 237.0 / 255.0, blue: 237.0 / 255.0, alpha: 1.0)
    })

    /// 次级背景：浅色为 #FCFCFC (252, 252, 252)，深色为 #282828 (40, 40, 40)
    static let nativeSecondarySystemBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 40.0 / 255.0, green: 40.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0)
            : UIColor(red: 252.0 / 255.0, green: 252.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0)
    })

    /// 信息流卡片容器标准背景 (Card Background)：浅色为 #FCFCFC (252, 252, 252)，深色为 #282828 (40, 40, 40)
    static let nativeSecondarySystemGroupedBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 40.0 / 255.0, green: 40.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0)
            : UIColor(red: 252.0 / 255.0, green: 252.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0)
    })
}

// MARK: - Global Typography System

public enum NativeTypography {
    /// 页面主标题 / 问题大标题 (19pt Bold)
    public static func pageTitle(scale: CGFloat = 1.0) -> Font {
        .system(size: 19 * scale, weight: .bold)
    }

    /// 信息流卡片 / 列表标题 (15.5pt SemiBold - 精致紧凑，比内容略大且加粗)
    public static func feedTitle(scale: CGFloat = 1.0) -> Font {
        .system(size: 15.5 * scale, weight: .semibold)
    }

    /// 正文主体 / 阅读内容 (15.5pt Regular)
    public static func body(scale: CGFloat = 1.0) -> Font {
        .system(size: 15.5 * scale, weight: .regular)
    }

    /// 卡片摘要 (13.5pt Regular - 紧凑舒适)
    public static func feedExcerpt(scale: CGFloat = 1.0) -> Font {
        .system(size: 13.5 * scale, weight: .regular)
    }

    /// 评论正文 (14pt Regular)
    public static func commentBody(scale: CGFloat = 1.0) -> Font {
        .system(size: 14 * scale, weight: .regular)
    }

    /// 用户名 / 作者名称 / 强调标签 (13.5pt Medium - 卡片与评论保持一致)
    public static func authorName(scale: CGFloat = 1.0) -> Font {
        .system(size: 13.5 * scale, weight: .medium)
    }

    /// 次级元数据 / 作者签名 / 辅助说明 (12.5pt Regular)
    public static func footnote(scale: CGFloat = 1.0) -> Font {
        .system(size: 12.5 * scale, weight: .regular)
    }

    /// 标注信息 / 发布时间 / IP 属地 / 互动计数 (11.5pt Regular)
    public static func caption(scale: CGFloat = 1.0) -> Font {
        .system(size: 11.5 * scale, weight: .regular)
    }

    /// 微型标注 / 交互数字角标 (10.5pt MonospacedDigit)
    public static func caption2(scale: CGFloat = 1.0) -> Font {
        .system(size: 10.5 * scale, weight: .regular).monospacedDigit()
    }
}

// MARK: - Reusable Capsule Badge Component

public struct NativeCapsuleBadge<Content: View>: View {
    private let content: Content
    private let foregroundColor: Color

    public init(
        foregroundColor: Color = .primary,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.foregroundColor = foregroundColor
    }

    public var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: Capsule())
    }
}

public extension View {
    func nativeCapsuleBadge(foregroundColor: Color = .primary) -> some View {
        NativeCapsuleBadge(foregroundColor: foregroundColor) {
            self
        }
    }
}

// MARK: - Reusable Loading, Error & Empty Components

public struct NativeLoadingRow: View {
    private let title: String?

    public init(_ title: String? = nil) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 8) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            if let title {
                Text(title)
                    .font(NativeTypography.caption())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title ?? "正在加载")
    }
}

public struct NativeInlineRetry: View {
    private let message: String
    private let retry: () -> Void

    public init(message: String, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(NativeTypography.footnote())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("重试", action: retry)
                .font(NativeTypography.feedTitle())
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

public struct NativeEmptyPlaceholder: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?

    public init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            Text(title)
                .font(NativeTypography.feedTitle())
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(NativeTypography.feedExcerpt())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

public struct NativeUnavailableState: View {
    public let title: String
    public let message: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(title)
                .font(NativeTypography.feedTitle())
                .foregroundStyle(.primary)
            Text(message)
                .font(NativeTypography.feedExcerpt())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(NativeTypography.feedTitle())
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}




