import ImageIO
import Photos
import SwiftUI
import UIKit

struct NativeMediaGallery: View {
    let urls: [URL]
    let animatedURLs: Set<URL>
    let initialIndex: Int
    let accessibilityPrefix: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var selectedIndex: Int
    @State private var pageID: Int?
    @StateObject private var imageStore = NativeMediaImageStore()
    @State private var zoomedIndices: Set<Int> = []
    @State private var dismissOffset: CGFloat = 0
    @State private var message: NativeMediaMessage?
    @State private var isSaving = false

    init(
        urls: [URL],
        initialIndex: Int,
        accessibilityPrefix: String = "media_gallery",
        animatedURLs: Set<URL> = []
    ) {
        self.urls = urls
        self.animatedURLs = animatedURLs
        self.initialIndex = min(max(0, initialIndex), max(0, urls.count - 1))
        self.accessibilityPrefix = accessibilityPrefix
        _selectedIndex = State(initialValue: min(max(0, initialIndex), max(0, urls.count - 1)))
        _pageID = State(initialValue: min(max(0, initialIndex), max(0, urls.count - 1)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(backgroundOpacity(viewportHeight: geometry.size.height))
                    .ignoresSafeArea()

                // Apple 官方分页：ScrollView + LazyHStack + scrollTargetBehavior(.paging) + scrollPosition
                // 惰性渲染仅可见页（解决多图 HStack 全量平铺卡顿）；缩放时 scrollDisabled 锁住翻页
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(urls.indices, id: \.self) { index in
                            NativeZoomableRemoteImage(
                                url: urls[index],
                                animatedURLs: animatedURLs,
                                store: imageStore,
                                onZoomChanged: { isZoomed in
                                    if isZoomed { zoomedIndices.insert(index) } else { zoomedIndices.remove(index) }
                                }
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $pageID)
                .onChange(of: pageID) { _, newValue in
                    if let newValue { selectedIndex = newValue }
                }
                .scrollDisabled(isCurrentImageZoomed)
                .offset(y: dismissOffset)
                .contentShape(Rectangle())
                .simultaneousGesture(verticalDismissGesture(viewportHeight: geometry.size.height))

                if urls.count > 1 {
                    VStack {
                        Spacer()
                        Text("\(selectedIndex + 1) / \(urls.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 54)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .modifier(NativeMediaIndicatorSurface())
                            .padding(.bottom, 18)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { topControls }
        .preferredColorScheme(.dark)
        .alert(item: $message) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了"))
            )
        }
        .accessibilityIdentifier(accessibilityPrefix)
        .onChange(of: selectedIndex) { previous, current in
            NativeMediaGalleryFeedback(action: hapticFeedback)
                .pageDidCommit(from: previous, to: current)
        }
    }

    private var topControls: some View {
        controls
    }

    private var controls: some View {
        HStack(spacing: 10) {
            NativeMediaControlButton(
                systemImage: "xmark",
                accessibilityLabel: "关闭图片",
                action: dismiss.callAsFunction
            )
            .accessibilityIdentifier("\(accessibilityPrefix)_close")

            Spacer()

            Menu {
                if let currentImage {
                    ShareLink(
                        item: Image(uiImage: currentImage),
                        preview: SharePreview("知乎++图片", image: Image(uiImage: currentImage))
                    ) {
                        Label("分享图片文件", systemImage: "square.and.arrow.up")
                    }
                }

                if let currentURL {
                    ShareLink(item: currentURL) {
                        Label("分享图片链接", systemImage: "link")
                    }
                }

                Button(action: copyCurrentImage) {
                    Label("复制图片", systemImage: "doc.on.doc")
                }

                Button(action: saveCurrentImage) {
                    Label(isSaving ? "正在保存" : "保存到照片", systemImage: "square.and.arrow.down")
                }
                .disabled(currentImage == nil || isSaving)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    )
            }
            .foregroundStyle(.white)
            .accessibilityLabel("图片操作")
            .accessibilityIdentifier("\(accessibilityPrefix)_actions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var currentURL: URL? {
        urls.indices.contains(selectedIndex) ? urls[selectedIndex] : nil
    }

    private var currentImage: UIImage? {
        currentURL.flatMap { imageStore.image(for: $0) }
    }

    private var isCurrentImageZoomed: Bool { zoomedIndices.contains(selectedIndex) }

    private func backgroundOpacity(viewportHeight: CGFloat) -> Double {
        let fadeDistance = max(viewportHeight * 0.3, 1)
        return 1 - min(abs(dismissOffset) / fadeDistance, 1) * 0.55
    }

    private func verticalDismissGesture(viewportHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !isCurrentImageZoomed,
                      NativeMediaDismissalPolicy.isVertical(value.translation)
                else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                guard !isCurrentImageZoomed,
                      NativeMediaDismissalPolicy.isVertical(value.translation)
                else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { dismissOffset = 0 }
                    return
                }
                if NativeMediaDismissalPolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    viewportHeight: viewportHeight
                ) {
                    NativeMediaGalleryFeedback(action: hapticFeedback)
                        .verticalDismissDidCommit(true)
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { dismissOffset = 0 }
                }
            }
    }

    private func copyCurrentImage() {
        if let currentImage {
            UIPasteboard.general.image = currentImage
            message = NativeMediaMessage(text: "已复制图片")
        } else if let currentURL {
            UIPasteboard.general.url = currentURL
            message = NativeMediaMessage(text: "图片尚未加载完成，已复制图片链接")
        } else {
            message = NativeMediaMessage(text: "当前图片不可用")
        }
    }

    private func saveCurrentImage() {
        guard let currentImage, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await NativePhotoLibrary.save(currentImage)
                message = NativeMediaMessage(text: "已保存到照片")
            } catch {
                message = NativeMediaMessage(text: "无法保存图片，请检查照片权限后重试")
            }
        }
    }
}

