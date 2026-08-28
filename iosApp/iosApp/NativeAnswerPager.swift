import SwiftUI
import UIKit

struct QAReadingPreferences: Equatable {
    let pinAnswerDate: Bool

    init(defaults: UserDefaults = .standard) {
        pinAnswerDate = defaults.bool(forKey: "pinAnswerDate")
    }
}

struct NativeAnswerPager: View {
    @ObservedObject var store: AnswerPagerStore
    let preferences: QAReadingPreferences
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    var body: some View {
        AnswerPagerPages(
            pager: store,
            preferences: preferences,
            hapticFeedback: hapticFeedback,
            onNavigate: onNavigate
        )
        .task { await store.prepare() }
    }
}

/// 纯 SwiftUI 横向分页（替代 UIKit `UIPageViewController`）：
/// `TabView(.page)` 原生支持左右滑动切换相邻回答，页面惰性预载相邻页；
/// 系统左缘右滑返回由 NavigationStack 与 `NativeAnswerInteractivePopBridge` 协作保证。
private struct AnswerPagerPages: View {
    @ObservedObject var pager: AnswerPagerStore
    let preferences: QAReadingPreferences
    let hapticFeedback: NativeHapticFeedbackAction
    let onNavigate: (QANavigationIntent) -> Void
    @State private var posterDocument: NativeContentPosterDocument?
    @State private var selectionValue: Int64

    init(
        pager: AnswerPagerStore,
        preferences: QAReadingPreferences,
        hapticFeedback: NativeHapticFeedbackAction,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        self.pager = pager
        self.preferences = preferences
        self.hapticFeedback = hapticFeedback
        self.onNavigate = onNavigate
        _selectionValue = State(initialValue: pager.current.id)
    }

