import AppKit
import Combine

struct AppIconRequest: Hashable, Sendable {
    let bundleIdentifier: String?
    let bundlePath: String?

    init?(bundleIdentifier: String?, bundlePath: String?) {
        self.bundleIdentifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        self.bundlePath = bundlePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard self.bundlePath != nil || self.bundleIdentifier != nil else { return nil }
    }

    var key: String { bundlePath.map { "path:\($0)" } ?? "id:\(bundleIdentifier!)" }
}

@MainActor
final class AppIconModel: ObservableObject, Identifiable {
    let request: AppIconRequest
    nonisolated var id: String { request.key }
    @Published private(set) var image: NSImage?
    private var fingerprint: Data?
    fileprivate var readers = 0
    fileprivate var generation = 0
    fileprivate var lastUse = 0

    init(request: AppIconRequest, image: NSImage?) {
        self.request = request
        self.image = image
    }

    fileprivate func apply(_ artwork: AppIconArtwork) {
        guard fingerprint != artwork.fingerprint else { return }
        fingerprint = artwork.fingerprint
        // Publish a new, already rasterized image. Never mutate an NSWorkspace image
        // that may be shared elsewhere, and never decode artwork in a hover frame.
        image = NSImage(cgImage: artwork.image, size: NSSize(width: 128, height: 128))
    }
}

/// Shared lookup work, with independent publications for each application's artwork.
/// Views retain their model while mounted; cached access itself performs no refresh.
@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()
    typealias Read = @Sendable ([AppIconRequest]) async -> [AppIconArtwork?]
    private var models: [String: AppIconModel] = [:]
    // A view may still own a model after its inactive cache slot is evicted.
    // Reuse it if that view returns instead of creating two publishers for one app.
    private var references: [String: WeakAppIconModel] = [:]
    private var pending: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var useCounter = 0
    private let initialImage: (AppIconRequest) -> NSImage?
    private let read: Read
    private let refreshInterval: Duration
    private let cacheLimit: Int
    private let observesWorkspace: Bool
    private let notificationCenter: NotificationCenter

    init(refreshInterval: Duration = .seconds(5), cacheLimit: Int = 128,
         observesWorkspace: Bool = true,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         initialImage: @escaping (AppIconRequest) -> NSImage? = AppIconSource.bundleImage,
         read: @escaping Read = AppIconSource.read) {
        self.refreshInterval = refreshInterval
        self.cacheLimit = max(cacheLimit, 0)
        self.observesWorkspace = observesWorkspace
        self.notificationCenter = notificationCenter
        self.initialImage = initialImage
        self.read = read
    }

    func model(for request: AppIconRequest) -> AppIconModel {
        useCounter += 1
        if let model = models[request.key] ?? references[request.key]?.value {
            model.lastUse = useCounter
            models[request.key] = model
            if models.count > cacheLimit { pruneCache() }
            return model
        }
        // Preserve the existing first-render bundle fallback; subsequent lookups and
        // all periodic refresh/rasterization work run on the utility executor.
        let model = AppIconModel(request: request, image: initialImage(request))
        model.lastUse = useCounter
        models[request.key] = model
        references[request.key] = WeakAppIconModel(model)
        if models.count > cacheLimit { pruneCache() }
        return model
    }

    func retain(_ model: AppIconModel) {
        models[model.id] = model
        model.readers += 1
        guard model.readers == 1 else { return }
        model.generation += 1
        pending.insert(model.id)
        startPollingIfNeeded()
        startRefreshIfNeeded()
    }

    func release(_ model: AppIconModel) {
        guard model.readers > 0 else { return }
        model.readers -= 1
        guard model.readers == 0 else { return }
        model.generation += 1
        pending.remove(model.id)
        if !models.values.contains(where: { $0.readers > 0 }) {
            generation += 1
            pollingTask?.cancel()
            pollingTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            for observer in observers { notificationCenter.removeObserver(observer) }
            observers = []
        }
        pruneCache()
    }

    func requestRefresh(bundlePath: String? = nil, bundleIdentifier: String? = nil) {
        for model in models.values where model.readers > 0 {
            if let bundlePath {
                guard model.request.bundlePath == bundlePath ||
                    (model.request.bundlePath == nil && model.request.bundleIdentifier == bundleIdentifier) else { continue }
            } else if let bundleIdentifier {
                guard model.request.bundleIdentifier == bundleIdentifier else { continue }
            }
            pending.insert(model.id)
        }
        startRefreshIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        let interval = refreshInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                self.requestRefresh()
            }
        }
        guard observesWorkspace else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let path = app?.bundleURL?.standardizedFileURL.path
                let identifier = app?.bundleIdentifier
                guard path != nil || identifier != nil else { return }
                Task { @MainActor [weak self] in self?.requestRefresh(bundlePath: path, bundleIdentifier: identifier) }
            })
        }
    }

    private func startRefreshIfNeeded() {
        guard refreshTask == nil, !pending.isEmpty else { return }
        let generation = generation
        let read = read
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.generation == generation {
                let batch = self.pending.compactMap { self.models[$0] }.filter { $0.readers > 0 }
                self.pending.removeAll()
                guard !batch.isEmpty else { break }
                let versions = batch.map(\.generation)
                let artwork = await read(batch.map(\.request))
                guard !Task.isCancelled, self.generation == generation else { return }
                for (index, result) in artwork.enumerated() where index < batch.count {
                    let model = batch[index]
                    guard let result, self.models[model.id] === model, model.readers > 0,
                          model.generation == versions[index] else { continue }
                    model.apply(result)
                }
            }
            guard let self, self.generation == generation else { return }
            self.refreshTask = nil
            self.pruneCache()
        }
    }

    private func pruneCache() {
        let inactive = models.values.filter { $0.readers == 0 }.sorted { $0.lastUse < $1.lastUse }
        for model in inactive.prefix(max(models.count - cacheLimit, 0)) { models.removeValue(forKey: model.id) }
        references = references.filter { $0.value.value != nil }
    }
}

@MainActor
private final class WeakAppIconModel {
    weak var value: AppIconModel?
    init(_ value: AppIconModel) { self.value = value }
}

/// Native resize previews take a cached snapshot once per gesture.
@MainActor
func appIconImage(bundleIdentifier: String?, bundlePath: String?) -> NSImage? {
    guard let request = AppIconRequest(bundleIdentifier: bundleIdentifier, bundlePath: bundlePath) else { return nil }
    return AppIconProvider.shared.model(for: request).image
}
