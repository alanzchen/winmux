// swift-tools-version: 6.0
// TOMLDecoder 0.4.5 (https://github.com/dduan/TOMLDecoder, a2bbd279), library target only, with WinMux's patch.
// See WINMUX-PATCH.md.

import PackageDescription

let package = Package(
    name: "TOMLDecoder",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "TOMLDecoder", targets: ["TOMLDecoder"]),
    ],
    targets: [
        .target(
            name: "TOMLDecoder",
            exclude: ["gyb"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ]
)
