// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AMPKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AMPCore", targets: ["AMPCore"]),
        .library(name: "DiscordRPC", targets: ["DiscordRPC"]),
        .library(name: "LastFM", targets: ["LastFM"]),
        .library(name: "Artwork", targets: ["Artwork"]),
        .library(name: "AMPPresence", targets: ["AMPPresence"]),
    ],
    targets: [
        // Pure models and rules: Track, playback state machine, scrobble rules, settings, templates.
        .target(name: "AMPCore"),
        // Discord desktop IPC client. Deliberately has no dependency on the rest of the app.
        .target(name: "DiscordRPC"),
        .target(name: "LastFM", dependencies: ["AMPCore"]),
        .target(name: "Artwork", dependencies: ["AMPCore"]),
        // Turns playback state + settings into a Discord activity.
        .target(name: "AMPPresence", dependencies: ["AMPCore", "DiscordRPC"]),

        .testTarget(name: "AMPCoreTests", dependencies: ["AMPCore"]),
        .testTarget(name: "DiscordRPCTests", dependencies: ["DiscordRPC"]),
        .testTarget(name: "LastFMTests", dependencies: ["LastFM", "AMPCore"]),
        .testTarget(name: "ArtworkTests", dependencies: ["Artwork", "AMPCore"]),
        .testTarget(name: "AMPPresenceTests", dependencies: ["AMPPresence", "AMPCore", "DiscordRPC"]),
    ],
    swiftLanguageModes: [.v6]
)
