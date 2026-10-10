import SwiftUI

struct OfflineManagerView: View {
    @State private var manifests: [OfflineQuestionManifest] = []
    @State private var totalSizeString: String = "正在计算..."
    @State private var showsDeleteAllAlert = false
    @StateObject private var downloadManager = OfflineDownloadManager.shared

    var body: some View {
        List {
            // 顶部统计与下载状态
            Section {
                HStack {
                    Text("离线已用存储空间")
                    Spacer()
                    Text(totalSizeString)
                        .foregroundStyle(.secondary)
                }

                if case let .downloading(_, progress, message) = downloadManager.state {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("正在下载")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.0f%%", progress * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("离线缓存包含问题描述、指定数量的高赞回答全文及配图。无网络（如飞行模式）下可自由畅读。")
            }
            .listRowBackground(Color.nativeSecondarySystemGroupedBackground)

            // 缓存问题列表
            Section("已缓存问题 (\(manifests.count))") {
                if manifests.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("暂无离线内容")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("在任意问题详情页右上角点击下载按钮，即可将问题及多条高赞回答缓存至本地。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(manifests) { manifest in
                        NavigationLink(value: NativeShellRoute.offlineReader(manifest.questionID)) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(manifest.title)
                                    .font(.headline)
                                    .lineLimit(2)

                                HStack(spacing: 8) {
                                    Label("\(manifest.cachedAnswerCount) 条回答", systemImage: "doc.text")
                                    Text("·")
                                    Text(manifest.cachedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: deleteManifests)
                }
            }
            .listRowBackground(Color.nativeSecondarySystemGroupedBackground)

            // 清理按钮
            if !manifests.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showsDeleteAllAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("清空所有离线缓存")
                            Spacer()
                        }
                    }
                }
                .listRowBackground(Color.nativeSecondarySystemGroupedBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.nativeSystemGroupedBackground.ignoresSafeArea())
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reloadData()
        }
        .onChange(of: downloadManager.activeQuestionID) { _, activeID in
            if activeID == nil {
                Task { await reloadData() }
            }
        }
        .alert("确认清空所有离线缓存？", isPresented: $showsDeleteAllAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task {
                    await OfflineStorageService.shared.deleteAll()
                    await reloadData()
                }
            }
        } message: {
            Text("将删除本地保存的所有离线问题、回答以及配图。")
        }
    }

    private func reloadData() async {
        manifests = await OfflineStorageService.shared.allManifests()
        let bytes = await OfflineStorageService.shared.calculateTotalCacheSize()
        totalSizeString = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func deleteManifests(at offsets: IndexSet) {
        for index in offsets {
            let item = manifests[index]
            Task {
                await OfflineStorageService.shared.deleteQuestion(questionID: item.questionID)
                await reloadData()
            }
        }
    }
}
