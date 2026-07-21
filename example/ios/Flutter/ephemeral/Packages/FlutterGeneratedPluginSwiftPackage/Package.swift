// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"])
    ],
    dependencies: [
        .package(name: "file_picker", path: "../.packages/file_picker-12.0.0-beta.7"),
        .package(name: "flutter_midi_command", path: "../.packages/flutter_midi_command"),
        .package(name: "universal_ble", path: "../.packages/universal_ble-2.0.4"),
        .package(name: "FlutterFramework", path: "../.packages/FlutterFramework")
    ],
    targets: [
        .target(
            name: "FlutterGeneratedPluginSwiftPackage",
            dependencies: [
                .product(name: "file-picker", package: "file_picker"),
                .product(name: "flutter-midi-command", package: "flutter_midi_command"),
                .product(name: "universal-ble", package: "universal_ble"),
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