private struct NativeMediaControlButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .foregroundStyle(.white)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NativeMediaIndicatorSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.liquidGlassCapsule()
    }
}

private struct NativeZoomableRemoteImage: View {
    let url: URL
    let animatedURLs: Set<URL>
    @ObservedObject var store: NativeMediaImageStore
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        Group {
            if NativeRemoteMediaPolicy.isAnimatedImage(url) || animatedURLs.contains(url) {
                NativeAnimatedRemoteImage(url: url, contentMode: .fit)
            } else if let image = store.image(for: url) {
                // Apple Photos 原生缩放：UIScrollView zoom（锚点跟随手指/回弹/惯性/双击），
                // zoomScale==1 时禁用内层滚动放行外层分页，放大后接管平移
                NativeZoomingScrollView(image: image, onZoomChanged: onZoomChanged)
            } else if store.didFail(url) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("图片加载失败")
                    Button("重试") { Task { await store.load(url) } }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) { await store.load(url) }
        .onDisappear { onZoomChanged(false) }
    }
}

/// Apple Photos 风格原生缩容器：包装 UIScrollView，viewForZooming 返回内容 view，
/// 缩放/平移/回弹/双击均由系统原生处理，不依赖 SwiftUI 自定义手势。
private struct NativeZoomingScrollView: UIViewRepresentable {
    let image: UIImage
    let onZoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear
        // zoomScale==1 时不拦截任何手势，横向滑动交由外层分页 ScrollView
        scrollView.isScrollEnabled = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(NativeZoomingScrollView.Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.image = image

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.image !== image {
            coordinator.image = image
            coordinator.imageView?.image = image
            scrollView.setZoomScale(1, animated: false)
            scrollView.isScrollEnabled = false
            coordinator.onZoomChanged(false)
        }
        coordinator.layoutContent()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChanged: onZoomChanged)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let onZoomChanged: (Bool) -> Void
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var image: UIImage?

        init(onZoomChanged: @escaping (Bool) -> Void) {
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.isScrollEnabled = zoomed
            onZoomChanged(zoomed)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let zoomed = scale > 1.01
            scrollView.isScrollEnabled = zoomed
            onZoomChanged(zoomed)
        }

        func scrollViewDidLayoutSubviews(_ scrollView: UIScrollView) {
            layoutContent()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                scrollView.isScrollEnabled = false
                onZoomChanged(false)
            } else {
                let point = gesture.location(in: scrollView)
                let newScale = min(scrollView.maximumZoomScale, 2.5)
                let rect = zoomRect(for: scrollView, scale: newScale, center: point)
                scrollView.zoom(to: rect, animated: true)
                onZoomChanged(true)
            }
        }

        private func zoomRect(for scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            return CGRect(origin: origin, size: size)
        }

        func layoutContent() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }
            if imageView.frame.size != boundsSize || scrollView.contentSize != boundsSize {
                imageView.frame = CGRect(origin: .zero, size: boundsSize)
                scrollView.contentSize = boundsSize
            }
            centerImage()
        }

        private func centerImage() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame
            if frameToCenter.size.width < boundsSize.width {
                frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
            } else {
                frameToCenter.origin.x = 0
            }
            if frameToCenter.size.height < boundsSize.height {
                frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
            } else {
                frameToCenter.origin.y = 0
            }
            imageView.frame = frameToCenter
        }
    }
}

enum NativeRemoteMediaPolicy {
    static func isAnimatedImage(_ url: URL) -> Bool {
        ["gif", "webp", "apng"].contains(url.pathExtension.lowercased())
    }
}

struct NativeAnimatedRemoteImage: View {
    let url: URL
    let contentMode: ContentMode

    @StateObject private var loader = NativeAnimatedImageLoader()

