import AppKit
import SwiftUI

@main
struct AppleBeatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppDelegate.model

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(nsImage: model.enabled && !model.beatLit ? MenuIcon.dim : MenuIcon.lit)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = BeatModel()

    func applicationWillTerminate(_ notification: Notification) {
        Self.model.shutdown()
    }
}

/// The menu bar apple, resting and on a beat.
enum MenuIcon {
    static let lit = make(alpha: 1)
    static let dim = make(alpha: 0.4)

    private static func make(alpha: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "AppleBeat")?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuView: View {
    @ObservedObject var model: BeatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "apple.logo")
                    .font(.title2)
                    .opacity(model.enabled && !model.beatLit ? 0.35 : 1)
                    .animation(.easeOut(duration: model.beatLit ? 0.03 : 0.25), value: model.beatLit)
                Text("AppleBeat").font(.headline)
                Spacer()
                Toggle("Beat with music", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !model.hasLogo {
                note("This Mac's logo light can't be controlled, so only the menu bar apple beats.")
            } else if model.logoSwitchedOff {
                HStack {
                    note("The logo light is switched off in macOS.")
                    Button("Turn On") { model.switchLogoOn() }
                }
            }
            if let problem = model.problem {
                note(problem)
            }

            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: model.level)
                    .tint(.primary)
                    .animation(.linear(duration: 0.05), value: model.level)
                slider("Sensitivity", $model.sensitivity, 0...1)
                slider("Brightness", $model.brightness, 0.2...1)
                slider("Fade", $model.fade, 0.12...1.2)
            }
            .disabled(!model.enabled)

            if model.enabled, model.level == 0 {
                note("Hearing nothing. If music is playing, allow AppleBeat under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
            }

            Divider()
            Button("Quit AppleBeat") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 300)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
