import SwiftUI

struct PersonTabSelector: View {
    let selection: PersonTab
    let onSelect: (PersonTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            tabs
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
                .padding(.horizontal, 4)
        }
        .accessibilityIdentifier("person_main_tabs")
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(PersonTab.profileContentTabs) { tab in
                Button(tab.title) { onSelect(tab) }
                    .font(.subheadline.weight(selection == tab ? .semibold : .regular))
                    .buttonStyle(PersonGlassTabButtonStyle(isSelected: selection == tab))
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .accessibilityIdentifier("person_tab_\(tab.rawValue)")
            }
        }
    }
}

struct PersonSubscriptionTabSelector: View {
    let selection: PersonSubscriptionTab
    let onSelect: (PersonSubscriptionTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PersonSubscriptionTab.allCases) { tab in
                    Button(tab.title) { onSelect(tab) }
                        .font(.caption.weight(selection == tab ? .semibold : .regular))
                        .buttonStyle(PersonGlassTabButtonStyle(isSelected: selection == tab))
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                        .accessibilityIdentifier("person_subscription_tab_\(tab.rawValue)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("person_subscription_tabs")
    }
}

private struct PersonGlassTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .liquidGlassCapsule(isProminent: isSelected, ignoreToggle: true)
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.15 : 0.04), radius: isSelected ? 4 : 2, x: 0, y: isSelected ? 2 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct PersonSortControl: View {
    let selection: PersonContentSort
    let onSelect: (PersonContentSort) -> Void

    var body: some View {
        Picker("排序", selection: Binding(get: { selection }, set: onSelect)) {
            ForEach(PersonContentSort.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 6)
        .accessibilityIdentifier("person_sort_control")
    }
}
