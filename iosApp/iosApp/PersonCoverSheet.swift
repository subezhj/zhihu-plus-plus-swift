import SwiftUI

/// 方案 B（小红书式）：用户主页以标准 sheet 呈现；在弹窗内点内容（回答/文章/想法等）时，
/// 先收起弹窗，再让底层导航栈全屏打开对应详情——避免"弹窗覆盖新页面"。
///
/// 可复用于评论、想法、回答等所有"从弹窗进入用户主页"的场景：
/// ```swift
/// .personCoverSheet(item: $personModel, onNavigate: onPersonNavigate)
/// ```
/// - `item`：当前呈现的用户主页 model（置 nil 即收起弹窗）
/// - `onNavigate`：底层导航栈的 PersonNavigationIntent 处理器（弹窗内点击时被转发）
struct PersonCoverSheetModifier: ViewModifier {
    @Binding var item: PersonHostModel?
    let onNavigate: (PersonNavigationIntent) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $item) { model in
                PersonCoverSheetContent(model: model, onNavigate: onNavigate)
            }
    }
}

extension View {
    /// 用户主页弹窗（方案 B）：
    /// 弹窗内点内容会先收起弹窗，再由 `onNavigate` 在底层导航栈全屏打开对应页面。
    func personCoverSheet(
        item: Binding<PersonHostModel?>,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) -> some View {
        modifier(PersonCoverSheetModifier(item: item, onNavigate: onNavigate))
    }
}

private struct PersonCoverSheetContent: View {
    @ObservedObject var model: PersonHostModel
    let onNavigate: (PersonNavigationIntent) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PersonHostView(model: model)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Color.accentColor)
                        }
                        .accessibilityLabel("关闭")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.nativeSystemGroupedBackground)
        .onAppear {
            // 弹窗内导航意图：先收起弹窗，再让底层导航栈全屏打开详情
            model.updateNavigation { intent in
                dismiss()
                onNavigate(intent)
            }
        }
    }
}
