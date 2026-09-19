import AppKit
import SwiftUI

/// Observe only this app's artwork, below the Dock's cached layout and motion tree.
struct AppIconView<Content: View>: View {
    private let model: AppIconModel?
    private let provider: AppIconProvider
    private let content: (NSImage?) -> Content

    init(bundleIdentifier: String?, bundlePath: String?, provider: AppIconProvider = .shared,
         @ViewBuilder content: @escaping (NSImage?) -> Content) {
        self.provider = provider
        self.model = AppIconRequest(bundleIdentifier: bundleIdentifier, bundlePath: bundlePath).map { provider.model(for: $0) }
        self.content = content
    }

    var body: some View {
        if let model {
            AppIconContent(model: model, provider: provider, content: content).id(model.id)
        } else {
            content(nil)
        }
    }
}

private struct AppIconContent<Content: View>: View {
    @ObservedObject var model: AppIconModel
    let provider: AppIconProvider
    let content: (NSImage?) -> Content

    var body: some View {
        content(model.image)
            .onAppear { provider.retain(model) }
            .onDisappear { provider.release(model) }
    }
}
