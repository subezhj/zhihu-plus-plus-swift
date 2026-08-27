import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class CommentHostModel: ObservableObject, Identifiable {
    let id: CommentSessionID
    let store: CommentSessionStore
    @Published private(set) var personModel: PersonHostModel?

    private let accountStore: AccountJSONStore
    private let onPersonNavigate: (PersonNavigationIntent) -> Void
    let onNavigate: (QANavigationIntent) -> Void

    init(
        route: CommentThreadRouteDTO,
        accountStore: AccountJSONStore,
        repository: CommentRepository? = nil,
        onPersonNavigate: @escaping (PersonNavigationIntent) -> Void,
        onNavigate: @escaping (QANavigationIntent) -> Void = { _ in }
    ) {
        let sessionID = CommentSessionID()
        id = sessionID
        self.accountStore = accountStore
        self.onPersonNavigate = onPersonNavigate
        self.onNavigate = onNavigate
        var openPerson: ((PersonRoutePayload) -> Void)?
        store = CommentSessionStore(
            route: route,
            repository: repository ?? URLSessionCommentRepository(
                client: ZhihuAPIClient(accountStore: accountStore)
            ),
            sessionID: sessionID,
            onOpenPerson: { payload in openPerson?(payload) }
        )
        openPerson = { [weak self] payload in self?.presentPerson(payload) }
    }

    deinit {
        MainActor.assumeIsolated {
            dispose()
        }
    }

    func dispose() {
        personModel?.dispose()
        personModel = nil
        store.dispose()
    }

    func personBindingChanged(isPresented: Bool) {
        guard !isPresented else { return }
        personModel?.dispose()
        personModel = nil
    }

    private func presentPerson(_ payload: PersonRoutePayload) {
        personModel?.dispose()
        personModel = PersonHostModel(
            routeEntry: PersonRouteEntry(payload: payload),
            accountStore: accountStore,
            onNavigate: onPersonNavigate
        )
    }
}


struct CommentNavigationPage: View {
    @ObservedObject var model: CommentHostModel

    var body: some View {
        CommentThreadContainer(
            store: model.store,
            personModel: model.personModel,
            personBindingChanged: model.personBindingChanged,
            onNavigate: model.onNavigate
        )
        .accessibilityIdentifier("comment_navigation_page")
    }
}


private enum CommentThreadActiveDestination: Hashable {
    case person
    case replies(String)
}

private struct CommentThreadContainer: View {
    @ObservedObject var store: CommentSessionStore
    let personModel: PersonHostModel?
    let personBindingChanged: (Bool) -> Void
    let onNavigate: (QANavigationIntent) -> Void

    var body: some View {
        CommentLevelView(store: store, level: .root, close: nil)
            .background {
                if case let .replies(rootCommentID) = store.activeLevel {
                    NavigationLink(
                        destination: CommentLevelView(store: store, level: .replies(rootCommentID: rootCommentID), close: nil),
                        isActive: Binding(
                            get: {
                                if case .replies = store.activeLevel { return true }
                                return false
                            },
                            set: { isPresented in
                                if !isPresented {
                                    store.dismissReplies()
                                }
                            }
                        )
                    ) {
                        EmptyView()
                    }
                    .hidden()
                }
            }
            .alert(
                item: Binding(
                    get: { store.message },
                    set: { store.messageBindingChanged(to: $0) }
                )
            ) { message in
                Alert(
                    title: Text("操作未完成"),
                    message: Text(message.text),
                    dismissButton: .default(Text("知道了"))
                )
            }
            .environment(\.openURL, OpenURLAction { url in
                handleCommentURL(url)
            })
            // 用户主页弹窗（方案 B）：弹窗内点内容先收起弹窗，再由底层导航栈全屏打开详情
            .personCoverSheet(item: personCoverBinding, onNavigate: onPersonNavigate)
            .task { store.start() }
    }

    private func handleCommentURL(_ url: URL) -> OpenURLAction.Result {
        if let link = QABodyLinkResolver.resolve(url) {
            switch link {
            case .external(let externalURL):
                return .systemAction(externalURL)
            default:
                onNavigate(.link(link))
                return .handled
            }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return .discarded
        }
        return .systemAction(url)
    }

