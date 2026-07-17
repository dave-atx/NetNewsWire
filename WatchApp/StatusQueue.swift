//
//  StatusQueue.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import os

// M1 scaffolding — see Technotes/WatchApp.md "Watch-side storage". A durable queue of
// read/star changes, persisted as JSON so a terminated app loses nothing. Semantics mirror
// SyncDatabase's selected-for-processing pattern: mark entries in-flight before sending,
// delete them on confirmed send, reset them back to pending on failure so they're retried.

/// One queued change plus its in-flight state.
private struct StatusQueueEntry: Codable, Equatable, Sendable {
	var change: WatchStatusChange
	var isSelected: Bool
}

/// Durable queue of `WatchStatusChange` values waiting to be sent to the phone (or, in M2,
/// directly to Miniflux). Coalesces same-key changes for an article so only the latest
/// un-selected change for a given `(articleID, key)` pair is kept.
@MainActor
final class StatusQueue {

	private var entries: [StatusQueueEntry]
	private let fileURL: URL
	private let logger = Logger(subsystem: WatchLog.subsystem, category: "StatusQueue")

	init(fileManager: FileManager = .default) {
		self.fileURL = StatusQueue.queueFileURL(fileManager: fileManager)
		// Reset any in-flight entries back to pending: if the app was terminated mid-send,
		// nothing will ever confirm or reset them, so they'd be stuck selected forever.
		// Worst case a confirmed-but-not-deleted change is re-sent — applying a read/star
		// flag twice is harmless.
		self.entries = StatusQueue.loadEntries(from: fileURL).map { entry in
			var entry = entry
			entry.isSelected = false
			return entry
		}
	}

	/// Queues a change, replacing any un-selected (not yet in-flight) change for the same
	/// article and key. A change that's already selected for processing is left alone —
	/// its replacement is queued as a new pending entry and sent on the next flush.
	func enqueue(_ change: WatchStatusChange) {
		entries.removeAll { entry in
			!entry.isSelected && entry.change.articleID == change.articleID && entry.change.key == change.key
		}
		entries.append(StatusQueueEntry(change: change, isSelected: false))
		persist()
	}

	/// Article IDs with a pending (not necessarily selected) change for the given key —
	/// used by `WatchStore` to protect locally-set flags from being overwritten by an
	/// incoming snapshot.
	func pendingArticleIDs(for key: WatchStatusKey) -> Set<String> {
		Set(entries.filter { $0.change.key == key }.map(\.change.articleID))
	}

	/// Marks every currently un-selected entry as in-flight and returns the changes to send.
	func selectForProcessing() -> [WatchStatusChange] {
		var selectedChanges: [WatchStatusChange] = []
		for index in entries.indices where !entries[index].isSelected {
			entries[index].isSelected = true
			selectedChanges.append(entries[index].change)
		}
		if !selectedChanges.isEmpty {
			persist()
		}
		return selectedChanges
	}

	/// Removes entries for changes that were confirmed delivered.
	func deleteSelected(_ changes: [WatchStatusChange]) {
		guard !changes.isEmpty else {
			return
		}
		entries.removeAll { entry in
			entry.isSelected && changes.contains(entry.change)
		}
		persist()
	}

	/// Returns selected entries to pending so they're retried on the next flush.
	func resetSelected(_ changes: [WatchStatusChange]) {
		guard !changes.isEmpty else {
			return
		}
		for index in entries.indices where entries[index].isSelected && changes.contains(entries[index].change) {
			entries[index].isSelected = false
		}
		persist()
	}

	// MARK: - Persistence

	private static func queueFileURL(fileManager: FileManager) -> URL {
		WatchStorePaths.baseDirectory(fileManager: fileManager).appendingPathComponent("StatusQueue.json")
	}

	private static func loadEntries(from fileURL: URL) -> [StatusQueueEntry] {
		guard let data = try? Data(contentsOf: fileURL) else {
			return []
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return (try? decoder.decode([StatusQueueEntry].self, from: data)) ?? []
	}

	private func persist() {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		do {
			let data = try encoder.encode(entries)
			try data.write(to: fileURL, options: .atomic)
		} catch {
			logger.error("Failed to persist status queue: \(error.localizedDescription)")
		}
	}
}
