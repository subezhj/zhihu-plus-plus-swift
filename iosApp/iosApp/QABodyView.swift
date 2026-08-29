import AVKit
import SwiftUI

struct QABodyView: View {
    let blocks: [QABodyBlock]
    let segmentSubject: CommentSubjectDTO?
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeContentPresentation) private var presentation
    @ScaledMetric(relativeTo: .body) private var bodyPointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .callout) private var calloutPointSize: CGFloat = 16

    init(
        blocks: [QABodyBlock],
        segmentSubject: CommentSubjectDTO? = nil,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        self.blocks = blocks
        self.segmentSubject = segmentSubject
        self.onNavigate = onNavigate
    }

    private var galleryImages: [QAImageDTO] {
        blocks.compactMap { block in
            guard case let .image(image) = block else { return nil }
            return image
        }
    }

    private var galleryURLs: [URL] { galleryImages.map(\.url) }

    var body: some View {
        // 连续正文段落合并到单个 UITextView：支持跨段长按选择复制
        VStack(alignment: .leading, spacing: presentation.blockSpacing()) {
            groupedBlocks
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = QABodyLinkResolver.resolve(url) else { return .discarded }
            onNavigate(.link(destination))
            return .handled
        })
    }

    private enum GroupedBlock {
        case paragraphGroup([QAInlineRun])
        case block(QABodyBlock)
    }

    /// 把连续正文段落合并为一组（跨段选择复制），遇到非段落块断开
    private var groupedItems: [GroupedBlock] {
        var paragraphs: [QAInlineRun] = []
        var items: [GroupedBlock] = []
        for block in blocks {
            if case let .paragraph(_, runs) = block {
                if !paragraphs.isEmpty { paragraphs.append(QAInlineRun(text: "\n")) }
                paragraphs.append(contentsOf: runs)
            } else {
                if !paragraphs.isEmpty {
                    items.append(.paragraphGroup(paragraphs))
                    paragraphs = []
                }
                items.append(.block(block))
            }
        }
        if !paragraphs.isEmpty { items.append(.paragraphGroup(paragraphs)) }
        return items
    }

    @ViewBuilder
    private var groupedBlocks: some View {
        ForEach(groupedItems.indices, id: \.self) { index in
            switch groupedItems[index] {
            case let .paragraphGroup(runs):
                QARichTextView(
                    runs: runs,
                    pointSize: bodyPointSize * presentation.fontScale,
                    lineSpacing: bodyLineSpacing
                )
            case let .block(block):
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: QABodyBlock) -> some View {
        switch block {
        case let .paragraph(_, runs):
            QARichTextView(
                runs: runs,
                pointSize: bodyPointSize * presentation.fontScale,
                lineSpacing: bodyLineSpacing
            )
        case let .heading(_, level, runs):
            QARichTextView(
                runs: runs,
                pointSize: headingPointSize(level),
                lineSpacing: bodyLineSpacing,
                isBold: true
            )
            .padding(.top, level <= 2 ? 8 : 2)
        case let .quote(_, runs):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 3.5)
                QARichTextView(
                    runs: runs,
                    pointSize: bodyPointSize * presentation.fontScale,
                    lineSpacing: bodyLineSpacing,
                    foregroundColor: .secondaryLabel
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        case let .list(_, kind, items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(listRows(kind: kind, items: items)) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.marker)
                            .font(bodyFont)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        QARichTextView(
                            runs: row.runs,
                            pointSize: bodyPointSize * presentation.fontScale,
                            lineSpacing: bodyLineSpacing
                        )
                    }
                    .padding(.leading, CGFloat(row.depth) * 20)
                }
            }
        case let .code(_, language, text):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                QARichTextView(
                    runs: [QAInlineRun(text: text, style: [.code])],
                    pointSize: calloutPointSize * presentation.fontScale,
                    lineSpacing: 2
                )
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        case let .formula(_, latex):
            QAKaTeXFormulaView(
                latex: latex,
                pointSize: bodyPointSize * presentation.fontScale
            )
        case let .image(image):
            Button {
                let index = galleryImages.firstIndex { $0.id == image.id } ?? 0
                onNavigate(.images(urls: galleryURLs, initialIndex: index))
            } label: {
                VStack(spacing: 7) {
                    QABodyRemoteImage(image: image)
                    if let caption = image.caption ?? image.altText, !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(image.altText ?? image.caption ?? "查看图片")
        case let .segment(_, segmentID, runs):
            HStack(alignment: .top, spacing: 7) {
                QARichTextView(
                    runs: runs,
                    pointSize: bodyPointSize * presentation.fontScale,
                    lineSpacing: bodyLineSpacing
                )
                if let segmentSubject,
                   let subject = segmentCommentSubject(segmentSubject, segmentID: segmentID) {
                    Button {
                        onNavigate(.segmentComments(CommentThreadRouteDTO(subject: subject)))
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看本段评论")
                }
            }
        case let .video(_, video):
            let route = videoRoute(video)
            QANativeVideoPlayer(
                video: video,
                contentID: route.contentID,
                contentType: route.contentType,
                openExternal: { url in onNavigate(.link(.external(url))) }
            )
        case .divider:
            NativeThinDivider()
        }
    }

    private var bodyFont: Font {
        .system(size: bodyPointSize * presentation.fontScale)
    }

    private var bodyLineSpacing: CGFloat {
        presentation.extraLineSpacing(for: bodyPointSize * presentation.fontScale)
    }

    private func headingFont(_ level: Int) -> Font {
        let scale = presentation.fontScale
        switch level {
        case 1: return .system(size: 22 * scale, weight: .bold)
        case 2: return .system(size: 20 * scale, weight: .bold)
        case 3: return .system(size: 17 * scale, weight: .semibold)
        default: return .system(size: bodyPointSize * scale, weight: .semibold)
        }
    }

    private func headingPointSize(_ level: Int) -> CGFloat {
        let scale = presentation.fontScale
        switch level {
        case 1: return 22 * scale
        case 2: return 20 * scale
        case 3: return 17 * scale
        default: return bodyPointSize * scale
        }
    }

    private func listRows(kind: QAListKind, items: [QAListItem]) -> [QAListDisplayRow] {
        flattenList(QAListGroup(kind: kind, items: items), depth: 0)
    }

    private func flattenList(_ group: QAListGroup, depth: Int) -> [QAListDisplayRow] {
        group.items.enumerated().flatMap { index, item in
            let number = item.ordinal ?? group.startIndex + index
            let marker = group.kind == .ordered ? "\(number)." : "•"
            let row = QAListDisplayRow(
                id: item.id,
                marker: marker,
                depth: depth,
                runs: item.runs
            )
            return [row] + item.nestedLists.flatMap {
                flattenList($0, depth: depth + 1)
            }
        }
    }

    private func segmentCommentSubject(
        _ subject: CommentSubjectDTO,
        segmentID: String
    ) -> CommentSubjectDTO? {
        switch subject {
        case let .answer(id): return .segment(contentID: String(id), contentTypeRaw: "answer", segmentID: segmentID)
        case let .article(id): return .segment(contentID: String(id), contentTypeRaw: "article", segmentID: segmentID)
        case let .question(id): return .segment(contentID: String(id), contentTypeRaw: "question", segmentID: segmentID)
        case let .pin(id): return .segment(contentID: String(id), contentTypeRaw: "pin", segmentID: segmentID)
        case .segment: return nil
        }
    }

    private func videoRoute(_ video: QAAttachmentVideoDTO) -> NativeVideoRouteDTO {
        let contentID: Int64
        let contentType: NativeVideoContentType
        switch segmentSubject {
        case let .answer(id):
            contentID = id
            contentType = .answer
        case let .article(id):
            contentID = id
            contentType = .article
        case let .question(id):
            contentID = id
            contentType = .question
        case let .pin(id):
            contentID = id
            contentType = .zvideo
        case .segment, .none:
            contentID = video.videoID
            contentType = .zvideo
        }
        return NativeVideoRouteDTO(
            contentID: contentID,
            videoID: video.videoID,
            contentType: contentType,
            thumbnailURL: video.thumbnailURL,
            playbackURL: video.playbackURL,
            webURL: video.destinationURL
        )
    }
}

private struct QAListDisplayRow: Identifiable {
    let id: UUID
    let marker: String
    let depth: Int
    let runs: [QAInlineRun]
}

private final class NativeBodyImageMemoryCache {
    static let shared = NativeBodyImageMemoryCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 60 * 1024 * 1024 // 60 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

private enum NativeImageDownsampler {
    static func downsample(data: Data, maxPixelSize: CGFloat = 1600) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: downsampledImage)
    }
}

