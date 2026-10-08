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
        case .rules: "Draft one explicit or scheduled power action. Review and confirm each decision separately."
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
            let layout = profile == .expanded ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            layout {
                sidebar(profile)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            Text(task.brief).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        attention()
                        content()
                    }.frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(profile == .compact ? 16 : 28)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    private func sidebar(_ profile: HomeLayoutProfile) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("WoTEx Home", systemImage: "house.fill")
                .font(.headline).accessibilityAddTraits(.isHeader)
            navigation(profile)
            if profile == .expanded { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 6) {
                Text(availability).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(session).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(profile == .compact ? 16 : 20)
            .frame(width: profile == .expanded ? 220 : nil, alignment: .topLeading)
            .frame(maxWidth: profile == .expanded ? nil : .infinity, maxHeight: profile == .expanded ? .infinity : nil, alignment: .topLeading)
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: profile == .expanded ? .trailing : .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor))
                    .frame(width: profile == .expanded ? 1 : nil, height: profile == .expanded ? nil : 1)
            }
    }
    private func navigation(_ profile: HomeLayoutProfile) -> some View {
        let layout = profile == .expanded ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ForEach(HomeTask.allCases) { item in
                Button { task = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: profile == .expanded ? .leading : .center)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(task == item ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).keyboardShortcut(item.shortcut)
                    .accessibilityLabel(item.title).accessibilityValue(task == item ? "Selected" : "")
                    .accessibilityAddTraits(task == item ? .isSelected : [])
                    .accessibilityIdentifier("home-task-" + item.rawValue)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel("Home tasks")
    }
}

// Group controls by the decision they belong to; Thing cards remain selectable.
struct HomeSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HomeSettingToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .fixedSize().accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
