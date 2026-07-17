//
//  NetNewsWireWatchApp.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

@main
struct NetNewsWireWatchApp: App {

	var body: some Scene {
		WindowGroup {
			TimelinePlaceholderView()
		}
	}
}

struct TimelinePlaceholderView: View {

	var body: some View {
		Text("NetNewsWire")
	}
}
