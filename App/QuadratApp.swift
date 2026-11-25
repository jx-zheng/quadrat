import AppKit
import QuadratCore
import SwiftUI

@main
struct QuadratApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Reveal in Finder") { delegate.model.revealSelection() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Move to Trash…") { delegate.model.askTrash() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Divider()
                Button("Zoom Out") { delegate.model.zoomOut() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
            }
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Sizes", selection: Binding(get: { model.metric }, set: { model.setMetric($0) })) {
                Text("On Disk").tag(SizeMetric.allocated)
                Text("Logical").tag(SizeMetric.logical)
            }
            Text("On Disk is the space the file occupies. Logical is the size you would copy, so sparse disk images stay honest. Both are kept from the scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let out = argument("--pixel-check", in: args) {
            SnapshotRunner.renderLeafProbe(to: out)
            exit(0)
        }
        if let directory = argument("--snapshot-suite", in: args) {
            SnapshotRunner.renderSuite(into: directory)
            exit(0)
        }
        if let path = argument("--snapshot-path", in: args), let out = argument("--snapshot-out", in: args) {
            let scheme: ColorScheme = argument("--snapshot-scheme", in: args) == "dark" ? .dark : .light
            SnapshotRunner.render(path: path, to: out, scheme: scheme, drill: args.contains("--snapshot-drill"))
            exit(0)
        }
        if args.contains("--zoom-wide") {
            PerfRunner.runWideZoom(arguments: args)
            exit(0)
        }
        if let path = argument("--perf-path", in: args) {
            PerfRunner.runPath(directory: path, arguments: args)
            exit(0)
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            SnapshotRunner.render(into: args[index + 1])
            exit(0)
        }
        if let index = args.firstIndex(of: "--perf"), index + 1 < args.count {
            PerfRunner.run(directory: args[index + 1], arguments: args)
            exit(0)
        }
        if args.contains("--demo") {
            DemoRunner.start(model: model)
            return
        }
        model.refreshVolumes()
    }

    private func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheckAccess()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model.scanFolder(url)
    }
}
