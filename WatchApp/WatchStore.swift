//
//  WatchStore.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Observation
import os

// M1 scaffolding — see Technotes/WatchApp.md "Watch-side storage" and "Cache policy".
// No SQLite: a small metadata index (one JSON file) plus one content file per article,
// both written atomically. The metadata index is cheap enough to rewrite in full on every
// mutation; per-article content is written once when a snapshot arrives and loaded on
// demand by the article view.

/// Shared subsystem string for the watch target's `os.Logger` instances.
enum WatchLog {
	static let subsystem = Bundle.main.bundleIdentifier ?? "com.ranchero.NetNewsWire.watchapp"
}

/// File locations for the watch store, rooted in the app's Application Support directory.
/// A plain, `Sendable` value type so it can cross into background `Task`s that do file I/O
/// off the main actor.
struct WatchStorePaths: Sendable {

	let indexFileURL: URL
	let contentDirectoryURL: URL

	private let logger = Logger(subsystem: WatchLog.subsystem, category: "WatchStorePaths")

	init(fileManager: FileManager = .default) {
		let base = Self.baseDirectory(fileManager: fileManager)
		indexFileURL = base.appendingPathComponent("ArticleIndex.json")
		contentDirectoryURL = base.appendingPathComponent("ArticleContent", isDirectory: true)
		try? fileManager.createDirectory(at: contentDirectoryURL, withIntermediateDirectories: true)
	}

