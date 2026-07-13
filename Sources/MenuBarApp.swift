// Claude-O-Meter — menu bar variant. Colored usage ring + session percentage
// in the menu bar; click opens the usage panel.

import AppKit
import SwiftUI

@main
struct ClaudeOMeterApp: App {
    @StateObject private var model: UsageModel

    init() {
        handleLoginItemFlagAndExitIfPresent()
        if CommandLine.arguments.contains("--check") {
            runCheckAndExit()
        }
        _model = StateObject(wrappedValue: UsageModel())
        // No Dock icon even when the bare binary is run outside the .app bundle.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: Ring.image(percent: model.hasError ? nil : model.sessionPercent))
            Text(model.menuText)
        }
        .menuBarExtraStyle(.window)
    }
}
