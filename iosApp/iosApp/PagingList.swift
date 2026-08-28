import SwiftUI

/// 通用分页数据源协议（新架构重构 §4.19）。
///
/// 抽象所有「列表 + 触底分页 + 下拉刷新 + 空/错/底占位」的共享行为，
/// 供首页推荐流、热榜、收藏、通知、评论区、话题、想法等页面复用。
///
/// - 各 Store 通过 `extension ... : PagingSource` 或轻量包装接入，不改动内部数据逻辑。
/// - 卡片 vs 无卡片由调用方的 `rowContent` 决定（FeedItemRow 有卡片、CommentRow 无卡片）。
@MainActor
protocol PagingSource: AnyObject, ObservableObject {
    associatedtype Item: Identifiable

    var items: [Item] { get }
    var isLoading: Bool { get }
    /// 是否还有下一页可加载（决定触底触发 loadMore 与 footer 占位）
    var hasMore: Bool { get }
    var errorMessage: String? { get }

    func loadMore() async
    func refresh() async
    func retry() async
}

/// 通用分页列表内容：在 `List` 内使用，统一管理：
/// - 首屏加载行、行列表、触底加载（最后一项 onAppear）
/// - footer（加载中 / 已到底 / 错误重试）、空态
///
/// 页面保留自己的 `List` 修饰符（滚动追踪、ScrollViewReader、坐标空间等特殊能力），
/// 仅复用“分页骨架 + 占位”以收敛重复实现。
struct PagingListContent<Source: PagingSource, Row: View>: View {
    @ObservedObject var source: Source
    let rowContent: (Source.Item, Int) -> Row
    var onAppearItem: (Source.Item) -> Void = { _ in }
    var loadingMessage = "正在加载"
    var footerLoadingMessage = "正在加载更多"
    var emptyMessage = "暂无内容"
    var emptySystemImage = "tray"
    var background: Color = .nativeSystemGroupedBackground

    var body: some View {
        Group {
            if source.items.isEmpty, source.isLoading {
                HStack {
                    Spacer()
                    ProgressView(loadingMessage)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(background)
            }

            ForEach(Array(source.items.enumerated()), id: \.element.id) { index, item in
                rowContent(item, index)
                    .onAppear {
                        onAppearItem(item)
                        if item.id == source.items.last?.id, source.hasMore {
                            Task { await source.loadMore() }
                        }
                    }
            }

            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let message = source.errorMessage {
            HStack(spacing: 12) {
                Text(message)
                    .font(NativeTypography.footnote())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("重试") {
                    Task { await source.retry() }
                }
                .font(NativeTypography.feedTitle())
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .listRowBackground(background)
        } else if source.hasMore {
            HStack {
                Spacer()
                ProgressView(footerLoadingMessage)
                Spacer()
            }
            .font(.caption)
            .listRowSeparator(.hidden)
            .listRowBackground(background)
        } else if source.items.isEmpty, !source.isLoading {
            VStack(spacing: 10) {
                Image(systemName: emptySystemImage)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(emptyMessage)
                    .font(NativeTypography.feedTitle())
                    .foregroundStyle(.primary)
                Text("下拉刷新试试")
                    .font(NativeTypography.caption())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowSeparator(.hidden)
            .listRowBackground(background)
        }
    }
}
