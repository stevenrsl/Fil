// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fil", targets: ["Fil"])
    ],
    targets: [
        // Pont minimal vers la libcurl livrée avec macOS (FTP, FTPS). Aucune bibliothèque embarquée.
        .target(name: "CCurl", linkerSettings: [.linkedLibrary("curl")]),
        .executableTarget(name: "Fil", dependencies: ["CCurl"]),
        .testTarget(name: "FilTests", dependencies: ["Fil", "CCurl"])
    ]
)
