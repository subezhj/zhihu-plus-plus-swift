import SwiftUI

struct TopicRouteDTO: Hashable, Sendable {
    let topicID: Int64
}

struct TopicInfoDTO: Codable, Hashable, Sendable {
    let id: Int64
    let name: String
    let excerpt: String?
    let avatarURL: URL?
    let followersCount: Int
    let answersCount: Int
    let questionsCount: Int
}

struct TopicFeedDTO: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let excerpt: String?
    let source: String
    let route: FeedItemRoute?
}

protocol TopicRepository: Sendable {
    func fetchInfo(topicID: Int64) async throws -> TopicInfoDTO
    func fetchFeeds(topicID: Int64, offset: Int, limit: Int) async throws -> [TopicFeedDTO]
}

/// 话题页数据（登录态下通过 APIClient 访问；未登录或接口调整时由调用方兜底）
actor URLSessionTopicRepository: TopicRepository {
    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchInfo(topicID: Int64) async throws -> TopicInfoDTO {
        let url = URL(string: "https://www.zhihu.com/api/v4/topics/\(topicID)")!
        let data = try await client.data(for: url)
        return try TopicResponseMapper.info(from: data, topicID: topicID)
    }

    func fetchFeeds(topicID: Int64, offset: Int, limit: Int) async throws -> [TopicFeedDTO] {
        var components = URLComponents(string: "https://www.zhihu.com/api/v4/topics/\(topicID)/feeds/hot")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        guard let url = components.url else { throw ZhihuAPIError.malformedPayload }
        let data = try await client.data(for: url)
        return try TopicResponseMapper.feeds(from: data)
    }
}

enum TopicResponseMapper {
    static func info(from data: Data, topicID: Int64) throws -> TopicInfoDTO {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZhihuAPIError.malformedPayload
        }
        let name = (root["name"] as? String) ?? "话题"
        let excerpt = ((root["excerpt"] as? String)?.nonBlank ?? (root["introduction"] as? String)?.nonBlank)
        let avatarURL = (root["avatar_url"] as? String).flatMap { URL(string: $0) }
        let parsedID = (root["id"] as? NSNumber)?.int64Value ?? Int64((root["id"] as? String) ?? "")
        return TopicInfoDTO(
            id: parsedID ?? topicID,
            name: name,
            excerpt: excerpt,
            avatarURL: avatarURL,
            followersCount: (root["followers_count"] as? NSNumber)?.intValue ?? 0,
            answersCount: (root["answers_count"] as? NSNumber)?.intValue ?? 0,
            questionsCount: (root["questions_count"] as? NSNumber)?.intValue ?? 0
        )
    }

    static func feeds(from data: Data) throws -> [TopicFeedDTO] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataList = root["data"] as? [[String: Any]]
        else {
            return []
        }
        let items: [TopicFeedDTO] = dataList.compactMap { item in
            let target = item["target"] as? [String: Any] ?? item
            guard let type = target["type"] as? String else { return nil }
            let title = (target["title"] as? String) ?? (target["excerpt"] as? String) ?? ""
            let excerpt = (target["excerpt"] as? String)?.nonBlank ?? (target["content"] as? String)?.nonBlank
            let route = topicRoute(type: type, target: target)
            let id = (target["id"] as? NSNumber)?.stringValue ?? (target["id"] as? String) ?? UUID().uuidString
            return TopicFeedDTO(id: "\(type)-\(id)", title: title, excerpt: excerpt, source: type, route: route)
        }
        return items
    }

    private static func topicRoute(type: String, target: [String: Any]) -> FeedItemRoute? {
        let id = ((target["id"] as? NSNumber) ?? (target["id"] as? NSString)).flatMap { Int64($0.description) }
        guard let id else { return nil }
        switch type {
        case "question", "normal_question", "topic_question":
            return .question(questionID: id, title: (target["title"] as? String) ?? "")
        case "answer":
            let question = target["question"] as? [String: Any]
            return .answer(
                answerID: id,
                questionID: (question?["id"] as? NSNumber).flatMap { Int64($0.description) },
                questionTitle: (question?["title"] as? String) ?? ""
            )
        case "article":
            return .article(articleID: id, title: (target["title"] as? String) ?? "")
        case "pin", "zvideo":
            return .pin(pinID: id)
        default:
            return nil
        }
    }
}

@MainActor
final class TopicStore: ObservableObject {
    @Published private(set) var info: TopicInfoDTO?
    @Published private(set) var feeds: [TopicFeedDTO] = []
    @Published private(set) var isLoadingInfo = false
    @Published private(set) var isLoadingFeeds = false
    @Published private(set) var infoErrorMessage: String?
    @Published private(set) var feedsErrorMessage: String?
    @Published private(set) var isEnd = false

