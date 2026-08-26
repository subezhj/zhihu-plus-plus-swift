import SwiftUI

struct QuestionNativeView: View {
    @ObservedObject var store: QuestionStore
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @ScaledMetric(relativeTo: .subheadline) private var detailSummaryPointSize: CGFloat = 15

    var body: some View {
        Group {
            if store.question != nil {
                questionContent
            } else {
                switch store.initialLoad {
                case let .failed(message):
                    QAErrorState(message: message, actionTitle: "重试") {
                        Task { await store.refresh() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
                case .idle, .loading, .loaded:
                    VStack {
                        Spacer()
                        ProgressView("正在加载问题")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
                }
            }
        }
        .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
        .navigationTitle(store.question?.title.isEmpty == false ? (store.question?.title ?? "问题") : "问题")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadIfNeeded() }
        .alert(item: messageBinding) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了")) { store.dismissMessage() }
            )
        }
    }

    @ViewBuilder
    private var questionContent: some View {
        if let question = store.question {
            List {
                VStack(alignment: .leading, spacing: 18) {
                    Text(question.title)
                        .font(NativeTypography.pageTitle(scale: contentPresentation.fontScale))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.detailBlocks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    store.isDetailExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Text("问题描述")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(store.isDetailExpanded ? 180 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if store.isDetailExpanded {
                                QABodyView(
                                    blocks: question.detailBlocks,
                                    segmentSubject: .question(question.id),
                                    onNavigate: onNavigate
                                )
                                .transition(.opacity)
                            } else {
                                Text(question.plainTextDetail)
                                    .font(.system(size: detailSummaryPointSize * contentPresentation.fontScale))
                                    .lineSpacing(contentPresentation.extraLineSpacing(
                                        for: detailSummaryPointSize * contentPresentation.fontScale
                                    ))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .transition(.opacity)
                            }
                        }
                    }

                    if !question.topics.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(question.topics) { topic in
                                    if let url = topic.url {
                                        Button(topic.name) { onNavigate(.endorsement(url)) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    } else {
                                        Text(topic.name)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    QAQuestionStats(question: question)
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemGroupedBackground)

                Section {
                    if store.answers.isEmpty && store.nextPage == .loading {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 9) {
                                    Circle().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 14)
                                        RoundedRectangle(cornerRadius: 3).frame(width: 130, height: 10)
                                    }
                                }
                                RoundedRectangle(cornerRadius: 4).frame(height: 16)
                                RoundedRectangle(cornerRadius: 4).frame(height: 16)
                                RoundedRectangle(cornerRadius: 3).frame(width: 100, height: 12)
                            }
                            .foregroundStyle(.secondary.opacity(0.3))
                            .redacted(reason: .placeholder)
                            .nativeFeedCardItem(cornerRadius: 14)
                        }
                    } else {
                        ForEach(store.answers) { answer in
                            Button {
                                onNavigate(.answer(store.answerRoute(for: answer)))
                            } label: {
                                QAAnswerPreviewRow(answer: answer)
                            }
                            .buttonStyle(.plain)
                            .nativeFeedCardItem(cornerRadius: 14)
                            .task {
                                if answer.id == store.answers.last?.id { await store.loadMore() }
                            }
                        }
                    }

                    switch store.nextPage {
                    case .loading where !store.answers.isEmpty:
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    case let .failed(message):
                        Button("加载回答失败，点此重试") { Task { await store.loadMore() } }
                            .foregroundStyle(.red)
                            .accessibilityHint(message)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    case .idle:
                        if store.answers.isEmpty {
                            Text("还没有回答")
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    default:
                        EmptyView()
                    }
                } header: {
                    Picker("回答排序", selection: sortBinding) {
                        ForEach(QuestionAnswerSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.clear)
                    .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
            .refreshable { await store.refresh() }
            .safeAreaInset(edge: .bottom) {
                QuestionActionBar(
                    question: question,
                    followInFlight: store.isFollowMutationInFlight,
                    onFollow: { Task { await store.toggleFollowing() } },
                    onWrite: {
                        onNavigate(.writeAnswer(.init(questionID: question.id, questionTitle: question.title)))
                    },
                    onComments: {
                        onNavigate(.comments(CommentThreadRouteDTO(
                            subject: .question(question.id),
                            shareContext: CommentShareContextDTO(
                                title: question.title,
                                excerpt: QARichContentParser.plainText(question.detailHTML),
                                sourceURL: URL(string: "https://www.zhihu.com/question/\(question.id)")!
                            )
                        )))
                    },
                    onShare: {
                        if let url = URL(string: "https://www.zhihu.com/question/\(question.id)") {
                            onNavigate(.share(url))
                        }
                    }
                )
            }
        }
    }

    private var sortBinding: Binding<QuestionAnswerSort> {
        Binding(
            get: { store.sort },
            set: { value in
                Task {
                    await store.selectSort(value)
                }
            }
        )
    }

    private var messageBinding: Binding<QAUserMessage?> {
        Binding(get: { store.message }, set: { _ in store.dismissMessage() })
    }
}

private struct QAQuestionStats: View {
    let question: QuestionDTO

    var body: some View {
        HStack(spacing: 0) {
            stat("回答", question.answerCount)
            stat("浏览", question.visitCount)
            stat("评论", question.commentCount)
            stat("关注", question.followerCount)
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text(value, format: .number.notation(.compactName)).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QAAnswerPreviewRow: View {
    let answer: AnswerPreviewDTO
    @Environment(\.nativeContentPresentation) private var presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: answer.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(answer.author.displayName)
                        .font(NativeTypography.authorName(scale: presentation.fontScale))
                        .foregroundStyle(.primary)
                    if !answer.author.headline.isEmpty {
                        Text(answer.author.headline)
                            .font(NativeTypography.footnote(scale: presentation.fontScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !answer.excerpt.isEmpty {
                let renderedPointSize = 13.5 * presentation.fontScale
                Text(answer.excerpt)
                    .font(NativeTypography.feedExcerpt(scale: presentation.fontScale))
                    .foregroundStyle(.secondary)
                    .lineSpacing(presentation.extraLineSpacing(for: renderedPointSize) * 0.45)
                    .lineLimit(presentation.feedExcerptLines)
            }

            HStack(spacing: 6) {
                Text("\(answer.voteUpCount) 赞同 · \(answer.commentCount) 评论")
                    .font(NativeTypography.caption(scale: presentation.fontScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }
}

private struct QuestionActionBar: View {
    let question: QuestionDTO
    let followInFlight: Bool
    let onFollow: () -> Void
    let onWrite: () -> Void
    let onComments: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            action(
                question.isFollowing ? "checkmark" : "plus",
                label: question.isFollowing ? "已关注" : "关注",
                selected: question.isFollowing,
                action: onFollow
            )
            .disabled(followInFlight)

            Button(action: onWrite) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                    Text("写回答")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("写回答")

            action(
                "bubble.left",
                count: question.commentCount,
                selected: false,
                action: onComments
            )

            action(
                "square.and.arrow.up",
                label: "分享",
                selected: false,
                action: onShare
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            NativeThinDivider()
        }
    }

    private func action(
        _ systemName: String,
        count: Int? = nil,
        label: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                Text(label ?? count.map(String.init) ?? "")
                    .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                    .lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }
}

struct QAErrorState: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
