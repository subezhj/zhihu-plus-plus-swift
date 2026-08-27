import SwiftUI

struct SearchNativeView: View {
    @StateObject private var store: SearchStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @FocusState private var isSearchFieldFocused: Bool
    @State private var lastConsumedFocusRequestToken: UInt = 0
    @Environment(\.nativeSearchPresentation) private var searchPresentation
    private let focusRequest: NativeSearchFocusRequest
    private let onOpen: (FeedItemRoute) -> Void

    init(
        route: SearchRouteDTO,
        repository: SearchRepository,
        historyPersistence: SearchHistoryPersistence = UserDefaultsSearchHistoryPersistence(),
        defaults: UserDefaults = .standard,
        focusRequest: NativeSearchFocusRequest = .inactive,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = StateObject(
            wrappedValue: SearchStore(
                route: route,
                repository: repository,
                historyPersistence: historyPersistence,
                defaults: defaults
            )
        )
        self.focusRequest = focusRequest
        self.onOpen = onOpen
    }

    var body: some View {
        ZStack {
            List {
                if store.submittedQuery.isEmpty {
                    suggestionContent
                } else {
                    resultContent
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.nativeSystemGroupedBackground)
            .refreshable {
                if store.submittedQuery.isEmpty {
                    await store.refreshSuggestions()
                } else {
                    await store.refreshResults()
                }
            }

            if visibleItems.isEmpty, store.isLoadingResults {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在搜索")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nativeSystemGroupedBackground)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在搜索")
            }
        }
        .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.queryText) { value in
            if value.isEmpty, !store.submittedQuery.isEmpty {
                store.clearQuery()
                if store.showsHotSearch {
                    Task { await store.refreshSuggestions() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField
            }
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
        }
        .task { await store.loadInitialIfNeeded() }
        .task(id: focusRequest) { await consumeFocusRequest(focusRequest) }
        .task(id: searchPresentation) {
            await store.updateSuggestionVisibility(searchPresentation)
        }
        .background(SearchInteractivePopKeyboardBridge())
        .accessibilityIdentifier("search_screen")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: $store.queryText)
                .font(.system(size: 16))
                .focused($isSearchFieldFocused)
                .accessibilityIdentifier("search_input")
                .submitLabel(.search)
                .onSubmit {
                    submitKeyboardQuery()
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            if !store.queryText.isEmpty {
                Button {
                    store.queryText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索内容")
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 320, maxWidth: .infinity)
        .frame(height: 40)
        .liquidGlassCapsule(isProminent: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search_field")
    }

    private func submitKeyboardQuery() {
        let query = store.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearchFieldFocused = false
        Task { await store.submitQuery(query) }
    }

    @MainActor
    private func consumeFocusRequest(_ request: NativeSearchFocusRequest) async {
        guard NativeSearchFocusRequestPolicy.shouldConsume(
            request,
            lastConsumedToken: lastConsumedFocusRequestToken
        ) else { return }
        await Task.yield()
        guard !Task.isCancelled,
              focusRequest == request,
              NativeSearchFocusRequestPolicy.shouldConsume(
                request,
                lastConsumedToken: lastConsumedFocusRequestToken
              )
        else { return }
        lastConsumedFocusRequestToken = request.token
        isSearchFieldFocused = true
    }

    private var searchPrompt: String {
        store.route.isMemberRestricted
            ? "搜索 \(store.memberDisplayName) 的创作"
            : "搜索内容"
    }

    @ViewBuilder
    private var suggestionContent: some View {
        if store.showsHistory, !store.history.isEmpty {
            Section {
                ForEach(historyRows) { row in
                    Button {
                        Task { await store.submitQuery(row.query) }
                    } label: {
                        // 图标降为与热搜热度文本一致的小尺寸（caption），文字保持 feedTitle
                        HStack(spacing: 7) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(NativeTypography.caption())
                                .foregroundStyle(.secondary)
                            Text(row.query)
                                .font(NativeTypography.feedTitle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.nativeSystemGroupedBackground)
                    .listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Text("搜索历史")
                        .nativeCapsuleBadge(foregroundColor: .primary)
                    Spacer()
                    Button("清空") { store.clearHistory() }
                        .nativeCapsuleBadge(foregroundColor: Color.accentColor)
                        .textCase(nil)
                }
                .padding(.top, 4)
                .listRowBackground(Color.nativeSystemGroupedBackground)
            }

            // 仅一条分割线，分隔“搜索历史”与“热搜”区块
            NativeThinDivider()
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.nativeSystemGroupedBackground)
                .listRowSeparator(.hidden)
        }

        if store.showsHotSearch {
            Section {
                ForEach(Array(store.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button {
                        Task { await store.submitQuery(suggestion.query) }
                    } label: {
                        HStack(spacing: 14) {
                            Text("\(index + 1)")
                                .font(NativeTypography.feedTitle().weight(.bold).monospacedDigit())
                                .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                                .frame(minWidth: 20, alignment: .leading)
                            Text(suggestion.query)
                                .font(NativeTypography.feedTitle())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let popularity = suggestion.popularityText {
                                Text(popularity)
                                    .font(NativeTypography.caption())
                                    .foregroundStyle(.secondary.opacity(0.8))
                            }
                        }
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.nativeSystemGroupedBackground)
                    .listRowSeparator(.hidden)
                }

                if store.isRefreshingSuggestions {
                    NativeLoadingRow("正在刷新热搜")
                        .listRowBackground(Color.nativeSystemGroupedBackground)
                } else if let error = store.suggestionErrorMessage {
                    NativeInlineRetry(message: error) {
                        Task { await store.refreshSuggestions() }
                    }
                    .listRowBackground(Color.nativeSystemGroupedBackground)
                }
            } header: {
                HStack {
                    Text("热搜")
                        .nativeCapsuleBadge(foregroundColor: .primary)
                    Spacer()
                    Button {
                        Task { await store.refreshSuggestions() }
                    } label: {
                        Text("刷新")
                            .nativeCapsuleBadge(foregroundColor: Color.accentColor)
                    }
                    .disabled(store.isRefreshingSuggestions)
                    .textCase(nil)
                    .accessibilityLabel("刷新热搜")
                }
                .padding(.top, 4)
                .listRowBackground(Color.nativeSystemGroupedBackground)
            }
        }

        if !store.showsHistory, !store.showsHotSearch {
            NativeEmptyPlaceholder(
                title: store.route.isMemberRestricted ? "搜索创作" : "搜索知乎",
                subtitle: store.route.isMemberRestricted ? "输入关键词搜索 \(store.memberDisplayName) 的创作" : "输入关键词搜索问题、回答、想法或文章",
                systemImage: "magnifyingglass"
            )
            .listRowBackground(Color.nativeSystemGroupedBackground)
        } else if store.showsHistory, store.history.isEmpty,
                  (!store.showsHotSearch || (!store.isRefreshingSuggestions && store.suggestions.isEmpty && store.suggestionErrorMessage == nil)) {
            NativeEmptyPlaceholder(
                title: "暂无搜索历史",
                subtitle: "搜索过的内容会自动保存在这里，方便快速再次查找",
                systemImage: "clock.arrow.circlepath"
            )
            .listRowBackground(Color.nativeSystemGroupedBackground)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if store.route.isMemberRestricted {
            Text("以下结果来自 \(store.memberDisplayName) 的创作")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        ForEach(visibleItems) { item in
            FeedItemRow(item: item, showsThumbnail: true, onOpen: onOpen)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }

        if let error = store.resultErrorMessage {
            NativeInlineRetry(message: error) {
                Task { await store.retryResults() }
            }
        } else if store.canLoadNextPage {
            NativeLoadingRow("正在加载更多")
                .task { await store.loadNextPage() }
        } else if visibleItems.isEmpty, !store.isLoadingResults {
            NativeEmptyPlaceholder(
                title: "没有找到相关内容",
                subtitle: "换个关键词试试看吧",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private var filterMenu: some View {
        Menu {
            Picker("排序", selection: sortBinding) {
                ForEach(SearchSort.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("内容类型", selection: contentTypeBinding) {
                ForEach(SearchContentType.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("时间范围", selection: timeRangeBinding) {
                ForEach(SearchTimeRange.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
        } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(store.submittedQuery.isEmpty)
    }

    private var historyRows: [SearchHistoryRow] {
        var occurrences: [String: Int] = [:]
        return store.history.map { query in
            let occurrence = occurrences[query, default: 0]
            occurrences[query] = occurrence + 1
            return SearchHistoryRow(query: query, occurrence: occurrence)
        }
    }

    private var sortBinding: Binding<SearchSort> {
        Binding(
            get: { store.sort },
            set: { value in Task { await store.updateSort(value) } }
        )
    }

    private var contentTypeBinding: Binding<SearchContentType> {
        Binding(
            get: { store.contentType },
            set: { value in Task { await store.updateContentType(value) } }
        )
    }

    private var timeRangeBinding: Binding<SearchTimeRange> {
        Binding(
            get: { store.timeRange },
            set: { value in Task { await store.updateTimeRange(value) } }
        )
    }
}

private struct SearchInteractivePopKeyboardBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SearchInteractivePopObserverController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class SearchInteractivePopObserverController: UIViewController {
    private weak var observedGesture: UIGestureRecognizer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard observedGesture == nil,
              let gesture = navigationController?.interactivePopGestureRecognizer
        else { return }
        gesture.addTarget(self, action: #selector(interactivePopChanged(_:)))
        observedGesture = gesture
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observedGesture?.removeTarget(self, action: #selector(interactivePopChanged(_:)))
        observedGesture = nil
    }

    @objc private func interactivePopChanged(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        view.window?.endEditing(true)
    }
}

private struct SearchHistoryRow: Identifiable {
    struct ID: Hashable {
        let query: String
        let occurrence: Int
    }

    let query: String
    let occurrence: Int

    var id: ID { ID(query: query, occurrence: occurrence) }
}