    private var personCoverBinding: Binding<PersonHostModel?> {
        Binding(
            get: { personModel },
            set: { value in
                if value == nil {
                    personBindingChanged(false)
                }
            }
        )
    }
}

private struct CommentSheetPresentationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.nativeSystemGroupedBackground)
    }
}


private struct CommentLevelView: View {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey
    let close: (() -> Void)?
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var scrollView: UIScrollView?
    @State private var posterDocument: NativeContentPosterDocument?

    var body: some View {
        List {
            if level == .root {
                sortControl
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.nativeSystemGroupedBackground)
            }
            pageContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.defaultMinListRowHeight, 1)
        .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
        .background(CommentScrollViewAccessor { scrollView = $0 })
        .onChange(of: store.scrollToStartLevel) { target in
            guard target == level else { return }
            DispatchQueue.main.async {
                guard let scrollView else { return }
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                    animated: true
                )
                store.consumeScrollToStart(for: level)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CommentComposerBar(store: store, level: level)
        }
        .navigationTitle(level == .root ? "评论" : "回复")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(level == .root ? "关闭评论" : "关闭回复")
                    .accessibilityIdentifier(level == .root ? "comment_close" : "comment_reply_close")
                }
            }
        }
        .accessibilityIdentifier(level == .root ? "comment_root" : "comment_direct_replies")
        .sheet(item: $posterDocument) { document in
            NativeContentPosterShareView(document: document)
        }
        .fullScreenCover(
            item: Binding(
                get: { store.galleryDestination },
                set: { store.galleryBindingChanged(to: $0) }
            )
        ) { destination in
            NativeMediaGallery(
                urls: destination.urls,
                initialIndex: destination.initialIndex,
                accessibilityPrefix: "comment_media",
                animatedURLs: destination.animatedURLs
            )
        }
    }

    private var coordinateSpaceName: String {
        switch level {
        case .root: return "comment-list-root"
        case let .replies(rootCommentID): return "comment-list-replies-\(rootCommentID)"
        }
    }

    private var sortControl: some View {
        Picker("评论排序", selection: Binding(
            get: { store.rootSort },
            set: store.changeSort
        )) {
            ForEach(CommentSortDTO.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("comment_sort")
    }

    @ViewBuilder
    private var pageContent: some View {
        let page = store.pages[level] ?? store.activePage
        switch page.initialLoad {
        case .idle where page.items.isEmpty, .loading where page.items.isEmpty:
            HStack { Spacer(); ProgressView("正在加载评论"); Spacer() }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemGroupedBackground)
        case let .failed(message) where page.items.isEmpty:
            CommentUnavailableView(
                title: "评论加载失败",
                message: message,
                actionTitle: "重试"
            ) { store.retryInitial(level: level) }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.nativeSystemGroupedBackground)
        case .loaded where page.items.isEmpty:
            CommentUnavailableView(
                title: level == .root ? "暂无评论" : "暂无回复",
                message: level == .root ? "成为第一个发表评论的人" : "这条评论还没有回复",
                actionTitle: nil,
                action: nil
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.nativeSystemGroupedBackground)
        default:
            // 独立回复页（level == .replies）：顶部展示主评论（完整渲染、不显示回复入口），底部为回复列表
            if case .replies = level, let rootComment = store.rootComment(for: level) {
                CommentRow(
                    store: store,
                    comment: rootComment,
                    interactionLevel: .root,
                    showsReplyEntry: false,
                    onShare: { presentSharePoster(for: rootComment) }
                )
                    .id(rootComment.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.nativeSystemBackground)

                // “回复”说明：标明下方均为针对主评论的回复
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("回复")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("· 以下 \(page.items.count) 条均针对上面的主评论")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.secondary)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemGroupedBackground)
            }
            ForEach(page.items) { comment in
                CommentRow(
                    store: store,
                    comment: comment,
                    interactionLevel: level,
                    onShare: { presentSharePoster(for: comment) }
                )
                    .id(comment.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            store.beginReply(to: comment.id, level: level)
                        } label: {
                            Label("回复", systemImage: "arrowshape.turn.up.left.fill")
                        }
                        .tint(Color.accentColor)
                        .accessibilityLabel("回复 @\(comment.author.displayName)")
                        .accessibilityIdentifier("comment_swipe_reply_\(comment.id)")

                        Button {
                            presentSharePoster(for: comment)
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.indigo)
                        .accessibilityLabel("分享 \(comment.author.displayName) 的评论")
                        .accessibilityIdentifier("comment_swipe_share_\(comment.id)")
                    }
                    .onAppear { store.loadNextIfNeeded(after: comment.id, level: level) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.nativeSystemBackground)
            }
            pageFooter(page)
        }
    }

    private func presentSharePoster(for comment: CommentDTO) {
        hapticFeedback(.commit)
        let context = store.route.shareContext ?? store.route.subject.fallbackShareContext
        var blocks: [NativeContentPosterBlock] = []
        if let excerpt = context.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            blocks.append(.text("正文摘要：\(excerpt)", style: .caption))
            blocks.append(.divider)
        }

        let commentText = CommentPlainText.value(from: comment.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !commentText.isEmpty {
            blocks.append(.text(commentText, style: .body))
        }
        blocks.append(contentsOf: comment.media.map {
            .image($0.url, caption: $0.kind == .sticker ? "表情" : nil)
        })

        let replyContext = comment.replyToAuthor.map { "回复 @\($0.displayName)" } ?? ""
        posterDocument = NativeContentPosterDocument(
            title: context.title,
            authorName: comment.author.displayName,
            authorHeadline: replyContext,
            authorAvatarURL: comment.author.avatarURL,
            sourceURL: context.sourceURL,
            metadata: "\(CommentDateFormatter.string(seconds: comment.createdTimeSeconds)) · \(comment.likeCount) 赞",
            blocks: blocks
        )
    }

    @ViewBuilder
    private func pageFooter(_ page: CommentPageState) -> some View {
        switch page.nextPage {
        case .loading:
            HStack { Spacer(); ProgressView("正在加载更多"); Spacer() }
                .font(.caption)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemGroupedBackground)
        case let .failed(message):
            CommentUnavailableView(title: "未能加载更多", message: message, actionTitle: "重试") {
                store.retryNext(level: level)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.nativeSystemGroupedBackground)
        case .idle where page.isEnd && !page.items.isEmpty:
            Text(level == .root ? "已显示全部评论" : "已显示全部回复")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemGroupedBackground)
        default:
            EmptyView()
        }
    }
}

