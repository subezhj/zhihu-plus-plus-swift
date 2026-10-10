import Foundation
import Combine

enum OfflineDownloadTarget: Int, CaseIterable, Identifiable {
    case five = 5
    case ten = 10
    case twenty = 20

    var id: Int { rawValue }
    var title: String { "前 \(rawValue) 条回答" }
}

enum OfflineDownloadState: Equatable {
    case idle
    case downloading(questionID: Int64, progress: Double, message: String)
    case completed(questionID: Int64, count: Int)
    case failed(questionID: Int64, message: String)
}

@MainActor
final class OfflineDownloadManager: ObservableObject {
    static let shared = OfflineDownloadManager()

    @Published private(set) var state: OfflineDownloadState = .idle
    @Published private(set) var activeQuestionID: Int64?

    private let storage: OfflineStorageService
    private var downloadTask: Task<Void, Never>?

    init(storage: OfflineStorageService = .shared) {
        self.storage = storage
    }

    var isDownloading: Bool {
        activeQuestionID != nil
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        if let qid = activeQuestionID {
            state = .idle
            activeQuestionID = nil
        }
    }

    func startDownload(
        questionID: Int64,
        targetCount: OfflineDownloadTarget,
        repository: QuestionAnswerRepository
    ) {
        guard !isDownloading else { return }

        activeQuestionID = questionID
        state = .downloading(questionID: questionID, progress: 0.05, message: "正在获取问题详情...")

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 1. 获取问题详情
                let route = QuestionRouteDTO(questionID: questionID)
                let question = try await repository.fetchQuestion(route)
                try Task.checkCancellation()

                await MainActor.run {
                    self.state = .downloading(questionID: questionID, progress: 0.15, message: "正在获取回答列表...")
                }

                // 2. 分页获取 AnswerPreviewDTO 列表直到达到 targetCount
                var previews: [AnswerPreviewDTO] = []
                var nextURL: URL? = nil
                while previews.count < targetCount.rawValue {
                    try Task.checkCancellation()
                    let page = try await repository.fetchQuestionAnswers(
                        questionID: questionID,
                        sort: .default,
                        after: nextURL
                    )
                    previews.append(contentsOf: page.items)
                    nextURL = page.nextURL
                    if page.isEnd || page.nextURL == nil || previews.count >= targetCount.rawValue {
                        break
                    }
                }

                let targetPreviews = Array(previews.prefix(targetCount.rawValue))
                guard !targetPreviews.isEmpty else {
                    throw NSError(domain: "OfflineDownload", code: -1, userInfo: [NSLocalizedDescriptionKey: "该问题暂无回答可供缓存"])
                }

                // 3. 逐条拉取完整 AnswerDTO
                var answers: [AnswerDTO] = []
                var imageURLsToDownload: Set<URL> = []

                // 收集问题描述中的图片
                for block in question.detailBlocks {
                    if case let .image(img) = block {
                        imageURLsToDownload.insert(img.url)
                    }
                }

                let totalAnswers = targetPreviews.count
                for (index, preview) in targetPreviews.enumerated() {
                    try Task.checkCancellation()
                    let progress = 0.15 + (0.55 * Double(index) / Double(totalAnswers))
                    await MainActor.run {
                        self.state = .downloading(
                            questionID: questionID,
                            progress: progress,
                            message: "正在下载回答全文 (\(index + 1)/\(totalAnswers))..."
                        )
                    }

                    let answerRoute = AnswerRouteDTO(
                        contentID: preview.answerID,
                        kind: .answer,
                        questionID: questionID,
                        provisionalTitle: preview.questionTitle
                    )
                    let fullAnswer = try await repository.fetchAnswer(answerRoute)
                    answers.append(fullAnswer)

                    // 收集配图 URL
                    for block in fullAnswer.blocks {
                        if case let .image(img) = block {
                            imageURLsToDownload.insert(img.url)
                        }
                    }
                }

                // 4. 下载图片资源
                let totalImages = imageURLsToDownload.count
                if totalImages > 0 {
                    var downloadedCount = 0
                    for imgURL in imageURLsToDownload {
                        try Task.checkCancellation()
                        downloadedCount += 1
                        let progress = 0.70 + (0.25 * Double(downloadedCount) / Double(totalImages))
                        await MainActor.run {
                            self.state = .downloading(
                                questionID: questionID,
                                progress: progress,
                                message: "正在缓存正文配图 (\(downloadedCount)/\(totalImages))..."
                            )
                        }

                        // 检查本地是否已存在
                        let alreadyHas = await self.storage.hasCachedImage(for: imgURL)
                        if !alreadyHas {
                            if let (data, response) = try? await URLSession.shared.data(from: imgURL),
                               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                                await self.storage.saveImageData(data, for: imgURL)
                            }
                        }
                    }
                }

                // 5. 打包并保存
                await MainActor.run {
                    self.state = .downloading(questionID: questionID, progress: 0.98, message: "正在写入本地存储...")
                }

                let manifest = OfflineQuestionManifest(
                    questionID: questionID,
                    title: question.title,
                    answerCount: question.answerCount,
                    cachedAnswerCount: answers.count,
                    totalByteSize: 0, // 会在下次统计时刷新
                    cachedAt: Date()
                )
                let package = OfflineQuestionPackage(manifest: manifest, question: question, answers: answers)
                try await self.storage.save(package: package)

                await MainActor.run {
                    self.activeQuestionID = nil
                    self.state = .completed(questionID: questionID, count: answers.count)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.activeQuestionID = nil
                    self.state = .idle
                }
            } catch {
                await MainActor.run {
                    self.activeQuestionID = nil
                    self.state = .failed(questionID: questionID, message: error.localizedDescription)
                }
            }
        }
    }
}
