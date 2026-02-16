// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordpressMediaUploader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "WordpressMediaUploaderApp",
            targets: ["WordpressMediaUploaderApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WordpressMediaUploaderApp",
            path: "Sources/WordpressImageUploaderApp",
            exclude: ["Assets.xcassets", "Info.plist", "WPMediaUploader.entitlements"]
        ),
        .testTarget(
            name: "WordpressMediaUploaderAppTests",
            dependencies: ["WordpressMediaUploaderApp"],
            path: "Tests"
        )
    ]
)
