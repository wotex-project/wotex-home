import SwiftUI

enum HomeLayoutProfile: String, Sendable {
    case compact, medium, expanded
    static func forWidth(_ width: CGFloat) -> Self { width < 600 ? .compact : width < 840 ? .medium : .expanded }
}

enum HomeTask: String, CaseIterable, Identifiable {
    case things, rules, activity, setup
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .things: "lightbulb"; case .rules: "slider.horizontal.3"; case .activity: "list.bullet.rectangle"; case .setup: "gearshape" }
    }
    var brief: String {
        switch self {
        case .things: "Select an enrolled Thing. Inspect its evidence before requesting a change."
        case .rules: "Draft one explicit power action. Review and confirm each rule decision separately."
        case .activity: "Read receipts and reconcile the original request after an uncertain outcome."
        case .setup: "Enable the local controller, select a session, review a device and separately grant access."
        }
    }
    var shortcut: KeyEquivalent {
        switch self { case .things: "1"; case .rules: "2"; case .activity: "3"; case .setup: "4" }
    }
}

struct HomeTaskShell<Attention: View, Content: View>: View {
    @Binding var task: HomeTask
    let availability: String, session: String
    @ViewBuilder var attention: () -> Attention
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            let profile = HomeLayoutProfile.forWidth(geometry.size.width)
            let layout = profile == .expanded ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WoTEx Home").font(.title).accessibilityAddTraits(.isHeader)
                    Text(availability).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(session).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                layout {
                    navigation(profile)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            attention()
                            Text(task.title).font(.title2).accessibilityAddTraits(.isHeader)
                            Text(task.brief).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Divider()
                            content()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(profile == .compact ? 16 : 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    private func navigation(_ profile: HomeLayoutProfile) -> some View {
        let layout = profile == .expanded ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ForEach(HomeTask.allCases) { item in
                Button { task = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: profile == .expanded ? .leading : .center)
                        .padding(8)
                        .background(task == item ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).keyboardShortcut(item.shortcut)
                    .accessibilityLabel(item.title).accessibilityValue(task == item ? "Selected" : "")
                    .accessibilityAddTraits(task == item ? .isSelected : [])
                    .accessibilityIdentifier("home-task-" + item.rawValue)
            }
        }.frame(width: profile == .expanded ? 180 : nil, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel("Home tasks")
    }
}
