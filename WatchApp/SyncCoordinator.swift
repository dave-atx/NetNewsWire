//
//  SyncCoordinator.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import MinifluxAPI
import Secrets
import os

// See Technotes/WatchApp.md "Sync triggers" and "Architecture overview". Two sync paths,
// one queue: when the phone is reachable, flush the status queue through it and ask for a
// fresh snapshot (relay, works for any account type); when it isn't and a phone-forwarded
// Miniflux config + credential exist, talk to the Miniflux server directly.

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
	private let directSyncSettings: DirectSyncSettings
	private let userDefaults: UserDefaults
	private let logger = Logger(subsystem: WatchLog.subsystem, category: "SyncCoordinator")

	private static let lastSyncDateKey = "SyncCoordinator.lastSyncDate"
	private static let minimumForegroundSyncInterval: TimeInterval = 10 * 60
	/// Caps mirror the phone-side snapshot caps — see Technotes/WatchApp.md "Cache policy".
	private static let directUnreadLimit = 200
	private static let directStarredLimit = 100
	/// Body HTML trim, same rationale as WatchBridge.maxContentLength on the phone.
	nonisolated private static let maxContentLength = 64 * 1024

	init(store: WatchStore, statusQueue: StatusQueue, phoneSession: PhoneSession, directSyncSettings: DirectSyncSettings, userDefaults: UserDefaults = .standard) {
		self.store = store
		self.statusQueue = statusQueue
		self.phoneSession = phoneSession
		self.directSyncSettings = directSyncSettings
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

	// lastSyncDate is only recorded when a sync actually moved data (snapshot requested or
	// direct pull succeeded) — a failed attempt shouldn't suppress the next foreground sync
	// for 10 minutes.
	private func sync() async {
		guard !isSyncing else {
			return
		}
		isSyncing = true
		defer { isSyncing = false }

		if phoneSession.isReachable {
			await flushQueue()
			phoneSession.requestSnapshot()
			lastSyncDate = Date()
			return
		}

		guard let config = directSyncSettings.config, let credentials = directSyncSettings.credentials else {
			logger.notice("Phone is not reachable and no direct sync configuration exists; skipping sync")
			return
		}
		await directSync(config: config, credentials: credentials)
	}

	private func flushQueue() async {
		let changes = statusQueue.selectForProcessing()
		guard !changes.isEmpty else {
			return
		}
		phoneSession.sendStatusBatch(changes)
	}

	// MARK: - Direct Miniflux sync

	private func directSync(config: WatchAccountConfig, credentials: Credentials) async {
		let caller = MinifluxAPICaller()
		caller.credentials = credentials
		caller.accountSettings = directSyncSettings

		await flushQueueDirectly(with: caller, accountID: config.accountID)

		do {
			let unreadEntries = try await caller.retrieveRecentUnreadEntries(limit: Self.directUnreadLimit)
			let starredEntries = try await caller.retrieveStarredEntries(limit: Self.directStarredLimit)
			let feedNamesByID = await feedNames(with: caller)

			let snapshot = Self.snapshot(unreadEntries: unreadEntries, starredEntries: starredEntries, feedNamesByID: feedNamesByID, accountID: config.accountID)
			await store.applySnapshot(snapshot)
			lastSyncDate = Date()
			logger.info("Direct sync applied a snapshot with \(snapshot.articles.count) articles")
		} catch {
			logger.error("Direct entry fetch failed: \(error.localizedDescription)")
		}
	}

	/// Flushes queued changes straight to the server. Only changes that belong to the
	/// configured account and carry a Miniflux entry ID can go this way — anything else
	/// (relay-only accounts) is reset to pending and waits for the phone.
	private func flushQueueDirectly(with caller: MinifluxAPICaller, accountID: String) async {
		let changes = statusQueue.selectForProcessing()
		guard !changes.isEmpty else {
			return
		}

		let flushable = changes.filter { $0.accountID == accountID && $0.minifluxEntryID != nil }
		let relayOnly = changes.filter { !($0.accountID == accountID && $0.minifluxEntryID != nil) }
		statusQueue.resetSelected(relayOnly)

		guard !flushable.isEmpty else {
			return
		}

		do {
			for key in [WatchStatusKey.read, .starred] {
				for flag in [true, false] {
					let entryIDs = flushable.filter { $0.key == key && $0.flag == flag }.compactMap { $0.minifluxEntryID.map(Int64.init) }
					guard !entryIDs.isEmpty else {
						continue
					}
					switch key {
					case .read:
						try await caller.updateEntries(entryIDs: entryIDs, read: flag)
					case .starred:
						try await caller.updateEntries(entryIDs: entryIDs, starred: flag)
					}
				}
			}
			statusQueue.deleteSelected(flushable)
		} catch {
			logger.error("Direct queue flush failed: \(error.localizedDescription)")
			statusQueue.resetSelected(flushable)
		}
	}

	/// Feed titles for timeline rows. Entries don't reliably carry a nested feed (the
	/// server-side fields trim strips it), so the feed list is fetched separately.
	/// Best-effort: a failure just means articles show without feed names this sync.
	private func feedNames(with caller: MinifluxAPICaller) async -> [Int64: String] {
		do {
			let feeds = try await caller.retrieveFeeds()
			return Dictionary(uniqueKeysWithValues: feeds.compactMap { feed in
				guard let title = feed.title else {
					return nil
				}
				return (feed.feedID, title)
			})
		} catch {
			logger.error("Feed list fetch failed: \(error.localizedDescription)")
			return [:]
		}
	}

	nonisolated private static func snapshot(unreadEntries: [MinifluxEntry], starredEntries: [MinifluxEntry], feedNamesByID: [Int64: String], accountID: String) -> WatchSnapshot {
		var recordsByID: [String: WatchArticleRecord] = [:]
		for entry in unreadEntries + starredEntries {
			guard entry.status != "removed" else {
				continue
			}
			let record = watchArticleRecord(for: entry, feedNamesByID: feedNamesByID, accountID: accountID)
			recordsByID[record.articleID] = record
		}
		return WatchSnapshot(generatedAt: Date(), articles: Array(recordsByID.values))
	}

	/// Mirrors the phone-side mapping in WatchBridge: for Miniflux accounts, NNW's
	/// articleID is `String(entryID)`.
	nonisolated private static func watchArticleRecord(for entry: MinifluxEntry, feedNamesByID: [Int64: String], accountID: String) -> WatchArticleRecord {
		let contentHTML = entry.contentHTML.map { String($0.prefix(maxContentLength)) }
		let textPreview = contentHTML.map { String(ArticleBodyPlainTextConverter.plainText(fromHTML: $0).prefix(200)) } ?? ""

		return WatchArticleRecord(articleID: String(entry.entryID),
								   accountID: accountID,
								   minifluxEntryID: Int(entry.entryID),
								   feedName: feedNamesByID[entry.feedID] ?? "",
								   title: entry.title ?? "",
								   textPreview: textPreview,
								   datePublished: entry.parsedDatePublished,
								   url: entry.url,
								   read: entry.status == "read",
								   starred: entry.starred ?? false,
								   contentHTML: contentHTML)
	}
}
