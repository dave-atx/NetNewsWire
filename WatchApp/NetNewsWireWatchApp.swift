//
//  NetNewsWireWatchApp.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

/// Composition root: owns the store, queue, phone session, and sync coordinator for the
/// app's lifetime, and hosts the single `NavigationStack` the whole app navigates within.
@main
struct NetNewsWireWatchApp: App {

	@State private var statusQueue: StatusQueue
	@State private var store: WatchStore
	@State private var phoneSession: PhoneSession
	@State private var syncCoordinator: SyncCoordinator

	@Environment(\.scenePhase) private var scenePhase

	init() {
		let statusQueue = StatusQueue()
		let store = WatchStore(statusQueue: statusQueue)
		let phoneSession = PhoneSession(store: store, statusQueue: statusQueue)
		let syncCoordinator = SyncCoordinator(store: store, statusQueue: statusQueue, phoneSession: phoneSession)

		_statusQueue = State(initialValue: statusQueue)
		_store = State(initialValue: store)
		_phoneSession = State(initialValue: phoneSession)
		_syncCoordinator = State(initialValue: syncCoordinator)

		// Activate as early as possible — and after the coordinator has wired its
		// reachability callback, so activation completing with the phone in range triggers
		// the first sync.
		phoneSession.activate()
	}

	var body: some Scene {
		WindowGroup {
			NavigationStack {
				TimelineView(store: store, coordinator: syncCoordinator)
			}
			.onChange(of: scenePhase, initial: true) { _, newPhase in
				if newPhase == .active {
					syncCoordinator.syncOnForegroundIfNeeded()
				}
			}
		}
	}
}
