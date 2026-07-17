//
//  SyncCoordinator.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import os

// M1 scaffolding — see Technotes/WatchApp.md "Sync triggers" and "Architecture overview".
// M1 only implements the relay path (flush the status queue through the phone, then ask it
// for a fresh snapshot). The design's direct-Miniflux path — used when the phone is
// unreachable but the watch has its own network — arrives in M2; see the seam noted below.

/// Orchestrates a sync attempt: flush the status queue, then request a fresh snapshot.
/// Triggered on foreground (if the last successful sync is stale) and by manual refresh.
@MainActor
@Observable
final class SyncCoordinator {

	private(set) var isSyncing = false
	private(set) var lastSyncDate: Date? {
		didSet {
			userDefaults.set(lastSyncDate, forKey: Self.lastSyncDateKey)
		}
	}

	private let store: WatchStore
	private let statusQueue: StatusQueue
	private let phoneSession: PhoneSession
	private let userDefaults: UserDefaults
	private let logger = Logger(subsystem: WatchLog.subsystem, category: "SyncCoordinator")

	private static let lastSyncDateKey = "SyncCoordinator.lastSyncDate"
	private static let minimumForegroundSyncInterval: TimeInterval = 10 * 60

	init(store: WatchStore, statusQueue: StatusQueue, phoneSession: PhoneSession, userDefaults: UserDefaults = .standard) {
		self.store = store
		self.statusQueue = statusQueue
		self.phoneSession = phoneSession
		self.userDefaults = userDefaults
		self.lastSyncDate = userDefaults.object(forKey: Self.lastSyncDateKey) as? Date

		// Opportunistic trigger, per the design: when the phone comes into reach (including
		// right after session activation at launch), flush anything queued and sync if stale.
		// This is also what rescues a cold launch, where the first foreground sync attempt
		// runs before WCSession activation has completed and can't reach the phone yet.
		phoneSession.onBecameReachable = { [weak self] in
			self?.phoneDidBecomeReachable()
		}
	}

	/// Call on app foreground. Syncs only if the last successful sync is stale, per the
	/// design's "> 10 minutes" trigger.
	func syncOnForegroundIfNeeded() {
		guard shouldSyncOnForeground else {
			return
		}
		Task {
			await sync()
		}
	}

	/// Manual refresh (e.g. pull-to-refresh on the timeline). Always syncs.
	func manualSync() async {
		await sync()
	}

	private var shouldSyncOnForeground: Bool {
		guard let lastSyncDate else {
			return true
		}
		return Date().timeIntervalSince(lastSyncDate) > Self.minimumForegroundSyncInterval
	}

	private func phoneDidBecomeReachable() {
		if shouldSyncOnForeground {
			Task {
				await sync()
			}
		} else {
			Task {
				await flushQueue()
			}
		}
	}

	private func sync() async {
		guard !isSyncing else {
			return
		}
		isSyncing = true
		defer { isSyncing = false }

		await flushQueue()

		// M2 seam: when the phone is unreachable, fall through to a direct Miniflux sync
		// here — pull recent unread + starred entries via MinifluxAPI and flush the queue
		// directly, using the phone-forwarded server version and credentials (see
		// Technotes/WatchApp.md "Credential handoff (direct path)"). M1 is relay-only: if
		// the phone isn't reachable, this sync attempt is a no-op beyond the queue flush
		// above (which itself no-ops when nothing is queued).

		// lastSyncDate is only recorded when a snapshot was actually requested — an
		// unreachable-phone attempt shouldn't suppress the next foreground sync for 10
		// minutes.
		if phoneSession.isReachable {
			phoneSession.requestSnapshot()
			lastSyncDate = Date()
		} else {
			logger.notice("Phone is not reachable; skipping snapshot request")
		}
	}

	private func flushQueue() async {
		let changes = statusQueue.selectForProcessing()
		guard !changes.isEmpty else {
			return
		}
		phoneSession.sendStatusBatch(changes)
	}
}
