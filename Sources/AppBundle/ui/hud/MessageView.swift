import Common
import SwiftUI

@MainActor
public func getMessageWindow(messageModel: MessageModel) -> some Scene {
    // Using SwiftUI.Window because another class in WinMux is already called Window
    SwiftUI.Window(messageModel.detailMessage?.title ?? winMuxAppName, id: messageWindowId) {
        MessageView(model: messageModel)
            .onAppear {
                // Set activation policy; otherwise, WinMux windows won't be able to receive focus and accept keyboard input
                NSApp.setActivationPolicy(.accessory)
                NSApplication.shared.windows.forEach {
                    if $0.identifier?.rawValue == messageWindowId {
                        $0.level = WinMuxPanelLayer.overlay.level
                        $0.styleMask.remove(.miniaturizable) // Disable minimize button, because we don't unminimize the window on config error
                    }
                }
            }
        // .windowMinimizeBehavior(WindowInteractionBehavior.disabled) // SwiftUI way of hiding minimize button. Available only since macOS 15
    }
    .windowResizability(.contentMinSize)
    //.windowLevel(.floating) //This might be the SwiftUI way of doing window level instead of the onAppear block above, but it's only available from macOS 15.0
}

public let messageWindowId = "\(winMuxAppName).messageView"

struct MessageView: View {
    @StateObject private var model: MessageModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    @FocusState var focus: Bool

    init(model: MessageModel) {
        self._model = .init(wrappedValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .center) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 48))
                Text("\(model.detailMessage?.description ?? "")")
                    .padding(.horizontal)
                    .focusable()
            }
            .padding()
            ScrollView {
                VStack(alignment: .leading) {
                    HStack {
                        let cancelOnEnterBinding: Binding<String> = Binding(
                            get: { model.detailMessage?.body ?? "" },
                            set: { newText in
                                if let prev = model.detailMessage?.body.count(where: \.isNewline), newText.count(where: \.isNewline) > prev {
                                    model.detailMessage = nil
                                }
                            },
                        )
                        TextEditor(text: cancelOnEnterBinding)
                            .font(.system(size: 12).monospaced())
                            .focused($focus)
                        //  .onKeyPress(.return) { return .handled } // enter handling alternative. Only available since macOS 14
                        Spacer()
                    }
                    Spacer()
                }
                .padding()
            }
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal)
            HStack {
                Spacer()
                if let message = model.detailMessage {
                    ForEach(message.actions) { action in
                        Button(action.title) { action.perform() }
                            .disabled(!action.isAvailable())
                    }
                }
                if let type = model.detailMessage?.type {
                    switch type {
                        case .config:
                            reloadConfigButton(showShortcutGroup: true)
                            openConfigButton(showShortcutGroup: true)
                    }
                }
                let closeButton = Button("Close") { model.detailMessage = nil }.keyboardShortcut(.defaultAction)
                shortcutGroup(label: Image(systemName: "return.left"), content: closeButton)
            }
            .padding()
        }
        .textSelection(.enabled)
        .frame(minWidth: 480, maxWidth: 960, minHeight: 200)
        .onChange(of: model.detailMessage) { message in
            if message == nil {
                self.dismiss()
            }
        }
        .onDisappear {
            // If user closes the screen with the macOS native close (x) button and then the error is still the same, this window will not appear again
            model.detailMessage = nil
        }
        .onAppear {
            focus = true
        }
    }
}

@MainActor
public final class MessageModel: ObservableObject {
    @MainActor public static let shared = MessageModel()
    /// Incoming GUI errors always go through the toast. This remains separate from the
    /// deliberately opened diagnostic, so later failures cannot replace its contents.
    @Published public var message: Message? = nil {
        didSet {
            if let message { report(message) }
        }
    }
    @Published public var detailMessage: Message? = nil
    @Published public private(set) var detailRequestId = 0

    private init() {}

    @MainActor private func report(_ message: Message) {
        WinMuxToastPanel.shared.show(.init(title: message.description, body: message.body, details: message))
    }

    @MainActor func openDetails(_ message: Message) {
        detailMessage = message
        detailRequestId += 1
    }
}

public enum MessageType {
    case config
}

public struct Message: Hashable, Equatable {
    public let type: MessageType
    public let title: String
    public let description: String
    public let body: String
    let actions: [MessageAction]

    init(type: MessageType = .config, title: String = winMuxAppName, description: String, body: String, actions: [MessageAction] = []) {
        self.type = type
        self.title = title
        self.description = description
        self.body = body
        self.actions = actions
    }
}

/// Recovery controls keep the original operation's identity. Their guard is checked again
/// on activation, so an old diagnostic cannot retry or revert a newer edit.
struct MessageAction: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let isAvailable: @MainActor () -> Bool
    let perform: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