@MainActor
private final class NativeStaticImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var didFail = false
    private var loadedURL: URL?

    func load(_ url: URL) async {
        if let cached = NativeBodyImageMemoryCache.shared.image(for: url) {
            self.image = cached
            self.didFail = false
            return
        }
        guard loadedURL != url || image == nil else { return }
        loadedURL = url
        image = nil
        didFail = false

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let decoded = await Task.detached(priority: .userInitiated, operation: {
                      NativeImageDownsampler.downsample(data: data)
                  }).value
            else { throw URLError(.cannotDecodeContentData) }

            guard loadedURL == url else { return }
            NativeBodyImageMemoryCache.shared.store(decoded, for: url)
            self.image = decoded
        } catch is CancellationError {
        } catch {
            guard loadedURL == url else { return }
            self.didFail = true
        }
    }
}

private struct QABodyRemoteImage: View {
    let image: QAImageDTO
    @StateObject private var staticLoader = NativeStaticImageLoader()

    var body: some View {
        Group {
            if let dimensions = image.dimensions {
                content
                    .aspectRatio(CGFloat(dimensions.aspectRatio), contentMode: .fit)
            } else {
                content
                    .frame(minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if NativeRemoteMediaPolicy.isAnimatedImage(image.url) {
            NativeAnimatedRemoteImage(url: image.url)
        } else {
            Group {
                if let uiImage = staticLoader.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                } else if staticLoader.didFail {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("图片加载失败").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack {
                        Color(uiColor: .secondarySystemBackground).opacity(0.3)
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: image.url) {
                await staticLoader.load(image.url)
            }
        }
    }
}

enum QARichTextFormatter {
    /// 生成富文本 AttributedString。
    /// 注意：粗体/斜体用显式 font（同字号变粗/变斜），
    /// 不要用 `inlinePresentationIntent = .stronglyEmphasized`——SwiftUI 的
    /// `Text(AttributedString)` 渲染该语义时会同时放大字号，导致“变粗还变大”。
    static func attributed(_ runs: [QAInlineRun], pointSize: CGFloat) -> AttributedString {
        runs.reduce(into: AttributedString()) { value, run in
            var part = AttributedString(run.text)
            if run.style.contains(.code) {
                part.font = .system(size: pointSize).monospaced()
                part.backgroundColor = Color(uiColor: .secondarySystemBackground)
            } else {
                let bold = run.style.contains(.strong)
                let italic = run.style.contains(.emphasis)
                if bold, italic {
                    part.font = .system(size: pointSize).bold().italic()
                } else if bold {
                    part.font = .system(size: pointSize).bold()
                } else if italic {
                    part.font = .system(size: pointSize).italic()
                }
            }
            if run.style.contains(.strikethrough) { part.strikethroughStyle = .single }
            if let link = run.link {
                part.link = QABodyLinkResolver.url(link)
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
            }
            value.append(part)
        }
    }
}

/// 回答/文章正文的富文本 UITextView：长按走系统标准文本选择（选择/复制/翻译/查找），
/// 前景色使用 label 与作者名对齐（深浅色自适应），链接可点击。
private struct QARichTextView: UIViewRepresentable {
    let runs: [QAInlineRun]
    var pointSize: CGFloat
    var lineSpacing: CGFloat
    var isBold: Bool = false
    var foregroundColor: UIColor = .label

    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> QASelectionTextView {
        let textView = QASelectionTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.textColor = foregroundColor
        textView.isAccessibilityElement = true
        return textView
    }

    func updateUIView(_ textView: QASelectionTextView, context: Context) {
        textView.attributedText = Self.attributed(
            runs: runs,
            pointSize: pointSize,
            lineSpacing: lineSpacing,
            isBold: isBold,
            foregroundColor: foregroundColor
        )
        textView.font = UIFont.systemFont(ofSize: pointSize, weight: isBold ? .semibold : .regular)
        textView.markNeedsRemeasure()
        context.coordinator.openURL = openURL
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction = OpenURLAction { url in .systemAction(url) }

        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            openURL(url)
            return false
        }
    }

    private static func attributed(
        runs: [QAInlineRun],
        pointSize: CGFloat,
        lineSpacing: CGFloat,
        isBold: Bool,
        foregroundColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: run.style, pointSize: pointSize, baseBold: isBold),
                .paragraphStyle: paragraphStyle(lineSpacing),
                .foregroundColor: foregroundColor
            ]
            if run.style.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.style.contains(.code) {
                attributes[.backgroundColor] = UIColor.secondarySystemBackground
            }
            if let link = run.link, let url = QABodyLinkResolver.url(link) {
                attributes[.link] = url
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private static func font(for style: QAInlineStyle, pointSize: CGFloat, baseBold: Bool) -> UIFont {
        if style.contains(.code) {
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        let bold = baseBold || style.contains(.strong)
        let italic = style.contains(.emphasis)
        if bold, italic {
            let descriptor = UIFontDescriptor().withSymbolicTraits([.traitBold, .traitItalic]) ?? UIFontDescriptor()
            return UIFont(descriptor: descriptor, size: pointSize)
        }
        if bold { return .boldSystemFont(ofSize: pointSize) }
        if italic { return .italicSystemFont(ofSize: pointSize) }
        return .systemFont(ofSize: pointSize)
    }

    private static func paragraphStyle(_ lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }
}

/// 高度随内容自适应的只读 UITextView（长按系统文本选择）
/// 高度缓存在 measuredHeight，仅宽度变化时测量，避免 intrinsicContentSize 内强制布局导致选中/pop 闪退
private final class QASelectionTextView: UITextView {
    private var lastLayoutWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 18

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textContainer?.widthTracksTextView = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 1, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        let height = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = max(height, 18)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    /// 内容更新后调用：重置宽度标记，使下次 layoutSubviews 重新测量
    func markNeedsRemeasure() {
        lastLayoutWidth = 0
        measuredHeight = 18
        setNeedsLayout()
        // 同步立即测量：内容刚替换时先用当前宽度算好高度，
        // 避免 List 行复用瞬间“旧高度承载新内容”造成的短暂文本重合
        let width = bounds.width > 1 ? bounds.width : 320
        let height = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        measuredHeight = max(height, 18)
        invalidateIntrinsicContentSize()
    }
}

private final class FullScreenOrientationPlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    private var orientationButton: UIButton?
    private var isLandscape = false

    override func viewDidLoad() {
        super.viewDidLoad()
        self.delegate = self
        setupOrientationButton()
    }

    private func setupOrientationButton() {
        guard let overlay = contentOverlayView else { return }

        // Safari-style liquid glass capsule button
        var config = UIButton.Configuration.plain()
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.image = UIImage(systemName: "iphone.landscape", withConfiguration: imageConfig)
        config.imagePadding = 6
        config.imagePlacement = .leading
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)

        var titleAttr = AttributedString("横屏")
        titleAttr.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
        config.attributedTitle = titleAttr

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false

        // UltraThinMaterial effect background
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.isUserInteractionEnabled = false
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = 17
        blurView.layer.masksToBounds = true
        blurView.layer.borderWidth = 0.5
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor

        button.insertSubview(blurView, at: 0)
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: button.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowRadius = 5

        button.addTarget(self, action: #selector(handleOrientationToggle), for: .touchUpInside)
        button.isHidden = true // Only visible when in full screen

        overlay.addSubview(button)
        // 悬浮在系统底部控制条上方（-60），不与右下角倍速控件抢占底部条同一水平，避免视觉拥挤
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            button.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -60),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])

        self.orientationButton = button
    }

