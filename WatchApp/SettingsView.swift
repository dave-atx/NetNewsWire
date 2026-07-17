//
//  SettingsView.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

// M3 — theme choice, auto-mark-read, and the manual sync trigger from the design's
// "Sync triggers" section. Reached from the timeline's toolbar gear.

struct SettingsView: View {

	var coordinator: SyncCoordinator

	@AppStorage(WatchSettingsKeys.themeName) private var themeName = WatchTheme.defaultTheme.name
	@AppStorage(WatchSettingsKeys.markReadOnScroll) private var markReadOnScroll = false

	var body: some View {
		List {
			Section("Appearance") {
				Picker("Theme", selection: $themeName) {
					ForEach(WatchTheme.builtInThemes) { theme in
						Text(theme.name).tag(theme.name)
					}
				}
			}

			Section {
				Toggle("Mark Read on Scroll", isOn: $markReadOnScroll)
			} header: {
				Text("Reading")
			} footer: {
				Text("Marks an article read when you scroll to the end.")
			}

			Section("Sync") {
				Button {
					Task {
						await coordinator.manualSync()
					}
				} label: {
					Label(coordinator.isSyncing ? "Syncing" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
				}
				.disabled(coordinator.isSyncing)

				if let lastSyncDate = coordinator.lastSyncDate {
					VStack(alignment: .leading, spacing: 2) {
						Text("Last Sync")
						Text(lastSyncDate, format: .relative(presentation: .named))
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.navigationTitle("Settings")
	}
}
