import AppKit
import SwiftUI

@MainActor final class ShellFixtureModel: ObservableObject {
    @Published var task: HomeTask = .things
    @Published var draft = "light:retained-fixture"
    @Published var confirmed = true
    @Published var capability = "power"
    var lookups = 0
}
struct ShellFixtureView: View {
    @ObservedObject var model: ShellFixtureModel
    let accessible: Bool
    let dark: Bool
    var body: some View {
        HomeTaskShell(task: $model.task, availability: "Controller unavailable · Reconcile the original request", session: "Fixture Operator · Authority 7") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Outcome unknown · Original operation retained").font(.headline)
                Text("light:retained-fixture · Power On · Operation fixture:original").textSelection(.enabled)
                Button("Look Up Original") { model.lookups += 1 }
            }
        } content: {
            HomeSection(title: "Selected Thing") {
                TextField("Draft fixture", text: $model.draft).textFieldStyle(.roundedBorder).accessibilityIdentifier("layout-draft")
                Picker("Selected capability", selection: $model.capability) { Text("Power").tag("power"); Text("Brightness").tag("brightness") }
                Toggle("Reviewed decision", isOn: $model.confirmed)
                Text("Current: Unknown").font(.title2)
                Text("Stored: On · stale · synthetic lab").foregroundStyle(.orange)
                Text("No new command or device result is inferred from this retained evidence.").fixedSize(horizontal: false, vertical: true)
            }
        }.environment(\.colorScheme, dark ? .dark : .light)
            .contrast(accessible ? 1.5 : 1)
            .font(accessible ? .title3 : .body)
            .dynamicTypeSize(accessible ? .accessibility3 : .large)
    }
}
enum ShellAssertion: Error { case failed(Int) }

@main struct HomeTaskShellSmoke {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw ShellAssertion.failed(#line) }
            _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
            for dark in [false, true] {
                for accessible in [false, true] { try await check(path: CommandLine.arguments[1], accessible: accessible, dark: dark) }
            }
            print("{\"complete\":true}")
        } catch ShellAssertion.failed(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false}") }
    }
    @MainActor private static func check(path: String, accessible: Bool, dark: Bool) async throws {
        let model = ShellFixtureModel()
        let hosting = NSHostingView(rootView: ShellFixtureView(model: model, accessible: accessible, dark: dark))
        hosting.frame = NSRect(x: 0, y: 0, width: 599, height: 720)
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        guard let field = fields(hosting).first(where: { $0.placeholderString == "Draft fixture" }), window.makeFirstResponder(field) else { throw ShellAssertion.failed(#line) }
        let originalResponder = window.firstResponder
        for (width, expected) in [(599, HomeLayoutProfile.compact), (600, .medium), (839, .medium), (840, .expanded), (599, .compact)] {
            guard HomeLayoutProfile.forWidth(CGFloat(width)) == expected else { throw ShellAssertion.failed(#line) }
            window.setContentSize(NSSize(width: width, height: 720))
            try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
            guard model.task == .things, model.draft == "light:retained-fixture", model.confirmed, model.capability == "power", model.lookups == 0,
                  fields(hosting).contains(where: { $0 === field }), window.firstResponder === originalResponder else { throw ShellAssertion.failed(#line) }
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ShellAssertion.failed(#line) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw ShellAssertion.failed(#line) }
            try bytes.write(to: URL(fileURLWithPath: path + "/task-shell-\(dark ? "dark-" : "")\(accessible ? "accessible" : "standard")-\(width).png"))
        }
    }
    @MainActor private static func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap(fields)
    }
}
