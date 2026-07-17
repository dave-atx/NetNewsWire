//
//  WatchTheme.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

// M3 — see Technotes/WatchApp.md "Theme support on the watch". The .nnwtheme format
// (HTML template + CSS) isn't portable to native rendering, so the watch gets a
// deliberately small native style model. watchOS renders dark-only, so themes carry a
// single palette, tuned for dark backgrounds and legible under always-on dimming.
// Deriving themes from installed .nnwtheme files is a later exploration (v1.5), which is
// why this model is Codable even though v1 only ever instantiates the built-ins.

/// A flat RGB color that can round-trip through Codable (SwiftUI `Color` can't).
struct ThemeColor: Codable, Equatable, Sendable {

	var red: Double
	var green: Double
	var blue: Double

	init(_ red: Double, _ green: Double, _ blue: Double) {
		self.red = red
		self.green = green
		self.blue = blue
	}

	var color: Color {
		Color(red: red, green: green, blue: blue)
	}
}

/// The article body's font family. Themes don't carry sizes — text size follows
/// watchOS Dynamic Type.
enum BodyFont: String, Codable, Sendable {

	case system
	case serif
	case rounded

	var fontDesign: Font.Design {
		switch self {
		case .system:
			return .default
		case .serif:
			return .serif
		case .rounded:
			return .rounded
		}
	}
}

/// A watch reading theme: one dark palette plus a body font. Identified by name; the
/// selected name persists in UserDefaults and resolves via `theme(named:)`, falling back
/// to Default if the stored name is stale.
struct WatchTheme: Codable, Equatable, Sendable, Identifiable {

	var id: String { name }

	var name: String
	var backgroundColor: ThemeColor
	var textColor: ThemeColor
	var secondaryTextColor: ThemeColor
	var accentColor: ThemeColor
	var linkColor: ThemeColor
	var bodyFont: BodyFont
}

// MARK: - Built-in themes

extension WatchTheme {

	static let defaultTheme = WatchTheme(
		name: "Default",
		backgroundColor: ThemeColor(0, 0, 0),
		textColor: ThemeColor(0.95, 0.95, 0.95),
		secondaryTextColor: ThemeColor(0.62, 0.62, 0.62),
		accentColor: ThemeColor(0.26, 0.49, 0.88),
		linkColor: ThemeColor(0.42, 0.63, 1.0),
		bodyFont: .system
	)

	static let sepia = WatchTheme(
		name: "Sepia",
		backgroundColor: ThemeColor(0.11, 0.09, 0.06),
		textColor: ThemeColor(0.91, 0.86, 0.75),
		secondaryTextColor: ThemeColor(0.65, 0.60, 0.50),
		accentColor: ThemeColor(0.85, 0.62, 0.29),
		linkColor: ThemeColor(0.90, 0.71, 0.42),
		bodyFont: .serif
	)

	static let highContrast = WatchTheme(
		name: "High Contrast",
		backgroundColor: ThemeColor(0, 0, 0),
		textColor: ThemeColor(1, 1, 1),
		secondaryTextColor: ThemeColor(0.85, 0.85, 0.85),
		accentColor: ThemeColor(1.0, 0.84, 0),
		linkColor: ThemeColor(0.35, 0.85, 1.0),
		bodyFont: .system
	)

	static let builtInThemes: [WatchTheme] = [.defaultTheme, .sepia, .highContrast]

	static func theme(named name: String) -> WatchTheme {
		builtInThemes.first { $0.name == name } ?? .defaultTheme
	}
}

// MARK: - Settings keys

/// UserDefaults keys for user-facing watch settings, shared between `SettingsView`
/// (which writes them) and the reading views (which read them via `@AppStorage`).
enum WatchSettingsKeys {
	static let themeName = "themeName"
	static let markReadOnScroll = "markReadOnScroll"
}