    let route: TopicRouteDTO
    private let repository: TopicRepository
    private var nextOffset = 0
    private let pageLimit = 20

    init(route: TopicRouteDTO, repository: TopicRepository) {
        self.route = route
        self.repository = repository
    }

    func loadInfoIfNeeded() async {
        guard info == nil, !isLoadingInfo else { return }
        isLoadingInfo = true
        infoErrorMessage = nil
        do {
            info = try await repository.fetchInfo(topicID: route.topicID)
        } catch is CancellationError {
            isLoadingInfo = false
            return
        } catch {
            infoErrorMessage = Self.presentableMessage(for: error, fallback: "话题信息加载失败")
        }
        isLoadingInfo = false
    }

    func loadMoreIfNeeded() async {
        guard !isLoadingFeeds, !isEnd else { return }
        isLoadingFeeds = true
        feedsErrorMessage = nil
        defer { isLoadingFeeds = false }
        do {
            let page = try await repository.fetchFeeds(
                topicID: route.topicID,
                offset: nextOffset,
                limit: pageLimit
            )
            let known = Set(feeds.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            feeds.append(contentsOf: fresh)
            nextOffset += pageLimit
            isEnd = page.isEmpty || fresh.isEmpty
        } catch is CancellationError {
            return
        } catch {
            feedsErrorMessage = Self.presentableMessage(for: error, fallback: "话题内容加载失败")
        }
    }

    /// 把服务端常见错误转为对用户友好的提示（话题接口需登录）
    private static func presentableMessage(for error: Error, fallback: String) -> String {
        switch error {
        case ZhihuAPIError.authenticationRequired,
             ZhihuAPIError.httpStatus(401),
             ZhihuAPIError.httpStatus(403):
            return "话题需要登录后查看，请先在 App 内登录"
        default:
            return fallback
        }
    }

    func retry() async {
        isLoadingInfo = false
        infoErrorMessage = nil
        feedsErrorMessage = nil
        await loadInfoIfNeeded()
        if feeds.isEmpty { await loadMoreIfNeeded() }
    }
}

struct TopicNativeView: View {
    @StateObject private var store: TopicStore
    let onOpen: (FeedItemRoute) -> Void

    init(
        route: TopicRouteDTO,
        repository: TopicRepository,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = StateObject(wrappedValue: TopicStore(route: route, repository: repository))
        self.onOpen = onOpen
    }

    var body: some View {
        Group {
            if store.info != nil {
                content
            } else if store.isLoadingInfo {
                ProgressView("正在加载话题")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
            } else {
                VStack(spacing: 12) {
                    Text(store.infoErrorMessage ?? "话题加载失败")
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await store.retry() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
            }
        }
        .navigationTitle(store.info?.name ?? "话题")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadInfoIfNeeded() }
        .accessibilityIdentifier("topic_native")
    }

    private var content: some View {
        List {
            if let info = store.info {
                topicHeader(info)
            }
            if let error = store.feedsErrorMessage, store.feeds.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.nativeSystemGroupedBackground)
                    .listRowSeparator(.hidden)
            }
            if store.info != nil, store.feeds.isEmpty, !store.isLoadingFeeds {
                Text("话题内容为空")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.nativeSystemGroupedBackground)
            }
            ForEach(store.feeds, id: \.id) { item in
                if let route = item.route {
                    Button {
                        onOpen(route)
                    } label: {
                        TopicFeedRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .nativeFeedCardItem(cornerRadius: 14)
                    .onAppear {
                        if item.id == store.feeds.last?.id {
                            Task { await store.loadMoreIfNeeded() }
                        }
                    }
                } else {
                    TopicFeedRow(item: item)
                        .nativeFeedCardItem(cornerRadius: 14)
                }
            }
            if store.isLoadingFeeds {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.nativeSystemGroupedBackground)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, NativeHomeFeedCardSpacing.firstCardExtraTopMargin, for: .scrollContent)
        .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
    }

    private func topicHeader(_ info: TopicInfoDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AsyncImage(url: info.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: "text.bubble")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(info.followersCount) 关注 · \(info.questionsCount) 问题 · \(info.answersCount) 回答")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            if let excerpt = info.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Text("热门内容")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.nativeSystemGroupedBackground)
    }
}

private struct TopicFeedRow: View {
    let item: TopicFeedDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            if let excerpt = item.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(sourceTitle(item.source))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func sourceTitle(_ source: String) -> String {
        switch source {
        case "question", "normal_question", "topic_question": return "问题"
        case "answer": return "回答"
        case "article": return "文章"
        case "pin": return "想法"
        case "zvideo": return "视频"
        default: return source
        }
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}