import SwiftUI

struct OfflineReaderView: View {
    let questionID: Int64
    @State private var package: OfflineQuestionPackage?
    @State private var selectedIndex: Int = 0
    @State private var isDetailExpanded = false
    @State private var showsIndexSheet = false
    @State private var showsCommentsSheet = false
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    var body: some View {
        Group {
            if let package {
                contentView(package)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载离线内容...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.nativeSystemBackground.ignoresSafeArea())
        .navigationTitle(package?.question.title ?? "离线阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let package, !package.answers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsIndexSheet = true
                    } label: {
                        Label("回答目录", systemImage: "list.bullet")
                    }
                }
            }
        }
        .task {
            package = await OfflineStorageService.shared.loadPackage(questionID: questionID)
        }
    }

    @ViewBuilder
    private func contentView(_ package: OfflineQuestionPackage) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // 问题头部（标题与折叠描述）
                    questionHeader(package.question)

                    Divider()
                        .padding(.vertical, 2)

                    if package.answers.indices.contains(selectedIndex) {
                        let answer = package.answers[selectedIndex]
                        answerBody(answer, totalCount: package.answers.count)
                            .id(answer.route.contentID)
                    } else {
                        Text("该问题下暂无缓存回答")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .padding(.bottom, 80) // 留出底部悬浮 ActionBar 的间距
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 35)
                    .onEnded { value in
                        handleSwipeGesture(value, totalCount: package.answers.count)
                    }
            )

            // 悬浮液态玻璃操作底栏
            if !package.answers.isEmpty {
                offlineActionBar(package: package)
            }
        }
        .sheet(isPresented: $showsIndexSheet) {
            offlineIndexSheet(package: package)
        }
        .sheet(isPresented: $showsCommentsSheet) {
            if package.answers.indices.contains(selectedIndex) {
                let currentAnswer = package.answers[selectedIndex]
                offlineCommentsSheet(
                    answer: currentAnswer,
                    comments: package.comments[currentAnswer.route.contentID] ?? []
                )
            }
        }
    }

    private func handleSwipeGesture(_ value: DragGesture.Value, totalCount: Int) {
        let horizontalTranslation = value.translation.width
        let verticalTranslation = value.translation.height
        // 确保是明显的水平滑动，且横向位移远大于竖向位移以避免与纵向滚动冲突
        guard abs(horizontalTranslation) > 60, abs(horizontalTranslation) > abs(verticalTranslation) * 1.5 else { return }

        if horizontalTranslation < 0 {
            // 向左轻扫 -> 下一条
            nextAnswer(totalCount: totalCount)
        } else {
            // 向右轻扫 -> 上一条
            previousAnswer()
        }
    }

    private func previousAnswer() {
        guard selectedIndex > 0 else {
            hapticFeedback(.navigationBoundary)
            return
        }
        hapticFeedback(.selection)
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedIndex -= 1
        }
    }

    private func nextAnswer(totalCount: Int) {
        guard selectedIndex < totalCount - 1 else {
            hapticFeedback(.navigationBoundary)
            return
        }
        hapticFeedback(.selection)
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedIndex += 1
        }
    }

    // MARK: - 悬浮液态玻璃操作底栏

    @ViewBuilder
    private func offlineActionBar(package: OfflineQuestionPackage) -> some View {
        let totalCount = package.answers.count
        let currentAnswer = package.answers.indices.contains(selectedIndex) ? package.answers[selectedIndex] : nil
        let commentsCount = currentAnswer.flatMap { package.comments[$0.route.contentID]?.count } ?? 0

        HStack(spacing: 0) {
            // 上一条回答
            Button {
                previousAnswer()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("上一条")
                        .font(.system(size: 10.5))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedIndex <= 0)
            .foregroundStyle(selectedIndex > 0 ? Color.primary : Color.secondary.opacity(0.4))

            // 中间目录/进度
            Button {
                hapticFeedback(.selection)
                showsIndexSheet = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "list.number")
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(selectedIndex + 1) / \(totalCount)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            // 评论
            Button {
                hapticFeedback(.selection)
                showsCommentsSheet = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 17, weight: .regular))
                    Text(commentsCount > 0 ? "\(commentsCount) 评论" : "评论")
                        .font(.system(size: 10.5).monospacedDigit())
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)

            // 下一条回答
            Button {
                nextAnswer(totalCount: totalCount)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                    Text("下一条")
                        .font(.system(size: 10.5))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedIndex >= totalCount - 1)
            .foregroundStyle(selectedIndex < totalCount - 1 ? Color.primary : Color.secondary.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlassCapsule(ignoreToggle: true)
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 问题头部

    @ViewBuilder
    private func questionHeader(_ question: QuestionDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.title)
                .font(NativeTypography.pageTitle(scale: contentPresentation.fontScale))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !question.detailBlocks.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isDetailExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isDetailExpanded ? "收起问题描述" : "查看问题描述")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isDetailExpanded ? 180 : 0))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isDetailExpanded {
                    QABodyView(
                        blocks: question.detailBlocks,
                        segmentSubject: .question(question.id),
                        onNavigate: { _ in }
                    )
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - 回答全文

    @ViewBuilder
    private func answerBody(_ answer: AnswerDTO, totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 作者信息行
            HStack(spacing: 12) {
                AsyncImage(url: answer.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 42, height: 42)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(answer.author.displayName)
                        .font(.headline)
                    if !answer.author.headline.isEmpty {
                        Text(answer.author.headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(answer.voteUpCount.formatted(.number.notation(.compactName))) 赞同")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                    Text("第 \(selectedIndex + 1) / \(totalCount) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            Divider()
                .opacity(0.6)

            // 正文富文本与图片展示
            QABodyView(
                blocks: answer.blocks,
                segmentSubject: .answer(answer.route.contentID),
                onNavigate: { _ in }
            )

            // 底部元信息
            VStack(alignment: .trailing, spacing: 4) {
                if let ip = answer.ipLocation, !ip.isEmpty {
                    Text("IP 属地：\(ip)")
                }
                if answer.createdTimeSeconds > 0 {
                    Text("发布于 \(Date(timeIntervalSince1970: TimeInterval(answer.createdTimeSeconds)).formatted(.dateTime.year().month().day()))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 16)
        }
    }

    // MARK: - 回答目录抽屉 Sheet

    @ViewBuilder
    private func offlineIndexSheet(package: OfflineQuestionPackage) -> some View {
        NavigationStack {
            List(Array(package.answers.enumerated()), id: \.element.route.contentID) { index, ans in
                Button {
                    selectedIndex = index
                    showsIndexSheet = false
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.secondary)
                            .frame(width: 28, alignment: .center)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ans.author.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.primary)
                                Spacer()
                                Text("\(ans.voteUpCount.formatted(.number.notation(.compactName))) 赞同")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let firstBlockText = extractSummaryText(from: ans.blocks) {
                                Text(firstBlockText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(index == selectedIndex ? Color.accentColor.opacity(0.08) : Color.clear)
            }
            .navigationTitle("回答目录 (\(package.answers.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showsIndexSheet = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func extractSummaryText(from blocks: [QABodyBlock]) -> String? {
        for block in blocks {
            switch block {
            case let .paragraph(_, runs), let .quote(_, runs), let .heading(_, _, runs):
                let text = runs.map(\.text).joined()
                if !text.isEmpty { return text }
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - 离线评论抽屉 Sheet

    @ViewBuilder
    private func offlineCommentsSheet(answer: AnswerDTO, comments: [CommentDTO]) -> some View {
        NavigationStack {
            Group {
                if comments.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("暂无缓存的离线评论")
                            .font(.headline)
                        Text("离线缓存仅收录回答的前 10 条热门主评。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(comments) { comment in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 9) {
                                AsyncImage(url: comment.author.avatarURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())

                                Text(comment.author.displayName)
                                    .font(.subheadline.weight(.semibold))

                                Spacer()

                                if comment.likeCount > 0 {
                                    Label("\(comment.likeCount)", systemImage: "hand.thumbsup")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // 评论文本内容
                            Text(QARichContentParser.plainText(comment.contentHTML))
                                .font(.subheadline)
                                .foregroundStyle(.primary)

                            HStack {
                                if let ip = comment.ipLocation, !ip.isEmpty {
                                    Text("IP属地: \(ip)")
                                }
                                Text(Date(timeIntervalSince1970: TimeInterval(comment.createdTimeSeconds)).formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("热门评论 (\(comments.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showsCommentsSheet = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
