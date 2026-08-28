import SwiftUI


struct HotListNativeView: View {
    @ObservedObject private var store: HotFeedStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Binding private var collapseProgress: CGFloat
    private let scrollToTopRequest: UInt
    private let onOpen: (FeedItemRoute) -> Void

    init(
        store: HotFeedStore,
        collapseProgress: Binding<CGFloat> = .constant(0),
        scrollToTopRequest: UInt = 0,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _collapseProgress = collapseProgress
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                NativeRootLargeTitle(
                    "首页",
                    coordinateSpaceName: "hot-root-scroll",
                    displaysTitle: false,
                    isActive: isActiveChannel,
                    isRefreshing: store.isRefreshing,
                    collapseProgress: $collapseProgress
                )
                .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.nativeSystemGroupedBackground)

                // 通用分页骨架：排名序号由 rowContent 的 index 渲染，footer 统一管理
                PagingListContent(
                    source: store,
                    rowContent: { item, index in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.headline.weight(.bold).monospacedDigit())
                                .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                                .frame(minWidth: 24, alignment: .trailing)
                                .padding(.top, 14)
                                .accessibilityHidden(true)
                            FeedItemRow(item: item, showsThumbnail: false, onOpen: onOpen)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    },
                    loadingMessage: "正在加载热榜",
                    footerLoadingMessage: "正在加载更多",
                    customItems: visibleItems
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
            .nativeHomeFeedListLayout()
            .coordinateSpace(name: "hot-root-scroll")
            .nativeHomeFeedScrollTracking(
                collapseProgress: $collapseProgress,
                isActive: isActiveChannel
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                guard isActiveChannel else { return }
                let previousSuccessfulRefresh = store.refreshMetadata.lastSuccessfulRefreshAt
                await store.refresh()
                if !Task.isCancelled,
                   NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: store.refreshMetadata.lastSuccessfulRefreshAt
                   ) {
                    hapticFeedback(.refreshSucceeded)
                }
            }
            .onAppear {
                if scrollToTopRequest > 0 { scrollToTop(proxy, animated: false) }
            }
            .onChange(of: scrollToTopRequest) { _ in scrollToTop(proxy, animated: true) }
            .task(id: isActiveChannel) {
                guard isActiveChannel else { return }
                await store.loadInitialIfNeeded()
            }
        }
        .accessibilityIdentifier("hot_list")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    proxy.scrollTo(
                        NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot),
                        anchor: .top
                    )
                }
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot),
                    anchor: .top
                )
            }
        }
    }
}