private struct CommentRow: View {
    @ObservedObject var store: CommentSessionStore
    let comment: CommentDTO
    let interactionLevel: CommentLevelKey?
    let showsReplyEntry: Bool
    let onShare: () -> Void
    @Environment(\.nativeContentPresentation) private var presentation
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    init(
        store: CommentSessionStore,
        comment: CommentDTO,
        interactionLevel: CommentLevelKey? = nil,
        showsReplyEntry: Bool = true,
        onShare: @escaping () -> Void = {}
    ) {
        self.store = store
        self.comment = comment
        self.interactionLevel = interactionLevel
        self.showsReplyEntry = showsReplyEntry
        self.onShare = onShare
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Button { store.openAuthor(commentID: comment.id) } label: {
                        AsyncImage(url: comment.author.avatarURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开 \(comment.author.displayName) 的主页")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Button(comment.author.displayName) { store.openAuthor(commentID: comment.id) }
                                .buttonStyle(.plain)
                                .font(NativeTypography.authorName(scale: presentation.fontScale))
                                .foregroundStyle(.primary)

                            if let reply = comment.replyToAuthor {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrowtriangle.right.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.tertiary)
                                    Text(reply.displayName)
                                        .font(NativeTypography.footnote(scale: presentation.fontScale))
                                        .foregroundStyle(.secondary)
                                }
                                .onTapGesture {
                                    store.openAuthor(commentID: comment.id, replyToAuthor: true)
                                }
                            }
                        }