    init(url: URL, contentMode: ContentMode = .fit) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image = loader.image {
                NativeAnimatedUIImageView(image: image, contentMode: contentMode)
                    .aspectRatio(
                        image.size.height > 0 ? image.size.width / image.size.height : 1,
                        contentMode: contentMode
                    )
            } else if loader.didFail {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    ProgressView()
                }
            }
        }
        .task(id: url) { await loader.load(url) }
        .accessibilityLabel("动图")
    }
}

private struct NativeAnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        guard uiView.image !== image else { return }
        uiView.stopAnimating()
        uiView.image = image
        uiView.startAnimating()
    }
}

@MainActor
private final class NativeAnimatedImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var didFail = false
    private var loadedURL: URL?

    func load(_ url: URL) async {
        guard loadedURL != url || image == nil else { return }
        loadedURL = url
        image = nil
        didFail = false
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= 40 * 1_024 * 1_024,
                  let decoded = NativeAnimatedImageDecoder.decode(data)
            else { throw URLError(.cannotDecodeContentData) }
            guard loadedURL == url else { return }
            image = decoded
        } catch is CancellationError {
        } catch {
            guard loadedURL == url else { return }
            didFail = true
        }
    }
}

enum NativeAnimatedImageDecoder {
    private static let maximumFrameCount = 60
    private static let maximumTotalPixels = 24_000_000
    private static let maximumPixelSize = 1_600

    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return UIImage(data: data) }

        let stride = max(1, Int(ceil(Double(frameCount) / Double(maximumFrameCount))))
        let decodedFrameCount = Int(ceil(Double(frameCount) / Double(stride)))
        let memoryBoundPixelSize = Int(
            sqrt(Double(maximumTotalPixels) / Double(max(decodedFrameCount, 1)))
        )
        let thumbnailPixelSize = min(maximumPixelSize, max(memoryBoundPixelSize, 320))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        var frames: [UIImage] = []
        frames.reserveCapacity(min(frameCount, maximumFrameCount))
        var duration = 0.0

        for index in 0 ..< frameCount {
            duration += frameDuration(source: source, index: index)
            guard index % stride == 0,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options)
            else { continue }
            frames.append(UIImage(cgImage: cgImage))
        }

        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let value = unclamped ?? clamped ?? 0.1
        return value < 0.02 ? 0.1 : value
    }
}

@MainActor
struct NativeMediaGalleryFeedback {
    let action: NativeHapticFeedbackAction

    func pageDidCommit(from previousIndex: Int, to selectedIndex: Int) {
        guard previousIndex != selectedIndex else { return }
        action(.selection)
    }

    func verticalDismissDidCommit(_ committed: Bool) {
        guard committed else { return }
        action(.dismiss)
    }
}

struct NativeMediaDismissalPolicy {
    static func isVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width) * 1.15
    }

    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        viewportHeight: CGFloat
    ) -> Bool {
        guard isVertical(translation) else { return false }
        let threshold = max(viewportHeight * 0.16, 72)
        return abs(translation.height) >= threshold ||
            abs(predictedEndTranslation.height) >= threshold * 1.35
    }
}

@MainActor
private final class NativeMediaImageStore: ObservableObject {
    private struct LoadOperation {
        let id = UUID()
        let task: Task<Data, Error>
    }

    @Published private var images: [URL: UIImage] = [:]
    @Published private var failedURLs: Set<URL> = []
    private var operations: [URL: LoadOperation] = [:]

    func image(for url: URL) -> UIImage? { images[url] }
    func didFail(_ url: URL) -> Bool { failedURLs.contains(url) }

    func load(_ url: URL) async {
        guard images[url] == nil else { return }
        let operation: LoadOperation
        if let existing = operations[url] {
            operation = existing
        } else {
            failedURLs.remove(url)
            operation = LoadOperation(task: Task {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode)
                else { throw URLError(.badServerResponse) }
                return data
            })
            operations[url] = operation
        }
        do {
            let data = try await operation.task.value
            let decodedImage = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            guard let decodedImage else { throw URLError(.cannotDecodeContentData) }
            images[url] = decodedImage
            failedURLs.remove(url)
        } catch is CancellationError {
            // A second visible page may still await the shared operation.
        } catch {
            failedURLs.insert(url)
        }
        if operations[url]?.id == operation.id { operations.removeValue(forKey: url) }
    }
}

private enum NativePhotoLibrary {
    static func save(_ image: UIImage) async throws {
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw NativePhotoLibraryError.permissionDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { succeeded, error in
                if let error { continuation.resume(throwing: error) }
                else if succeeded { continuation.resume() }
                else { continuation.resume(throwing: NativePhotoLibraryError.saveFailed) }
            }
        }
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private enum NativePhotoLibraryError: Error {
    case permissionDenied
    case saveFailed
}

private struct NativeMediaMessage: Identifiable {
    let id = UUID()
    let text: String
}
