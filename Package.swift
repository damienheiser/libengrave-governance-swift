// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EngraveGovernance",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EngraveGovernance", targets: ["EngraveGovernance"]),
    ],
    dependencies: [
        .package(url: "https://github.com/damienheiser/lib-engrave-interposer.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "EngraveGovernance",
            dependencies: [
                .product(name: "EngraveInterposer", package: "lib-engrave-interposer"),
            ],
            path: "Sources/EngraveGovernance"
        ),
    ]
)