    /// 当前可翻页集合：前一条 + 当前 + 后一条（相邻页由 store 维护）
    private var pages: [AnswerStore] {
        var result: [AnswerStore] = []
        if let previous = pager.previous { result.append(previous) }
        result.append(pager.current)
        if let next = pager.next { result.append(next) }
        return result
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectionValue) {
                ForEach(pages) { answerStore in
                    AnswerNativeView(
                        store: answerStore,
                        pinAnswerDate: preferences.pinAnswerDate,
                        onNavigate: onNavigate
                    )
                    .tag(answerStore.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if let error = pager.switchError {
                Button {
                    Task { await pager.retrySwitch() }
                } label: {
                    Label("下一个回答加载失败，点此重试", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(error)
                .padding(.top, 8)
            } else if let notice = pager.boundaryNotice {
                Text(notice)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityAddTraits(.isStaticText)
                    .padding(.top, 8)
            }
        }
        // 统一深浅色底色（nativeSystemBackground：浅 #EDEDED / 深 #181818）
        .background(Color.nativeSystemBackground.ignoresSafeArea())
        .navigationTitle(pager.current.initialRoute.kind == .answer ? "回答" : "文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let content = pager.current.content {
                    Menu {
                        Button {
                            UIPasteboard.general.url = content.sourceURL
                        } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                        }
                        Button {
                            posterDocument = NativeContentPosterDocument(answer: content)
                        } label: {
                            Label("分享内容海报", systemImage: "photo.on.rectangle.angled")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .onChange(of: selectionValue) { _, newID in
            guard newID != pager.current.id else { return }
            // 异步提交：等分页滑动动画完成后再切换/加载，避免动画期间 body 重算掉帧
            Task { @MainActor in
                let committed = pager.commitDisplayedAnswer(answerID: newID)
                if committed {
                    hapticFeedback(.selection)
                    await pager.prepareDisplayedAnswer()
                }
            }
        }
        .sheet(item: $posterDocument) { document in
            NativeContentPosterShareView(document: document)
        }
        .background(NativeAnswerInteractivePopBridge())
    }
}

struct QAMarkdownTemporaryFile: Equatable {
    let fileURL: URL
    let directoryURL: URL

    func cleanup(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directoryURL)
    }
}

enum QAMarkdownTemporaryFileStore {
    static func write(
        contents: String,
        suggestedFileName: String,
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> QAMarkdownTemporaryFile {
        let directory = baseDirectory.appendingPathComponent(
            "zhihu-plus-plus-markdown-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        do {
            let rawName = URL(fileURLWithPath: suggestedFileName).lastPathComponent
            let fileName = rawName.lowercased().hasSuffix(".md") ? rawName : "\(rawName).md"
            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            try Data(contents.utf8).write(to: fileURL, options: .atomic)
            return QAMarkdownTemporaryFile(fileURL: fileURL, directoryURL: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }
}

private struct QAMarkdownSharePresentation: Identifiable {
    let id = UUID()
    let activityItem: Any
    let temporaryFile: QAMarkdownTemporaryFile?

    init(document: QAMarkdownDocument) throws {
        switch QAMarkdownSharePayloadBuilder.payload(for: document) {
        case let .text(markdown):
            activityItem = markdown
            temporaryFile = nil
        case let .file(contents, suggestedFileName):
            let file = try QAMarkdownTemporaryFileStore.write(
                contents: contents,
                suggestedFileName: suggestedFileName
            )
            activityItem = file.fileURL
            temporaryFile = file
        }
    }

    func cleanup() {
        temporaryFile?.cleanup()
    }
}

/// 确保 NavigationStack 的系统左缘返回手势可用（处理 UIKit 容器嵌套时的 pop 手势仲裁）
private struct NativeAnswerInteractivePopBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NativeAnswerInteractivePopObserverController {
        NativeAnswerInteractivePopObserverController()
    }

    func updateUIViewController(
        _ uiViewController: NativeAnswerInteractivePopObserverController,
        context: Context
    ) {}
}

final class NativeAnswerInteractivePopObserverController: UIViewController,
    UIGestureRecognizerDelegate
{
    private weak var observedGesture: UIGestureRecognizer?
    private weak var previousDelegate: UIGestureRecognizerDelegate?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let navigationController,
              navigationController.viewControllers.count > 1,
              let gesture = navigationController.interactivePopGestureRecognizer
        else { return }
        observeInteractivePopGesture(gesture)
    }

    func observeInteractivePopGesture(_ gesture: UIGestureRecognizer) {
        guard observedGesture == nil,
              gesture.delegate !== self
        else { return }
        observedGesture = gesture
        previousDelegate = gesture.delegate
        gesture.delegate = self
        gesture.isEnabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObservingInteractivePopGesture()
    }

    func stopObservingInteractivePopGesture() {
        if observedGesture?.delegate === self {
            observedGesture?.delegate = previousDelegate
        }
        observedGesture = nil
        previousDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard navigationController?.viewControllers.count ?? 0 > 1 else { return false }
        guard let previousDelegate,
              previousDelegate !== self
        else { return true }
        return previousDelegate.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }
}

enum AnswerPagerLayoutDirection: Equatable {
    case leftToRight
    case rightToLeft
}

enum AnswerPagerHorizontalGestureOwner: Equatable {
    case pager
    case systemBack
    case undecided
}

struct AnswerPagerGestureArbitrationPolicy {
    static let horizontalIntentRatio: CGFloat = 1.15
    static let systemLeadingEdgeWidth: CGFloat = 44

    static func isLeadingToTrailing(
        horizontalMovement: CGFloat,
        layoutDirection: AnswerPagerLayoutDirection
    ) -> Bool {
        switch layoutDirection {
        case .leftToRight: horizontalMovement > 0
        case .rightToLeft: horizontalMovement < 0
        }
    }

    static func owner(
        translation: CGPoint,
        velocity: CGPoint,
        startLocationX: CGFloat,
        containerWidth: CGFloat,
        hasPreviousAnswer: Bool,
        canNavigateBack: Bool,
        layoutDirection: AnswerPagerLayoutDirection
    ) -> AnswerPagerHorizontalGestureOwner {
        let movement = abs(velocity.x) > 0.5 || abs(velocity.y) > 0.5
            ? velocity
            : translation
        guard abs(movement.x) > abs(movement.y) * horizontalIntentRatio else {
            return .undecided
        }
        let isLeadingToTrailing = isLeadingToTrailing(
            horizontalMovement: movement.x,
            layoutDirection: layoutDirection
        )
        guard isLeadingToTrailing else { return .pager }
        if canNavigateBack,
           startsInSystemLeadingEdge(
               locationX: startLocationX,
               containerWidth: containerWidth,
               layoutDirection: layoutDirection
           ) {
            return .systemBack
        }
        guard hasPreviousAnswer else {
            return canNavigateBack ? .systemBack : .pager
        }
        return .pager
    }

    static func startsInSystemLeadingEdge(
        locationX: CGFloat,
        containerWidth: CGFloat,
        layoutDirection: AnswerPagerLayoutDirection
    ) -> Bool {
        guard containerWidth > 0 else { return false }
        let clampedLocation = min(max(locationX, 0), containerWidth)
        switch layoutDirection {
        case .leftToRight:
            return clampedLocation <= systemLeadingEdgeWidth
        case .rightToLeft:
            return clampedLocation >= containerWidth - systemLeadingEdgeWidth
        }
    }
}

@MainActor
struct NativeAnswerPagerFeedback {
    let action: NativeHapticFeedbackAction

    func pageDidCommit(_ committed: Bool) {
        guard committed else { return }
        action(.selection)
    }

    func forwardBoundaryDidPublish(_ published: Bool) {
        guard published else { return }
        action(.navigationBoundary)
    }
}