    @objc private func handleOrientationToggle() {
        isLandscape.toggle()
        updateButtonAppearance()

        guard let windowScene = view.window?.windowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let targetOrientation: UIInterfaceOrientationMask = isLandscape ? .landscapeRight : .portrait
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetOrientation)
        windowScene.requestGeometryUpdate(geometryPreferences) { _ in }
    }

    private func updateButtonAppearance() {
        guard let button = orientationButton else { return }
        var config = button.configuration ?? UIButton.Configuration.plain()
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.image = UIImage(systemName: isLandscape ? "iphone.portrait" : "iphone.landscape", withConfiguration: imageConfig)
        var titleAttr = AttributedString(isLandscape ? "竖屏" : "横屏")
        titleAttr.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
        config.attributedTitle = titleAttr
        button.configuration = config
    }

    // MARK: - AVPlayerViewControllerDelegate
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        orientationButton?.isHidden = false
        isLandscape = false
        updateButtonAppearance()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        orientationButton?.isHidden = true
        if isLandscape {
            isLandscape = false
            guard let windowScene = view.window?.windowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
            windowScene.requestGeometryUpdate(geometryPreferences) { _ in }
        }
    }
}

private struct NativeInlineVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsPlaybackControls: Bool = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = FullScreenOrientationPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.allowsPictureInPicturePlayback = true
        controller.videoGravity = .resizeAspect
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

