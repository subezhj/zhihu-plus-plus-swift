import SwiftUI

struct OfflineReaderView: View {
    let questionID: Int64
    @State private var package: OfflineQuestionPackage?
    @State private var selectedIndex: Int = 0
    @State private var isDetailExpanded = true
    @Environment(\.nativeContentPresentation) private var contentPresentation

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
        .task {
            package = await OfflineStorageService.shared.loadPackage(questionID: questionID)
        }
    }

    @ViewBuilder
    private func contentView(_ package: OfflineQuestionPackage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 问题标题与描述部分
                questionHeader(package.question)

                Divider()
                    .padding(.vertical, 4)

                // 切换回答的 Tab/Paging 标识
                if !package.answers.isEmpty {
                    answerNavigationHeader(answersCount: package.answers.count)

                    // 当前选中的回答全文
                    if package.answers.indices.contains(selectedIndex) {
                        let answer = package.answers[selectedIndex]
                        answerBody(answer)
                    }
                } else {
                    Text("该问题下暂无缓存回答")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func questionHeader(_ question: QuestionDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        Text("问题描述")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isDetailExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isDetailExpanded {
                    QABodyView(
                        blocks: question.detailBlocks,
                        segmentSubject: .question(question.id),
                        onNavigate: { _ in }
                    )
                } else {
                    Text(question.plainTextDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    @ViewBuilder
    private func answerNavigationHeader(answersCount: Int) -> some View {
        HStack {
            Text("回答 (\(selectedIndex + 1)/\(answersCount))")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    withAnimation {
                        if selectedIndex > 0 { selectedIndex -= 1 }
                    }
                } label: {
                    Image(systemName: "chevron.left.circle")
                        .font(.title3)
                }
                .disabled(selectedIndex <= 0)

                Button {
                    withAnimation {
                        if selectedIndex < answersCount - 1 { selectedIndex += 1 }
                    }
                } label: {
                    Image(systemName: "chevron.right.circle")
                        .font(.title3)
                }
                .disabled(selectedIndex >= answersCount - 1)
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func answerBody(_ answer: AnswerDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 作者信息
            HStack(spacing: 11) {
                AsyncImage(url: answer.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 38, height: 38)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
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
                Text("\(answer.voteUpCount) 赞同")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            // 正文区块
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
            .padding(.top, 12)
        }
    }
}
