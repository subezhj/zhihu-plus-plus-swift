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

            let scrollEdgeAppearance = UINavigationBarAppearance()
            scrollEdgeAppearance.configureWithTransparentBackground()
            scrollEdgeAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
            scrollEdgeAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

            UINavigationBar.appearance().standardAppearance = navAppearance
            UINavigationBar.appearance().compactAppearance = navAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
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
        content
            .background {
                if !ignoreToggle && !presentation.liquidGlassEnabled {
                    shape
                        .fill(Color.nativeSecondarySystemGroupedBackground)
                } else if isProminent {
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
                } else {
                    ZStack {
                        shape
                            .fill(Color.nativeSecondarySystemGroupedBackground)

                        shape
                            .fill(.ultraThinMaterial.opacity(0.85))

                        // Lightweight subtle specular rim stroke (Apple standard)
                        shape
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.3 : 0.5),
                                        Color.white.opacity(colorScheme == .dark ? 0.05 : 0.1)
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
                )
        case .lightLiquidGlass:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.nativeSecondarySystemGroupedBackground)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.85))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.25 : 0.45),
                                        Color.white.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    }
                )
        case .plain:
            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.vertical, 10)
                NativeThinDivider()
            }
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
    static let nativeSystemBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 25.0 / 255.0, green: 25.0 / 255.0, blue: 25.0 / 255.0, alpha: 1.0)
            : .systemBackground
    })

    static let nativeSystemGroupedBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 25.0 / 255.0, green: 25.0 / 255.0, blue: 25.0 / 255.0, alpha: 1.0)
            : .systemGroupedBackground
    })

    static let nativeSecondarySystemBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 40.0 / 255.0, green: 40.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0)
            : .secondarySystemBackground
    })

    static let nativeSecondarySystemGroupedBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 40.0 / 255.0, green: 40.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0)
            : .secondarySystemGroupedBackground
    })
}