	/// The watch store's root directory: `Application Support/WatchStore`. Shared with
	/// `StatusQueue`, which persists its own file alongside the index and content directory.
	static func baseDirectory(fileManager: FileManager = .default) -> URL {
		let applicationSupport = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
		let directory = applicationSupport.appendingPathComponent("WatchStore", isDirectory: true)
		try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	func contentFileURL(for articleID: String) -> URL {
		contentDirectoryURL.appendingPathComponent(Self.sanitizedFilename(for: articleID))
	}

	func writeContent(_ html: String, for articleID: String) {
		guard let data = html.data(using: .utf8) else {
			return
		}
		do {
			try data.write(to: contentFileURL(for: articleID), options: .atomic)
		} catch {
			logger.error("Failed to write content file: \(error.localizedDescription)")
		}
	}

	func readContent(for articleID: String) -> String? {
		guard let data = try? Data(contentsOf: contentFileURL(for: articleID)) else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}

	func deleteContent(for articleID: String) {
		try? FileManager.default.removeItem(at: contentFileURL(for: articleID))
	}

	private static func sanitizedFilename(for articleID: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
		let sanitized = String(articleID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
		return sanitized.isEmpty ? "article" : sanitized
	}
}

private extension WatchArticleRecord {

	/// A copy with `read`/`starred` overridden when a value is supplied — used to reapply
	/// locally-pending flags after an incoming snapshot would otherwise overwrite them.
	func applyingLocalFlags(read: Bool?, starred: Bool?) -> WatchArticleRecord {
		WatchArticleRecord(articleID: articleID, accountID: accountID, minifluxEntryID: minifluxEntryID, feedName: feedName, title: title, textPreview: textPreview, datePublished: datePublished, url: url, read: read ?? self.read, starred: starred ?? self.starred, contentHTML: contentHTML)
	}
}

/// The watch's article cache. Exposes precomputed, sorted `unread` and `starred` arrays so
/// views never filter or sort inline. All mutation goes through `markRead`/`markStarred`
/// (which also append to the `StatusQueue`) or `applySnapshot` (relay/direct sync arrival).
@MainActor
@Observable
final class WatchStore {

	private(set) var unread: [WatchArticleRecord] = []
	private(set) var starred: [WatchArticleRecord] = []

	private var recordsByID: [String: WatchArticleRecord]
	private var openArticleID: String?

	private let statusQueue: StatusQueue
	private let paths: WatchStorePaths
	private let logger = Logger(subsystem: WatchLog.subsystem, category: "WatchStore")

	init(statusQueue: StatusQueue, fileManager: FileManager = .default) {
		self.statusQueue = statusQueue
		self.paths = WatchStorePaths(fileManager: fileManager)
		self.recordsByID = Self.loadIndex(from: paths)
		recomputeDerivedArrays()
	}

	var isEmpty: Bool {
		recordsByID.isEmpty
	}

	func article(for articleID: String) -> WatchArticleRecord? {
		recordsByID[articleID]
	}

	/// The on-disk location of an article's content file — a pure path computation, safe to
	/// hand to a background task that will load and parse the file off the main actor.
	func contentFileURL(for articleID: String) -> URL {
		paths.contentFileURL(for: articleID)
	}

	/// Tracks the article currently open in `ArticleView` so `applySnapshot` won't evict it
	/// even if it's absent from the incoming snapshot (e.g. the phone trimmed it for size).
	func setOpenArticle(_ articleID: String?) {
		openArticleID = articleID
	}

	// MARK: - Mutations

	func markRead(_ articleID: String, _ read: Bool) {
		setFlag(articleID: articleID, key: .read, flag: read)
	}

	func markStarred(_ articleID: String, _ starred: Bool) {
		setFlag(articleID: articleID, key: .starred, flag: starred)
	}

	private func setFlag(articleID: String, key: WatchStatusKey, flag: Bool) {
		guard let existing = recordsByID[articleID] else {
			return
		}

		let updated: WatchArticleRecord
		switch key {
		case .read:
			updated = existing.applyingLocalFlags(read: flag, starred: nil)
		case .starred:
			updated = existing.applyingLocalFlags(read: nil, starred: flag)
		}
		recordsByID[articleID] = updated

		statusQueue.enqueue(WatchStatusChange(articleID: articleID, accountID: existing.accountID, minifluxEntryID: existing.minifluxEntryID, key: key, flag: flag, date: Date()))

		persistIndex()
		recomputeDerivedArrays()
	}

	/// Applies status changes that originated elsewhere (a phone-sent delta). Never enqueues
	/// to the `StatusQueue`; per the conflict rule, a pending local change for the same
	/// article and key wins over the incoming value.
	func applyRemoteChanges(_ changes: [WatchStatusChange]) {
		let pendingReadIDs = statusQueue.pendingArticleIDs(for: .read)
		let pendingStarredIDs = statusQueue.pendingArticleIDs(for: .starred)

		var didChange = false
		for change in changes {
			guard let existing = recordsByID[change.articleID] else {
				continue
			}

			let updated: WatchArticleRecord
			switch change.key {
			case .read:
				guard !pendingReadIDs.contains(change.articleID), existing.read != change.flag else {
					continue
				}
				updated = existing.applyingLocalFlags(read: change.flag, starred: nil)
			case .starred:
				guard !pendingStarredIDs.contains(change.articleID), existing.starred != change.flag else {
					continue
				}
				updated = existing.applyingLocalFlags(read: nil, starred: change.flag)
			}

			recordsByID[change.articleID] = updated
			didChange = true
		}

		if didChange {
			persistIndex()
			recomputeDerivedArrays()
		}
	}

	// MARK: - Snapshot application

	/// Snapshot-wins replacement, per the design's conflict rule: articles with a pending
	/// (un-sent) queue entry keep their locally-set read/star flag rather than being
	/// overwritten by the incoming value, and starred or currently-open articles are never
	/// evicted even if the snapshot no longer includes them. The merge and its content-file
	/// writes run off the main actor; only the final in-memory swap and index persist happen
	/// here.
	func applySnapshot(_ snapshot: WatchSnapshot) async {
		let pendingReadIDs = statusQueue.pendingArticleIDs(for: .read)
		let pendingStarredIDs = statusQueue.pendingArticleIDs(for: .starred)
		let currentRecordsByID = recordsByID
		let currentOpenArticleID = openArticleID
		let currentPaths = paths

		let mergedRecordsByID = await Task.detached(priority: .utility) {
			Self.mergeSnapshot(snapshot, into: currentRecordsByID, pendingReadIDs: pendingReadIDs, pendingStarredIDs: pendingStarredIDs, openArticleID: currentOpenArticleID, paths: currentPaths)
		}.value

		recordsByID = mergedRecordsByID
		persistIndex()
		recomputeDerivedArrays()
	}

	nonisolated private static func mergeSnapshot(_ snapshot: WatchSnapshot, into currentRecordsByID: [String: WatchArticleRecord], pendingReadIDs: Set<String>, pendingStarredIDs: Set<String>, openArticleID: String?, paths: WatchStorePaths) -> [String: WatchArticleRecord] {
		var updatedRecordsByID: [String: WatchArticleRecord] = [:]
		updatedRecordsByID.reserveCapacity(snapshot.articles.count)

		for incoming in snapshot.articles {
			var record = incoming.withoutContent

			if pendingReadIDs.contains(record.articleID) || pendingStarredIDs.contains(record.articleID) {
				let keepRead = pendingReadIDs.contains(record.articleID) ? currentRecordsByID[record.articleID]?.read : nil
				let keepStarred = pendingStarredIDs.contains(record.articleID) ? currentRecordsByID[record.articleID]?.starred : nil
				record = record.applyingLocalFlags(read: keepRead, starred: keepStarred)
			}

			updatedRecordsByID[record.articleID] = record

			if let contentHTML = incoming.contentHTML {
				paths.writeContent(contentHTML, for: record.articleID)
			}
		}

		let incomingIDs = Set(updatedRecordsByID.keys)
		for (articleID, oldRecord) in currentRecordsByID where !incomingIDs.contains(articleID) {
			if oldRecord.starred || articleID == openArticleID {
				updatedRecordsByID[articleID] = oldRecord
			} else {
				paths.deleteContent(for: articleID)
			}
		}

		return updatedRecordsByID
	}

	// MARK: - Derived arrays

	private func recomputeDerivedArrays() {
		let sortedRecords = recordsByID.values.sorted { lhs, rhs in
			(lhs.datePublished ?? .distantPast) > (rhs.datePublished ?? .distantPast)
		}
		unread = sortedRecords.filter { !$0.read }
		starred = sortedRecords.filter(\.starred)
	}

	// MARK: - Index persistence

	nonisolated private static func loadIndex(from paths: WatchStorePaths) -> [String: WatchArticleRecord] {
		guard let data = try? Data(contentsOf: paths.indexFileURL) else {
			return [:]
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		guard let records = try? decoder.decode([WatchArticleRecord].self, from: data) else {
			return [:]
		}
		return Dictionary(uniqueKeysWithValues: records.map { ($0.articleID, $0) })
	}

	private func persistIndex() {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		do {
			let data = try encoder.encode(recordsByID.values.map(\.withoutContent))
			try data.write(to: paths.indexFileURL, options: .atomic)
		} catch {
			logger.error("Failed to persist article index: \(error.localizedDescription)")
		}
	}
}