private struct QANativeVideoPlayer: View {
    let video: QAAttachmentVideoDTO
    var contentID: Int64 = 0
    var contentType: NativeVideoContentType = .answer
    var openExternal: ((URL) -> Void)? = nil
    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                NativeInlineVideoPlayer(player: player)
            } else if let thumbnailURL = video.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Color.black
                            .overlay(Image(systemName: "video.slash").foregroundStyle(.secondary))
                    case .empty:
                        Color.black
                    @unknown default:
                        Color.black
                    }
                }
                .overlay {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Button {
                            Task { await playInline() }
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.white, .black.opacity(0.4))
                                .shadow(color: .black.opacity(0.35), radius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Button {
                        Task { await playInline() }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.7), in: Capsule())
                    Button("重试") { Task { await playInline() } }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task {
            if let playbackURL = video.playbackURL {
                player = AVPlayer(url: playbackURL)
            }
        }
        .onDisappear { player?.pause() }
        .accessibilityLabel("视频播放器")
        // 长按视频：复制视频链接 / 在浏览器打开
        .contextMenu {
            if let linkURL = video.destinationURL ?? video.playbackURL {
                Button {
                    UIPasteboard.general.string = linkURL.absoluteString
                } label: {
                    Label("复制视频链接", systemImage: "link")
                }
                if let openExternal {
                    Button {
                        openExternal(linkURL)
                    } label: {
                        Label("在浏览器中打开", systemImage: "safari")
                    }
                }
            }
        }
    }

    @MainActor
    private func playInline() async {
        Self.configureAudioSession()
        if let playbackURL = video.playbackURL {
            let player = AVPlayer(url: playbackURL)
            self.player = player
            player.play()
            return
        }
        guard video.videoID > 0 else {
            errorMessage = "视频信息无效"
            return
        }
        isLoading = true
        errorMessage = nil
        let route = NativeVideoRouteDTO(
            contentID: contentID,
            videoID: video.videoID,
            contentType: contentType,
            title: "视频",
            thumbnailURL: video.thumbnailURL,
            playbackURL: nil,
            webURL: nil
        )
        let repository = URLSessionNativeVideoRepository()
        do {
            let resolvedURL = try await repository.resolvePlaybackURL(for: route)
            guard !Task.isCancelled else { return }
            let player = AVPlayer(url: resolvedURL)
            self.player = player
            isLoading = false
            player.play()
        } catch {
            guard !error.isNativeRequestCancellation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Audio session activation best effort
        }
    }
}


