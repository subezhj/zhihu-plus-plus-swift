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

    init(
        route: CommentThreadRouteDTO,
        accountStore: AccountJSONStore,
        repository: CommentRepository? = nil,
        onPersonNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        let sessionID = CommentSessionID()
        id = sessionID
        self.accountStore = accountStore
        self.onPersonNavigate = onPersonNavigate
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
            personBindingChanged: model.personBindingChanged
        )
        .accessibilityIdentifier("comment_navigation_page")
    }
}


private struct CommentThreadContainer: View {
    @ObservedObject var store: CommentSessionStore
    let personModel: PersonHostModel?
    let personBindingChanged: (Bool) -> Void

    var body: some View {
        CommentLevelView(store: store, level: .root, close: nil)
            .navigationDestination(isPresented: rootPersonBinding) {
                if let personModel { PersonNativeView(model: personModel) }
            }
        .sheet(item: replyDestinationBinding) { destination in
            CommentReplySheetView(
                store: store,
                level: destination.level,
                personModel: personModel,
                personBindingChanged: personBindingChanged,
                close: closeReplies
            )
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
                accessibilityPrefix: "comment_media"
            )
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
        .task { store.start() }
    }

    private var rootPersonBinding: Binding<Bool> {
        Binding(
            get: { personModel != nil && store.activeLevel == .root },
            set: { isPresented in
                if !isPresented, store.activeLevel == .root {
                    personBindingChanged(false)
                }
            }
        )
    }

    private var replyDestinationBinding: Binding<CommentReplySheetDestination?> {
        Binding(
            get: { CommentReplySheetDestination(level: store.activeLevel) },
            set: { destination in
                if destination == nil { closeReplies() }
            }
        )
    }

    private func closeReplies() {
        personBindingChanged(false)
        store.dismissReplies()
    }
}

private struct CommentReplySheetDestination: Identifiable {
    let level: CommentLevelKey

    init?(level: CommentLevelKey) {
        guard case let .replies(rootCommentID) = level else { return nil }
        self.level = level
        id = rootCommentID
    }

    let id: String
}


private struct CommentReplySheetView: View {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey
    let personModel: PersonHostModel?
    let personBindingChanged: (Bool) -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            CommentLevelView(store: store, level: level, close: close)
                .navigationDestination(isPresented: personBinding) {
                    if let personModel { PersonNativeView(model: personModel) }
                }
        }
        .background(Color.nativeSystemBackground.ignoresSafeArea())
        .modifier(CommentSheetPresentationModifier())
        .fullScreenCover(
            item: Binding(
                get: { store.galleryDestination },
                set: { store.galleryBindingChanged(to: $0) }
            )
        ) { destination in
            NativeMediaGallery(
                urls: destination.urls,
                initialIndex: destination.initialIndex,
                accessibilityPrefix: "comment_media"
            )
        }
        .accessibilityIdentifier("comment_reply_sheet")
        .onDisappear(perform: close)
    }

    private var personBinding: Binding<Bool> {
        Binding(
            get: { personModel != nil && store.activeLevel == level },
            set: { isPresented in
                if !isPresented, store.activeLevel == level {
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
            .presentationBackground(Color.nativeSystemBackground)
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
                    .listRowBackground(Color.nativeSystemBackground)
            }
            pageContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Color.nativeSystemBackground)
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
                .listRowBackground(Color.nativeSystemBackground)
        case let .failed(message) where page.items.isEmpty:
            CommentUnavailableView(
                title: "评论加载失败",
                message: message,
                actionTitle: "重试"
            ) { store.retryInitial(level: level) }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.nativeSystemBackground)
        case .loaded where page.items.isEmpty:
            CommentUnavailableView(
                title: level == .root ? "暂无评论" : "暂无回复",
                message: level == .root ? "成为第一个发表评论的人" : "这条评论还没有回复",
                actionTitle: nil,
                action: nil
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.nativeSystemBackground)
        default:
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
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
                .listRowBackground(Color.nativeSystemBackground)
        case let .failed(message):
            CommentUnavailableView(title: "未能加载更多", message: message, actionTitle: "重试") {
                store.retryNext(level: level)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.nativeSystemBackground)
        case .idle where page.isEnd && !page.items.isEmpty:
            Text(level == .root ? "已显示全部评论" : "已显示全部回复")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemBackground)
        default:
            EmptyView()
        }
    }
}

private struct CommentRow: View {
    @ObservedObject var store: CommentSessionStore
    let comment: CommentDTO
    let interactionLevel: CommentLevelKey?
    let onShare: () -> Void

    init(
        store: CommentSessionStore,
        comment: CommentDTO,
        interactionLevel: CommentLevelKey? = nil,
        onShare: @escaping () -> Void = {}
    ) {
        self.store = store
        self.comment = comment
        self.interactionLevel = interactionLevel
        self.onShare = onShare
    }

    @Environment(\.nativeContentPresentation) private var presentation
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    var body: some View {
        rowContent
            .nativeFeedCard(cornerRadius: 14)
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
        .accessibilityHint("长按或左滑可回复、复制或分享")
    }

