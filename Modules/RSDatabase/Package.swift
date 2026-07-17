// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "RSDatabase",
	// watchOS is declared only because ErrorLog (used by Secrets on the watch) links this
	// package; the watch app itself deliberately doesn't use RSDatabase (see
	// Technotes/WatchApp.md, "Platform additions").
	platforms: [.macOS(.v15), .iOS(.v17), .watchOS(.v26)],
	products: [
		.library(
			name: "RSDatabase",
			type: .dynamic,
			targets: ["RSDatabase"]),
		.library(
			name: "RSDatabaseObjC",
			type: .dynamic,
			targets: ["RSDatabaseObjC"])
	],
	dependencies: [
	],
	targets: [
		.target(
			name: "RSDatabase",
			dependencies: ["RSDatabaseObjC"],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		),
		.target(
			name: "RSDatabaseObjC",
			dependencies: []
		),
		.testTarget(
			name: "RSDatabaseTests",
			dependencies: ["RSDatabase", "RSDatabaseObjC"])
	]
)