private struct QAVideoAttachmentView: View {
    let video: QAAttachmentVideoDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                AsyncImage(url: video.thumbnailURL) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    case .failure:
                        Color(uiColor: .secondarySystemBackground)
                            .overlay(Image(systemName: "video.slash").foregroundStyle(.secondary))
                    case .empty:
                        Color(uiColor: .secondarySystemBackground)
                            .overlay(ProgressView())
                    @unknown default:
                        Color(uiColor: .secondarySystemBackground)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white, .black.opacity(0.34))
                    .shadow(radius: 8)
                VStack {
                    Spacer()
                    HStack {
                        Label("视频", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(10)
                    .background(.black.opacity(0.38))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放视频")
    }
}

struct NativeVideoPlayerScreen: View {
    let route: NativeVideoRouteDTO
    let repository: NativeVideoRepository
    let openExternal: (URL) -> Void

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isLandscape = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Color.black
                if let player {
                    NativeInlineVideoPlayer(player: player, showsPlaybackControls: true)
                } else if let thumbnailURL = route.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFit()
                        case .failure:
                            Color.black
                        case .empty:
                            ProgressView().tint(.white)
                        @unknown default:
                            Color.black
                        }
                    }
                }
                if isLoading {
                    ProgressView("正在载入视频")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                    Text("视频加载失败")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                    if let webURL = route.webURL {
                        Button("在浏览器中打开") { openExternal(webURL) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleOrientation) {
                    Image(systemName: isLandscape ? "iphone.portrait" : "iphone.landscape")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel(isLandscape ? "切换竖屏" : "切换横屏")
            }
        }
        .task(id: route) { await load() }
        .onDisappear {
            player?.pause()
            requestDeviceOrientation(.portrait)
        }
    }

    private func toggleOrientation() {
        isLandscape.toggle()
        requestDeviceOrientation(isLandscape ? .landscapeRight : .portrait)
    }

    private func requestDeviceOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        windowScene.requestGeometryUpdate(geometryPreferences) { _ in }
    }

    @MainActor
    private func load() async {
        QANativeVideoPlayer.configureAudioSession()
        player?.pause()
        player = nil
        errorMessage = nil
        isLoading = true
        do {
            let playbackURL = try await repository.resolvePlaybackURL(for: route)
            guard !Task.isCancelled else { return }
            let player = AVPlayer(url: playbackURL)
            self.player = player
            isLoading = false
            player.play()
        } catch {
            guard !error.isNativeRequestCancellation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

enum QABodyLinkResolver {
    static func url(_ destination: QALinkDestination) -> URL? {
        switch destination {
        case let .answer(id): return URL(string: "zhihu://answers/\(id)")
        case let .article(id): return URL(string: "zhihu://articles/\(id)")
        case let .question(id): return URL(string: "zhihu://questions/\(id)")
        case let .pin(id): return URL(string: "zhihu://pin/\(id)")
        case let .topic(id): return URL(string: "zhihu://topics/\(id)")
        case let .person(token): return URL(string: "zhihu://people/\(token)")
        case let .external(url): return url
        }
    }

    static func resolve(_ url: URL) -> QALinkDestination? {
        if let destination = NativeContentDestinationResolver.resolve(url.absoluteString) {
            switch destination {
            case let .article(id, kind):
                return kind == .answer ? .answer(id) : .article(id)
            case let .question(id):
                return .question(id)
            case let .person(_, token, _):
                return .person(urlToken: token)
            case let .pin(id):
                return .pin(id)
            case let .topic(id):
                return .topic(id)
            case .special, .column, .search:
                return .external(url)
            case let .external(externalURL):
                return .external(externalURL)
            }
        }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return .external(url)
    }
}