    private var rowContent: some View {
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
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 \(comment.author.displayName) 的主页")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Button(comment.author.displayName) { store.openAuthor(commentID: comment.id) }
                            .buttonStyle(.plain)
                            .font(.headline)

                        if let reply = comment.replyToAuthor {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(reply.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .onTapGesture {
                                store.openAuthor(commentID: comment.id, replyToAuthor: true)
                            }
                        }
                    }
                    Text(CommentDateFormatter.string(seconds: comment.createdTimeSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            CommentRichText(html: comment.contentHTML)
                .contentShape(Rectangle())

            if !comment.media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(comment.media) { media in
                            Button { store.openMedia(commentID: comment.id, mediaID: media.id) } label: {
                                Group {
                                    if media.kind == .animatedImage ||
                                        NativeRemoteMediaPolicy.isAnimatedImage(media.url) {
                                        NativeAnimatedRemoteImage(url: media.url, contentMode: .fill)
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
                                    }
                                }
                                .frame(width: 120, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看评论图片")
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                Button {
                    hapticFeedback(.selection)
                    store.toggleLike(commentID: comment.id, level: interactionLevel)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 13, weight: .semibold))
                            .scaleEffect(comment.isLiked ? 1.08 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: comment.isLiked)
                        if comment.likeCount > 0 {
                            Text("\(comment.likeCount)")
                                .font(.caption.weight(.medium).monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .disabled(store.pages[interactionLevel ?? store.activeLevel]?.activeLikeMutation != nil)

                Button {
                    beginReply()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("回复")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("回复评论")

                Spacer(minLength: 12)

                if interactionLevel == .root, comment.childCommentCount > 0 {
                    Button {
                        store.openReplies(rootCommentID: comment.id)
                    } label: {
                        HStack(spacing: 3) {
                            Text("共 \(comment.childCommentCount) 条回复")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                    }
                    .accessibilityIdentifier("reply_count_open_\(comment.id)")
                }
            }
            .foregroundStyle(.tint)
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
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
                    .font(.system(size: 17, weight: .medium))
                Text(level == .root ? "写评论…" : "回复这条评论…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .liquidGlassCapsule(isProminent: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("comment_composer_open")
    }

    private var activeComposer: some View {
        VStack(spacing: 6) {
            HStack {
                Text(store.activeReplyTargetName.map { "回复 \($0)" } ?? (level == .root ? "发表新评论" : "发表新回复"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismissComposer() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

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
                .padding(.horizontal, 12)
            }
            HStack(alignment: .center, spacing: 8) {
                Button { showsEmojiPicker = true } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 21, weight: .medium))
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
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("选择图片")
                .accessibilityIdentifier("comment_photo_picker")

                CommentDraftField(store: store, isFocused: $isDraftFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
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

private struct CommentRichText: View {
    let html: String
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @ScaledMetric(relativeTo: .body) private var bodyPointSize: CGFloat = 17

    var body: some View {
        let pointSize = bodyPointSize * contentPresentation.fontScale
        let bodyFont = Font.system(size: pointSize)
        Text(CommentAttributedText.value(from: html, bodyFont: bodyFont))
            .font(bodyFont)
            .lineSpacing(contentPresentation.extraLineSpacing(for: pointSize))
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                    return .discarded
                }
                guard !CommentAttributedText.isKnownInternalZhihuURL(url) else { return .discarded }
                return .systemAction(url)
            })
    }
}

private enum CommentAttributedText {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func value(from html: String, bodyFont: Font) -> AttributedString {
        let key = html as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }

        let source = CommentHTMLMediaParser.project(html).textHTML
        var result = AttributedString()
        for block in QARichContentParser.blocks(from: source) {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            switch block {
            case let .paragraph(_, runs), let .heading(_, _, runs), let .quote(_, runs), let .segment(_, _, runs):
                append(runs, bodyFont: bodyFont, to: &result)
            case let .list(_, kind, items):
                append(
                    list: QAListGroup(kind: kind, items: items),
                    depth: 0,
                    bodyFont: bodyFont,
                    to: &result
                )
            case let .code(_, _, text), let .formula(_, text):
                var code = AttributedString(text)
                code.font = bodyFont.monospaced()
                result.append(code)
            case .image, .video, .divider:
                break
            }
        }
        let finalResult = result.characters.isEmpty
            ? AttributedString(CommentEmojiCatalog.renderedText(QARichContentParser.plainText(source)))
            : result

        if let ns = try? NSAttributedString(finalResult, including: \.uiKit) {
            cache.setObject(ns, forKey: key)
        }
        return finalResult
    }

    private static func append(_ runs: [QAInlineRun], bodyFont: Font, to result: inout AttributedString) {
        for run in runs {
            var part = AttributedString(CommentEmojiCatalog.renderedText(run.text))
            var presentation: InlinePresentationIntent = []
            if run.style.contains(.strong) { presentation.insert(.stronglyEmphasized) }
            if run.style.contains(.emphasis) { presentation.insert(.emphasized) }
            if !presentation.isEmpty { part.inlinePresentationIntent = presentation }
            if run.style.contains(.strikethrough) { part.strikethroughStyle = .single }
            if run.style.contains(.code) { part.font = bodyFont.monospaced() }
            if let destination = run.link,
               let url = QABodyLinkResolver.url(destination),
               !isKnownInternalZhihuURL(url) {
                part.link = url
            }
            result.append(part)
        }
    }

    private static func append(
        list: QAListGroup,
        depth: Int,
        bodyFont: Font,
        to result: inout AttributedString
    ) {
        for (index, item) in list.items.enumerated() {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            let number = item.ordinal ?? list.startIndex + index
            let marker = list.kind == .ordered ? "\(number). " : "• "
            result.append(AttributedString(String(repeating: "  ", count: depth) + marker))
            append(item.runs, bodyFont: bodyFont, to: &result)
            for nestedList in item.nestedLists {
                append(list: nestedList, depth: depth + 1, bodyFont: bodyFont, to: &result)
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
    static func string(seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
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

