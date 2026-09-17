import AppBundle
import Foundation

@main
struct MarketingRendererCommand {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--sidebar-dock-proof") {
            try showSidebarDockProof(arguments: Array(arguments))
            return
        }
        let isSafariProof = arguments.contains("--safari-proof")
        let isAppsProof = arguments.contains("--apps-proof")
        let isSafariPlasticityProof = arguments.contains("--safari-plasticity-proof")
        let outputPath = arguments.first(where: { !$0.hasPrefix("--") })
            ?? "resources/marketing/winmux-card-collage-swiftui.png"
        let outputURL = URL(fileURLWithPath: outputPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if isSafariPlasticityProof {
            try renderWinMuxSafariPlasticityProofImage(to: outputURL)
        } else if isAppsProof {
            try renderWinMuxAppsProofImage(to: outputURL)
        } else if isSafariProof {
            try renderWinMuxSafariProofImage(to: outputURL)
        } else {
            try renderWinMuxMarketingImage(to: outputURL)
        }
        print(outputURL.path)
    }

    @MainActor
    private static func showSidebarDockProof(arguments: [String]) throws {
        if arguments.contains("--help") {
            print("""
            Usage: winmux-marketing-renderer --sidebar-dock-proof [options]
              --width POINTS       Fixed compact sidebar width (default: 64)
              --expanded-width N   Fully expanded sidebar width (default: 240)
              --expansion N        Expansion progress from 0 to 1 (default: 0)
              --height POINTS      Window height (default: 360)
              --icon-size POINTS   Dock icon size, 24...48 (default: 40)
              --magnification N    Enable Dock magnification: 0 or 1 (default: 0)
              --pointer-y POINTS   Simulated pointer in sidebar coordinates for capture
              --glass-opacity N   Glass opacity, 0...1 (default: 1)
              --appearance NAME   light or dark (default: dark)
              --origin-x POINTS    Window origin; requires --origin-y
              --origin-y POINTS    AppKit screen points, measured from the lower left
              --hold-seconds N     Keep the live window visible (default: 30)
              --output PATH        Also capture only the proof window to a PNG
              --backdrop PATH      Composite an image beneath the live sidebar glass;
                                   image fills the requested width and height in points
            Prints the live window ID and frame as JSON. Uses sample workspaces and
            production sidebar views without starting the window manager.
            """)
            return
        }
        let allowed = Set(["--width", "--expanded-width", "--expansion", "--height", "--origin-x", "--origin-y", "--hold-seconds", "--output", "--backdrop", "--icon-size", "--magnification", "--pointer-y", "--glass-opacity", "--appearance"])
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--sidebar-dock-proof" {
                index += 1
                continue
            }
            guard allowed.contains(option), index + 1 < arguments.count,
                  options[option] == nil, !arguments[index + 1].hasPrefix("--") else {
                throw ProofArgumentsError.invalid("Invalid or missing value for \(option). Use --sidebar-dock-proof --help.")
            }
            options[option] = arguments[index + 1]
            index += 2
        }
        func number(_ option: String, default fallback: Double) throws -> Double {
            guard let raw = options[option] else { return fallback }
            guard let value = Double(raw), value.isFinite else {
                throw ProofArgumentsError.invalid("\(option) requires a finite number.")
            }
            return value
        }
        let width = try number("--width", default: 64)
        let expandedWidth = try number("--expanded-width", default: 240)
        let expansion = try number("--expansion", default: 0)
        let height = try number("--height", default: 360)
        let holdDuration = try number("--hold-seconds", default: 30)
        let iconSize = try number("--icon-size", default: 40)
        let magnification = try number("--magnification", default: 0)
        let pointerY: Double? = try options["--pointer-y"].map { _ in try number("--pointer-y", default: 0) }
        let glassOpacity = try number("--glass-opacity", default: 1)
        let appearance = options["--appearance"] ?? "dark"
        guard (24...48).contains(iconSize), [0.0, 1.0].contains(magnification),
              (0...1).contains(glassOpacity), ["light", "dark"].contains(appearance) else {
            throw ProofArgumentsError.invalid("Invalid icon size, magnification, glass opacity, or appearance.")
        }
        guard width > 0, height > 0, holdDuration >= 0 else {
            throw ProofArgumentsError.invalid("Width and height must be positive; hold duration must be nonnegative.")
        }
        guard expandedWidth > width, (0...1).contains(expansion) else {
            throw ProofArgumentsError.invalid("Expanded width must exceed compact width; expansion must be from 0 to 1.")
        }
        guard (options["--origin-x"] == nil) == (options["--origin-y"] == nil) else {
            throw ProofArgumentsError.invalid("Specify both --origin-x and --origin-y.")
        }
        let origin: CGPoint? = try options["--origin-x"].map { _ in
            CGPoint(x: try number("--origin-x", default: 0), y: try number("--origin-y", default: 0))
        }
        let captureURL = options["--output"].map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        }
        let backdropURL = options["--backdrop"].map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        }
        try showWinMuxSidebarDockProof(
            width: width,
            height: height,
            origin: origin,
            holdDuration: holdDuration,
            captureURL: captureURL,
            backdropURL: backdropURL,
            expandedWidth: expandedWidth,
            expansion: expansion,
            iconSize: iconSize,
            magnification: magnification == 1,
            pointerY: pointerY.map { CGFloat($0) },
            glassOpacity: glassOpacity,
            darkAppearance: appearance == "dark"
        )
    }
}

private enum ProofArgumentsError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
            case .invalid(let message): message
        }
    }
}
