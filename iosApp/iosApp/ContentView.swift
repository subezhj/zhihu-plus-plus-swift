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
            if #available(iOS 16.0, *) {
                NativeAppShell(
                    hostModel: hostModel,
                    isAppUnlocked: appLock.state == .unlocked
                )
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "iphone.gen3").font(.largeTitle)
                    Text("需要更新 iOS").font(.title2.bold())
                    Text("纯 Swift 版本需要 iOS 16 或更高版本。")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            if appLock.state != .unlocked {
                NativeAppLockGate(coordinator: appLock, disableUnavailableLock: { hostModel.setAppLock(false) })
            }
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

    @Environment(\.colorScheme) private var colorScheme

    public init(shape: S, isProminent: Bool = false) {
        self.shape = shape
        self.isProminent = isProminent
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if isProminent {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(colorScheme == .dark ? 0.95 : 0.88),
                                    Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.75)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            shape
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(colorScheme == .dark ? 0.5 : 0.35),
                                            Color.white.opacity(0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.8
                                )
                        )
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.18),
                            radius: 8,
                            x: 0,
                            y: 3
                        )
                } else {
                    ZStack {
                        shape
                            .fill(.ultraThinMaterial)

                        // Real-time specular sheen
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.28 : 0.6),
                                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        // 3D Glass rim edge
                        shape
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.65 : 0.85),
                                        Color.primary.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12),
                        radius: 6,
                        x: 0,
                        y: 2.5
                    )
                }
            }
    }
}

public extension View {
    func liquidGlass<S: Shape>(in shape: S, isProminent: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, isProminent: isProminent))
    }

    func liquidGlassCapsule(isProminent: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: Capsule(), isProminent: isProminent))
    }

    func liquidGlassCircle(isProminent: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: Circle(), isProminent: isProminent))
    }
}