                        HStack(spacing: 4) {
                            Text(CommentDateFormatter.string(seconds: comment.createdTimeSeconds))
                                .font(NativeTypography.caption(scale: presentation.fontScale))
                                .foregroundStyle(.secondary)

                            if let ipLocation = comment.ipLocation, !ipLocation.isEmpty {
                                Text("·")
                                    .font(NativeTypography.caption(scale: presentation.fontScale))
                                    .foregroundStyle(.tertiary)
                                Text(ipLocation.hasPrefix("IP 属地") ? ipLocation : "IP 属地\(ipLocation)")
                                    .font(NativeTypography.caption(scale: presentation.fontScale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    // 右上角极简点赞
                    Button {
                        hapticFeedback(.selection)
                        store.toggleLike(commentID: comment.id, level: interactionLevel)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: comment.isLiked ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(comment.isLiked ? Color.red : Color.secondary)
                            if comment.likeCount > 0 {
                                Text("\(comment.likeCount)")
                                    .font(NativeTypography.caption2(scale: presentation.fontScale))
                                    .foregroundStyle(comment.isLiked ? Color.red : Color.secondary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.pages[interactionLevel ?? store.activeLevel]?.activeLikeMutation != nil)
                    .accessibilityLabel("点赞评论")
                }

                // 评论正文：UITextView 支持长按选择文本/复制/翻译；链接点击走系统链接处理
                CommentRichText(html: comment.contentHTML)
                    .padding(.leading, 42)

                // 评论图片
                if !comment.media.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(comment.media) { media in
                                Button { store.openMedia(commentID: comment.id, mediaID: media.id) } label: {
                                    Group {
                                        if media.kind == .sticker ||
                                            media.kind == .animatedImage ||
                                            NativeRemoteMediaPolicy.isAnimatedImage(media.url) {
                                            // 动态表情/动图：等比完整显示（不被 110x80 裁剪），限最大尺寸
                                            NativeAnimatedRemoteImage(url: media.url, contentMode: .fit)
                                                .frame(maxWidth: 120, maxHeight: 120)
                                        } else {
                                            AsyncImage(url: media.url) { phase in
                                                if case let .success(image) = phase {
                                                    image.resizable().scaledToFill()
                                                } else {
                                                    ZStack {
                                                        Color.secondary.opacity(0.12)
                                                        ProgressView()
                                                    }
                                                }
                                            }
                                            .frame(width: 110, height: 80)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(media.kind == .sticker ? "查看评论动态表情" : "查看评论图片")
                            }
                        }
                    }
                    .padding(.leading, 42)
                }

                // 内嵌子回复入口 (仅在主楼且回复数 > 0 时展示，进入独立回复页)
                if interactionLevel == .root, showsReplyEntry, comment.childCommentCount > 0 {
                    inlineRepliesSection
                        .padding(.leading, 42)
                }
            }
            .padding(.vertical, 10)

            // 分割线紧贴内容底部，作为外层容器的末尾子视图，避免 overlay 在行高变化时出现偏移
            NativeThinDivider()
        }
        // 长按正文会优先弹出系统文本选择（复制/翻译/查找）；长按非文本区域弹出快捷菜单（回复/复制评论/分享）
        .contextMenu {
            Button(action: beginReply) {
                Label("回复 @\(comment.author.displayName)", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                UIPasteboard.general.string = CommentPlainText.value(from: comment.contentHTML)
            } label: {
                Label("复制评论", systemImage: "doc.on.doc")
            }
            Button(action: onShare) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("comment_context_share_\(comment.id)")
        }
        .accessibilityIdentifier("comment_row_\(comment.id)")
    }

    @ViewBuilder
    private var inlineRepliesSection: some View {
        // 打开独立回复页（顶部主评论 + 底部回复列表，类似知乎官方方案），
        // 彻底避免行内展开造成的行高抖动、上下扩开偏移与内容裁剪。
        Button {
            store.openReplies(rootCommentID: comment.id)
        } label: {
            HStack(spacing: 5) {
                Text("查看 \(comment.childCommentCount) 条回复")
                    .font(.system(size: 11.5 * presentation.fontScale, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func beginReply() {
        store.beginReply(to: comment.id, level: interactionLevel)
    }
}

private struct CommentComposerBar: View {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey
    @State private var showsEmojiPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoError: String?
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        Group {
            if store.composerPresentation.isActive(for: level) {
                activeComposer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                collapsedComposer
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.composerPresentation.isActive(for: level))
        .background(CommentComposerBackground())
        .onChange(of: store.composerPresentation) { presentation in
            isDraftFocused = presentation.isActive(for: level)
        }
        .onChange(of: selectedPhotoItem) { newItem in
            guard let newItem else { return }
            Task {
                do {
                    if let data = try await newItem.loadTransferable(type: Data.self) {
                        await MainActor.run { store.setDraftImage(data) }
                    }
                } catch {
                    await MainActor.run { photoError = error.localizedDescription }
                }
            }
        }
        .onAppear {
            isDraftFocused = store.composerPresentation.isActive(for: level)
        }
        .onDisappear { isDraftFocused = false }
        .sheet(isPresented: $showsEmojiPicker) {
            CommentEmojiPicker { emoji in
                store.appendEmoji(emoji.placeholder)
                showsEmojiPicker = false
            }
        }
        .alert("无法选择图片", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("知道了", role: .cancel) { photoError = nil }
        } message: {
            Text(photoError ?? "请稍后重试")
        }
    }

    private var collapsedComposer: some View {
        Button {
            store.beginComment(level: level)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(level == .root ? "写评论，发表你的看法…" : "回复这条评论…")
                    .font(NativeTypography.commentBody())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .liquidGlassCapsule(isProminent: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("comment_composer_open")
    }

    private var activeComposer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(store.activeReplyTargetName.map { "回复 @\($0)" } ?? (level == .root ? "发表评论" : "发表回复"))
                        .font(NativeTypography.feedTitle())
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button {
                    dismissComposer()
                } label: {
                    Text("取消")
                        .font(NativeTypography.caption())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if let imageData = store.draft.imageData, let image = UIImage(data: imageData) {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("待发送图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("移除", role: .destructive) { store.setDraftImage(nil) }
                        .font(.caption)
                }
                .padding(.horizontal, 16)
            }

            HStack(alignment: .center, spacing: 8) {
                Button { showsEmojiPicker = true } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("选择表情")
                .accessibilityIdentifier("comment_emoji_picker")

                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("选择图片")
                .accessibilityIdentifier("comment_photo_picker")

                CommentDraftField(store: store, isFocused: $isDraftFocused)
                    .textFieldStyle(.plain)
                    .font(NativeTypography.commentBody())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .liquidGlassCapsule(isProminent: false)

                Button {
                    if case .failed = store.draft.submissionState {
                        store.retrySubmission()
                    } else {
                        store.submitDraft()
                    }
                } label: {
                    if case .submitting = store.draft.submissionState {
                        ProgressView().frame(width: 38, height: 38)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                }
                .disabled(
                    (store.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        store.draft.imageData == nil) ||
                        store.draft.submissionState.isSubmitting
                )
                .accessibilityLabel("发送评论")
                .accessibilityIdentifier("comment_submit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func dismissComposer() {
        isDraftFocused = false
        store.dismissComposer(for: level)
    }
}

private struct CommentEmojiPicker: View {
    let onSelect: (CommentEmoji) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(CommentEmojiCatalog.entries) { emoji in
                        Button { onSelect(emoji) } label: {
                            VStack(spacing: 3) {
                                Text(emoji.symbol).font(.title2)
                                Text(emoji.placeholder.dropFirst().dropLast())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("插入\(emoji.placeholder)")
                    }
                }
                .padding(16)
            }
            .navigationTitle("选择表情")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .modifier(CommentEmojiPresentationModifier())
    }
}

private struct CommentEmojiPresentationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationDetents([.height(340), .medium])
            .presentationDragIndicator(.visible)
    }
}

private enum CommentPhotoPickerError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "无法读取所选图片" }
}

private struct CommentComposerBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea(edges: .bottom)
    }
}

private struct CommentRichText: UIViewRepresentable {
    let html: String
    var font: Font? = nil
    var basePointSize: CGFloat = 14
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SelectionTextView {
        let textView = SelectionTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        // 链接样式走系统默认（tint 强调色 + 下划线）
        textView.isAccessibilityElement = true
        return textView
    }

    func updateUIView(_ textView: SelectionTextView, context: Context) {
        let pointSize = basePointSize * contentPresentation.fontScale
        let lineSpacing = contentPresentation.extraLineSpacing(for: pointSize)
        textView.attributedText = CommentAttributedText.attributed(
            from: html,
            fallbackPointSize: pointSize,
            lineSpacing: lineSpacing
        )
        textView.font = UIFont.systemFont(ofSize: pointSize)
        textView.invalidateIntrinsicContentSize()
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
            // OpenURLAction.callAsFunction 返回 Void：直接触发应用内/系统链接处理，
            // 返回 false 表示由我们接管（内链跳转、外链系统打开）
            openURL(url)
            return false
        }
    }
}

/// 禁用滚动的 UITextView：高度随内容自适应，长按保持系统标准文本选择（复制/翻译/查找）。
/// 高度缓存在 measuredHeight，仅在宽度变化时于 layoutSubviews 中重新测量——
/// 避免在 intrinsicContentSize 内调用 layoutIfNeeded（布局期间强制布局会递归/死锁导致选中拖动或 pop 时闪退）。
private final class SelectionTextView: UITextView {
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
        remeasureIfWidthChanged()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    private func remeasureIfWidthChanged() {
        let width = bounds.width
        guard width > 1, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        let height = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = max(height, 18)
            invalidateIntrinsicContentSize()
        }
    }

    /// 内容更新后调用：重置宽度标记，使下次 layoutSubviews 重新测量
    func markNeedsRemeasure() {
        lastLayoutWidth = 0
        measuredHeight = 18
        setNeedsLayout()
    }
}

private enum CommentAttributedText {
    /// 直接缓存最终构建的 NSAttributedString（UTF8 外的 [NSString] key），供 UITextView 渲染。
    private final class Box {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    private static let cache = NSCache<NSString, Box>()

    /// 构建 UITextView 可用的富文本（显式字体/行距/链接），
    /// 使长按评论正文可以通过系统标准交互选择文本、复制、翻译。
    static func attributed(
        from html: String,
        fallbackPointSize: CGFloat,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let key = html as NSString
        if let box = cache.object(forKey: key) { return box.value }

        let source = CommentHTMLMediaParser.project(html).textHTML
        let blocks = QARichContentParser.blocks(from: source)
        let result = NSMutableAttributedString()
        for block in blocks {
            if result.length > 0 {
                appendNewline(to: result, pointSize: fallbackPointSize, lineSpacing: lineSpacing)
            }
            switch block {
            case let .paragraph(_, runs), let .heading(_, _, runs), let .quote(_, runs), let .segment(_, _, runs):
                appendRuns(runs, to: result, pointSize: fallbackPointSize, lineSpacing: lineSpacing)
            case let .list(_, kind, items):
                appendList(
                    QAListGroup(kind: kind, items: items),
                    depth: 0,
                    to: result,
                    pointSize: fallbackPointSize,
                    lineSpacing: lineSpacing
                )
            case let .code(_, _, text), let .formula(_, text):
                result.append(NSAttributedString(
                    string: text,
                    attributes: [.font: UIFont.monospacedSystemFont(ofSize: fallbackPointSize, weight: .regular)]
                ))
            case .image, .video, .divider:
                break
            }
        }
        let final: NSAttributedString
        if result.length == 0 {
            let text = CommentEmojiCatalog.renderedText(QARichContentParser.plainText(source))
            final = NSAttributedString(
                string: text,
                attributes: [.font: UIFont.systemFont(ofSize: fallbackPointSize)]
            )
        } else {
            final = result
        }
        cache.setObject(Box(final), forKey: key)
        return final
    }

    private static func paragraphStyle(_ lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    private static func font(for style: QAInlineStyle, pointSize: CGFloat) -> UIFont {
        if style.contains(.code) {
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        let bold = style.contains(.strong)
        let italic = style.contains(.emphasis)
        if bold, italic {
            let descriptor = UIFontDescriptor()
                .withSymbolicTraits([.traitBold, .traitItalic]) ?? UIFontDescriptor()
            return UIFont(descriptor: descriptor, size: pointSize)
        }
        if bold { return .boldSystemFont(ofSize: pointSize) }
        if italic { return .italicSystemFont(ofSize: pointSize) }
        return .systemFont(ofSize: pointSize)
    }

    private static func appendNewline(to result: NSMutableAttributedString, pointSize: CGFloat, lineSpacing: CGFloat) {
        result.append(NSAttributedString(
            string: "\n",
            attributes: [.font: UIFont.systemFont(ofSize: pointSize), .paragraphStyle: paragraphStyle(lineSpacing)]
        ))
    }

    private static func appendRuns(
        _ runs: [QAInlineRun],
        to result: NSMutableAttributedString,
        pointSize: CGFloat,
        lineSpacing: CGFloat
    ) {
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: run.style, pointSize: pointSize),
                .paragraphStyle: paragraphStyle(lineSpacing),
                .foregroundColor: UIColor.label
            ]
            if run.style.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let destination = run.link, let url = QABodyLinkResolver.url(destination) {
                attributes[.link] = url
            }
            result.append(NSAttributedString(
                string: CommentEmojiCatalog.renderedText(run.text),
                attributes: attributes
            ))
        }
    }

    private static func appendList(
        _ list: QAListGroup,
        depth: Int,
        to result: NSMutableAttributedString,
        pointSize: CGFloat,
        lineSpacing: CGFloat
    ) {
        for (index, item) in list.items.enumerated() {
            if result.length > 0 {
                appendNewline(to: result, pointSize: pointSize, lineSpacing: lineSpacing)
            }
            let number = item.ordinal ?? list.startIndex + index
            let marker = list.kind == .ordered ? "\(number). " : "• "
            let prefix = String(repeating: "  ", count: depth) + marker
            let prefixAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: pointSize),
                .paragraphStyle: paragraphStyle(lineSpacing)
            ]
            result.append(NSAttributedString(string: prefix, attributes: prefixAttributes))
            appendRuns(item.runs, to: result, pointSize: pointSize, lineSpacing: lineSpacing)
            for nestedList in item.nestedLists {
                appendList(nestedList, depth: depth + 1, to: result, pointSize: pointSize, lineSpacing: lineSpacing)
            }
        }
    }

    static func isKnownInternalZhihuURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }
}

private struct CommentDraftField: View {
    @ObservedObject var store: CommentSessionStore
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField("发表评论", text: draftBinding, axis: .vertical)
            .lineLimit(1...5)
            .focused(isFocused)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { store.draft.text }, set: store.setDraftText)
    }
}

