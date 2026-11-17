import SwiftUI

enum MainTab: Hashable, CaseIterable, Identifiable {
    case capture
    case library
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .capture: "홈"
        case .library: "보관함"
        case .settings: "설정"
        }
    }

    var symbol: String {
        switch self {
        case .capture: "house.fill"
        case .library: "hanger"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainTabBar: View {
    @Binding var selection: MainTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: -10) {
            ForEach(MainTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .glassEffect(.regular, in: Capsule())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier("main-tab-bar")
    }

    private func tabButton(_ tab: MainTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 1) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 24, weight: .regular))
                    .frame(height: 28)
                Text(tab.title)
                    .font(.system(size: 10, weight: .medium))
                    .frame(height: 12)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 7)
            .frame(width: 102, height: 54)
            .foregroundStyle(Color(isSelected ? "BrandNeutralBlack" : "BrandNeutral600"))
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .matchedGeometryEffect(id: "main-tab-selection", in: selectionAnimation)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
