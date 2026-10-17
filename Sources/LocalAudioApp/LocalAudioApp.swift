import SwiftUI
import AppKit
import LocalAudioCore

@main
struct LocalAudioApp: App {
    @StateObject private var store: AppStore
    @NSApplicationDelegateAdaptor(LocalAudioDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    init() {
        do {
            let paths = try LaunchPaths.parse(Array(CommandLine.arguments.dropFirst()))
            _store = StateObject(wrappedValue: AppStore(paths: paths))
        }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(2) }
    }

    var body: some Scene {
        Window("LocalAudio", id: "main") {
            RootView(store: store)
                .tint(Color.accentTeal)
                .frame(minWidth: 1020, minHeight: 680)
                .onAppear { delegate.store = store }
                .task { await store.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Audio…") { store.importFiles() }.keyboardShortcut("i")
                    .disabled(store.isShuttingDown || store.isImporting || store.isLibraryLoading)
            }
            RecordingCommands(store: store)
        }
        Settings { SettingsView(store: store).tint(Color.accentTeal) }
        MenuBarExtra {
            MenuBarView(store: store, showWindow: { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) })
        } label: {
            RecordingMenuIcon(capture: store.capture)
        }
    }
}

struct RecordingCommands: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject private var capture: CaptureController
    init(store: AppStore) { self.store = store; capture = store.capture }
    var body: some Commands {
        CommandMenu("Recording") {
            Button("Start Recording") { Task { await store.startRecording() } }
                .disabled(store.isShuttingDown || capture.isRecording || capture.isStarting || capture.isFinalizing)
            Button("Stop & Save") { Task { await capture.stop() } }
                .disabled(!capture.isRecording && !capture.isStarting)
        }
    }
}

struct RecordingMenuIcon: View {
    @ObservedObject var capture: CaptureController
    var body: some View { Image(systemName: capture.isRecording ? "record.circle.fill" : "waveform") }
}

final class LocalAudioDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminationPending = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in await store.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MenuBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var capture: CaptureController
    let showWindow: () -> Void
    init(store: AppStore, showWindow: @escaping () -> Void) { self.store = store; capture = store.capture; self.showWindow = showWindow }
    var body: some View {
        Text(capture.isRecording ? "Recording · " + clock(capture.elapsed) : "LocalAudio")
        Button("Show LocalAudio", action: showWindow).disabled(store.isShuttingDown)
        Divider()
        if capture.isRecording || capture.isStarting {
            Button("Stop & Save") { Task { await capture.stop() } }
        } else {
            Button("Start Recording") { Task { await store.startRecording() } }.disabled(capture.isFinalizing || store.isShuttingDown)
        }
        Divider()
        Button("Quit LocalAudio") { NSApp.terminate(nil) }
    }
}
