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
                    .background(Color.nativeSystemBackground.ignoresSafeArea())
                case .idle, .loading, .loaded:
                    VStack {
                        Spacer()
                        ProgressView("正在加载问题")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.nativeSystemBackground.ignoresSafeArea())
                }
            }
        }
        .background(Color.nativeSystemBackground.ignoresSafeArea())
        .navigationTitle("问题")
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
                        .font(.title2.bold())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.detailBlocks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { store.isDetailExpanded.toggle() }
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
                            } else {
                                Text(QARichContentParser.plainText(question.detailHTML))
                                    .font(.system(size: detailSummaryPointSize * contentPresentation.fontScale))
                                    .lineSpacing(contentPresentation.extraLineSpacing(
                                        for: detailSummaryPointSize * contentPresentation.fontScale
                                    ))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
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
                    Picker("回答排序", selection: sortBinding) {
                        ForEach(QuestionAnswerSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemBackground)

                Section("\(question.answerCount) 个回答") {
                    ForEach(store.answers) { answer in
                        Button {
                            onNavigate(.answer(store.answerRoute(for: answer)))
                        } label: {
                            QAAnswerPreviewRow(answer: answer)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.nativeSystemBackground)
                        .task {
                            if answer.id == store.answers.last?.id { await store.loadMore() }
                        }
                    }

                    switch store.nextPage {
                    case .loading:
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.nativeSystemBackground)
                            .listRowSeparator(.hidden)
                    case let .failed(message):
                        Button("加载更多失败，点此重试") { Task { await store.loadMore() } }
                            .foregroundStyle(.red)
                            .accessibilityHint(message)
                            .listRowBackground(Color.nativeSystemBackground)
                            .listRowSeparator(.hidden)
                    case .idle:
                        if store.answers.isEmpty {
                            Text("还没有回答")
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.nativeSystemBackground)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.nativeSystemBackground.ignoresSafeArea())
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
            set: { value in Task { await store.selectSort(value) } }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AsyncImage(url: answer.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(answer.author.displayName).font(.subheadline.weight(.medium))
                    if !answer.author.headline.isEmpty {
                        Text(answer.author.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if !answer.excerpt.isEmpty {
                Text(answer.excerpt).font(.body).lineLimit(4)
            }
            Text("\(answer.voteUpCount) 赞同 · \(answer.commentCount) 评论")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
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
        actions
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .liquidGlassCapsule(ignoreToggle: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            action(
                question.isFollowing ? "checkmark" : "plus",
                label: question.isFollowing ? "已关注" : "关注",
                selected: question.isFollowing,
                action: onFollow
            )
            .disabled(followInFlight)

            Button(action: onWrite) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                    Text("写回答")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .liquidGlassCapsule(isProminent: true, ignoreToggle: true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("写回答")

            Spacer(minLength: 2)

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
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 44)
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