private enum CommentPlainText {
    static func value(from html: String) -> String {
        CommentEmojiCatalog.renderedText(QARichContentParser.plainText(html))
    }
}

private extension CommentSubmissionState {
    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

private enum CommentDateFormatter {
    // 性能：DateFormatter 创建昂贵，评论每行渲染都会调用，必须静态缓存复用
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func string(seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return monthDayFormatter.string(from: date)
        }
        return fullFormatter.string(from: date)
    }
}

private extension CommentSubjectDTO {
    var fallbackShareContext: CommentShareContextDTO {
        switch self {
        case let .answer(id):
            return CommentShareContextDTO(
                title: "回答 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://www.zhihu.com/answer/\(id)")!
            )
        case let .article(id):
            return CommentShareContextDTO(
                title: "文章 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://zhuanlan.zhihu.com/p/\(id)")!
            )
        case let .question(id):
            return CommentShareContextDTO(
                title: "问题 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://www.zhihu.com/question/\(id)")!
            )
        case let .pin(id):
            return CommentShareContextDTO(
                title: "想法 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://www.zhihu.com/pin/\(id)")!
            )
        case let .segment(contentID, contentTypeRaw, _):
            let title: String
            let sourceURL: URL
            switch contentTypeRaw {
            case "answer":
                title = "回答 #\(contentID)"
                sourceURL = URL(string: "https://www.zhihu.com/answer/\(contentID)")!
            case "article":
                title = "文章 #\(contentID)"
                sourceURL = URL(string: "https://zhuanlan.zhihu.com/p/\(contentID)")!
            case "question":
                title = "问题 #\(contentID)"
                sourceURL = URL(string: "https://www.zhihu.com/question/\(contentID)")!
            case "pin":
                title = "想法 #\(contentID)"
                sourceURL = URL(string: "https://www.zhihu.com/pin/\(contentID)")!
            default:
                title = "知乎内容"
                sourceURL = URL(string: "https://www.zhihu.com")!
            }
            return CommentShareContextDTO(title: title, excerpt: nil, sourceURL: sourceURL)
        }
    }
}

private struct CommentUnavailableView: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right").font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct CommentScrollViewAccessor: UIViewRepresentable {
    let resolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.resolve = resolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.resolve = resolve
        uiView.findScrollView()
    }

    final class ProbeView: UIView {
        var resolve: ((UIScrollView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findScrollView()
        }

        func findScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var candidate = superview
                while let view = candidate {
                    if let scrollView = view as? UIScrollView {
                        resolve?(scrollView)
                        return
                    }
                    candidate = view.superview
                }
                resolve?(nil)
            }
        }
    }
}

