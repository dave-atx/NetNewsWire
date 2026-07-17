// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "MinifluxAPI",
	platforms: [.macOS(.v15), .iOS(.v17), .watchOS(.v26)],
	products: [
		.library(
			name: "MinifluxAPI",
			type: .dynamic,
			targets: ["MinifluxAPI"])
	],
	dependencies: [
		.package(path: "../RSWeb"),
		.package(path: "../RSParser"),
		.package(path: "../Secrets")
	],
	targets: [
		.target(
			name: "MinifluxAPI",
			dependencies: [
				"RSWeb",
				"RSParser",
				"Secrets"
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		),
		.testTarget(
			name: "MinifluxAPITests",
			dependencies: ["MinifluxAPI"],
			resources: [
				.copy("JSON")
			],
			swiftSettings: [.swiftLanguageMode(.v6)]
		)
	]
)
