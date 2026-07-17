//
//  WatchBridge.swift
//  NetNewsWire
//
//  Created by Claude Fable on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import WatchConnectivity
import os
import RSCore
import Articles
import Account

/// Phone-side half of the watch relay path — see Technotes/WatchApp.md, M1.
///
/// Builds article snapshots (recent unread + starred) and ships them to the watch via
/// `WCSession.transferFile`, pushes small incremental status deltas via
/// `transferUserInfo` as reads/stars happen on the phone, and applies status changes the
/// watch sends back through the normal `Account.markArticles` flow — so they enter
/// `SyncDatabase` and reach whatever service the account uses, same as any other change.
@MainActor final class WatchBridge: NSObject {

	static let shared = WatchBridge()

	nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ranchero.NetNewsWire", category: "WatchBridge")

	/// Recent-unread cap for a snapshot — see Technotes/WatchApp.md, Cache policy.
	private static let unreadLimit = 200
	/// Starred cap for a snapshot.
	private static let starredLimit = 100
	/// If more articles than this change status at once (a bulk mark-all-read, say),
	/// send a full snapshot instead of an incremental delta.
	private static let maxDeltaArticleCount = 50
	/// How long to coalesce status changes before sending a delta batch.
	private static let statusDebounceInterval: TimeInterval = 2

	/// Body HTML is capped here to keep the snapshot transfer size sane (worst case ~19 MB
	/// at the full 300-article cap; see Technotes/WatchApp.md, Cache policy). `String.prefix`
	/// truncates at a Character boundary, not an HTML tag boundary, so a body can be cut off
	/// mid-tag. That's tolerated by M1's plain-text-first article renderer; revisit with a
	/// tag-aware trim if M3's block-based HTML renderer needs one.
	private static let maxContentLength = 64 * 1024

	private let session: WCSession?

	/// articleIDs included in the last snapshot sent to the watch. Incremental deltas are
	/// only sent for articles the watch is known to already have.
	private var lastSentArticleIDs: Set<String> = []
	/// The encoded article list from the last snapshot sent, so an unchanged snapshot isn't
	/// resent. (Deliberately excludes `generatedAt`, which always differs.)
	private var lastSentArticlesData: Data?

	/// Status changes waiting to be coalesced into the next delta batch, keyed so a second
	/// flip of the same article+key before the debounce fires replaces rather than duplicates.
	private var pendingStatusChanges: [String: WatchStatusChange] = [:]
	private var statusDebounceTask: Task<Void, Never>?

	private override init() {
		session = WCSession.isSupported() ? WCSession.default : nil
		super.init()
	}

	/// Activates the WatchConnectivity session and starts observing status changes to relay
	/// as deltas. No-op if WatchConnectivity isn't supported on this device.
	func activate() {
		guard let session else {
			return
		}
		session.delegate = self
		session.activate()

		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
	}

	/// Builds a fresh snapshot (recent unread + starred, capped and deduplicated by
	/// articleID) and ships it to the watch via `transferFile`. No-op unless a watch is
	/// paired and has the app installed, or if the content is identical to the last
	/// snapshot sent — except when `force` is true, which sends even an unchanged snapshot
	/// (an explicit watch request can come from a watch that lost its cache, e.g. a
	/// reinstall, so "the phone already sent this" doesn't mean "the watch has it").
	func buildAndSendSnapshot(force: Bool = false) async {
		guard let session, session.isPaired, session.isWatchAppInstalled else {
			return
		}

		let unreadArticles = await AccountManager.shared.fetchArticlesAsync(.unread(Self.unreadLimit))
		let starredArticles = await AccountManager.shared.fetchArticlesAsync(.starred(Self.starredLimit))

		var recordsByArticleID: [String: WatchArticleRecord] = [:]
		for article in unreadArticles {
			recordsByArticleID[article.articleID] = watchArticleRecord(for: article)
		}
		for article in starredArticles {
			recordsByArticleID[article.articleID] = watchArticleRecord(for: article)
		}

		// Deterministic order (newest first, articleID as a tiebreaker) so two builds of
		// identical content encode to identical bytes — Dictionary.values iteration order
		// isn't stable across calls, so without a tiebreaker the content-equality check below
		// would false-positive on "changed" for unchanged snapshots.
		let records = recordsByArticleID.values.sorted { lhs, rhs in
			if lhs.datePublished != rhs.datePublished {
				return (lhs.datePublished ?? .distantPast) > (rhs.datePublished ?? .distantPast)
			}
			return lhs.articleID < rhs.articleID
		}

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601

		let articlesData: Data
		do {
			articlesData = try encoder.encode(records)
		} catch {
			Self.logger.error("Failed to encode snapshot articles: \(error.localizedDescription)")
			return
		}

		guard force || articlesData != lastSentArticlesData else {
			Self.logger.debug("Snapshot content unchanged since last send; skipping.")
			return
		}

		let snapshot = WatchSnapshot(generatedAt: Date(), articles: records)
		let snapshotData: Data
		do {
			snapshotData = try snapshot.encoded()
		} catch {
			Self.logger.error("Failed to encode snapshot: \(error.localizedDescription)")
			return
		}

		let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("watch-snapshot-\(UUID().uuidString).json")
		do {
			try snapshotData.write(to: tempURL, options: .atomic)
		} catch {
			Self.logger.error("Failed to write snapshot to a temp file: \(error.localizedDescription)")
			return
		}

		// Cancel any outstanding transfers for a snapshot this one supersedes.
		for transfer in session.outstandingFileTransfers {
			transfer.cancel()
		}

		_ = session.transferFile(tempURL, metadata: nil)

		lastSentArticleIDs = Set(records.map { $0.articleID })
		lastSentArticlesData = articlesData

		Self.logger.info("Sent snapshot with \(records.count) articles.")
	}
}

// MARK: - Article -> WatchArticleRecord

@MainActor private extension WatchBridge {

	func watchArticleRecord(for article: Article) -> WatchArticleRecord {
		let feedName = article.feed?.nameForDisplay ?? article.preferredLink ?? ""
		let title = ArticleStringFormatter.shared.truncatedTitle(article)
		let textPreview = (article.body?.strippingHTML(maxCharacters: 200) ?? "").decodingHTMLEntities()
		let contentHTML = article.body.map { String($0.prefix(Self.maxContentLength)) }

		return WatchArticleRecord(articleID: article.articleID,
								   accountID: article.accountID,
								   minifluxEntryID: minifluxEntryID(for: article),
								   feedName: feedName,
								   title: title,
								   textPreview: textPreview,
								   datePublished: article.logicalDatePublished,
								   url: article.preferredLink,
								   read: article.status.read,
								   starred: article.status.starred,
								   contentHTML: contentHTML)
	}

	/// For Miniflux accounts, `articleID` (and `uniqueID`) is `String(entry.entryID)` —
	/// `MinifluxAccountDelegate` sets `ParsedItem.syncServiceID` to that value, which
	/// short-circuits `ParsedItem.articleID`'s MD5 `calculatedArticleID` fallback that other
	/// account types use. So it round-trips through `Int(_:)`. Only populated for Miniflux
	/// accounts — other accounts' articleIDs are MD5 hashes and won't parse as an Int.
	func minifluxEntryID(for article: Article) -> Int? {
		guard AccountManager.shared.existingAccount(accountID: article.accountID)?.type == .miniflux else {
			return nil
		}
		return Int(article.articleID)
	}
}

// MARK: - Incremental status deltas (outgoing)

@MainActor private extension WatchBridge {

	@objc func statusesDidChange(_ note: Notification) {
		guard let account = note.object as? Account,
			let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>,
			let statusKey = note.userInfo?[Account.UserInfoKey.statusKey] as? ArticleStatus.Key,
			let flag = note.userInfo?[Account.UserInfoKey.statusFlag] as? Bool else {
				return
		}

		// Only articles the watch actually has are worth pushing a delta for.
		let relevantArticleIDs = articleIDs.intersection(lastSentArticleIDs)
		guard !relevantArticleIDs.isEmpty else {
			return
		}

		let watchKey: WatchStatusKey = statusKey == .starred ? .starred : .read
		let now = Date()
		for articleID in relevantArticleIDs {
			let change = WatchStatusChange(articleID: articleID, accountID: account.accountID, minifluxEntryID: nil, key: watchKey, flag: flag, date: now)
			pendingStatusChanges["\(articleID).\(watchKey.rawValue)"] = change
		}

		scheduleDebouncedStatusSend()
	}

	func scheduleDebouncedStatusSend() {
		statusDebounceTask?.cancel()
		statusDebounceTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(Self.statusDebounceInterval))
			guard !Task.isCancelled else {
				return
			}
			self?.flushPendingStatusChanges()
		}
	}

	func flushPendingStatusChanges() {
		guard !pendingStatusChanges.isEmpty else {
			return
		}
		let changes = Array(pendingStatusChanges.values)
		pendingStatusChanges.removeAll()

		let changedArticleIDs = Set(changes.map { $0.articleID })
		guard changedArticleIDs.count <= Self.maxDeltaArticleCount else {
			Self.logger.info("Status delta covers \(changedArticleIDs.count) articles; sending a full snapshot instead.")
			Task {
				await buildAndSendSnapshot()
			}
			return
		}

		guard let session, session.isPaired, session.isWatchAppInstalled else {
			return
		}

		let batch = WatchStatusBatch(changes: changes)
		_ = session.transferUserInfo(batch.dictionaryRepresentation)
		Self.logger.debug("Sent a status delta for \(changes.count) change(s).")
	}
}

// MARK: - Inbound from watch

@MainActor private extension WatchBridge {

	func handleIncoming(dictionary: [String: Any]) async {
		if let schemaVersion = dictionary[WatchSchema.Keys.schemaVersion] as? Int, schemaVersion > WatchSchema.version {
			Self.logger.info("Dropping watch payload with unsupported schemaVersion \(schemaVersion).")
			return
		}

		if let batch = WatchMessage.statusBatch(from: dictionary) {
			await apply(statusBatch: batch)
		} else if WatchMessage.isRequestSnapshot(dictionary) {
			await buildAndSendSnapshot(force: true)
		} else if WatchMessage.openOnPhoneURL(from: dictionary) != nil {
			// M3: actually open the URL on the phone. For now, just note that it arrived.
			Self.logger.info("Received an openOnPhone request; handling deferred to M3.")
		} else {
			Self.logger.debug("Dropping unrecognized watch payload.")
		}
	}

	func apply(statusBatch: WatchStatusBatch) async {
		let changesByAccountID = Dictionary(grouping: statusBatch.changes, by: { $0.accountID })

		for (accountID, changes) in changesByAccountID {
			guard let account = AccountManager.shared.existingAccount(accountID: accountID) else {
				Self.logger.error("Dropping status changes for unknown accountID.")
				continue
			}

			// Group by (key, flag) so each distinct combination becomes one markArticles call.
			let changesByKeyAndFlag = Dictionary(grouping: changes, by: { KeyAndFlag(key: $0.key, flag: $0.flag) })
			for (keyAndFlag, groupedChanges) in changesByKeyAndFlag {
				let articleIDs = Set(groupedChanges.map { $0.articleID })
				do {
					try await account.markArticles(articleIDs: articleIDs, statusKey: keyAndFlag.key.articleStatusKey, flag: keyAndFlag.flag)
				} catch {
					Self.logger.error("Failed to apply watch status changes: \(error.localizedDescription)")
				}
			}
		}
	}

	private struct KeyAndFlag: Hashable {
		let key: WatchStatusKey
		let flag: Bool
	}
}

private extension WatchStatusKey {
	var articleStatusKey: ArticleStatus.Key {
		switch self {
		case .read:
			return .read
		case .starred:
			return .starred
		}
	}
}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {

	/// A `[String: Any]` payload isn't `Sendable` (`Any` isn't), so it can't be captured
	/// directly by a `Task { @MainActor in }` closure created from these nonisolated
	/// delegate callbacks. This box carries it across under our own steam: the dictionary is
	/// read-only from here on, so there's no actual data race to guard against.
	private struct UnsafeSendableBox<T>: @unchecked Sendable {
		let value: T
	}

	nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
		if let error {
			Self.logger.error("WCSession activation failed: \(error.localizedDescription)")
		} else {
			Self.logger.info("WCSession activated with state \(activationState.rawValue).")
		}
	}

	nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
		Self.logger.info("WCSession became inactive.")
	}

	nonisolated func sessionDidDeactivate(_ session: WCSession) {
		Self.logger.info("WCSession deactivated; reactivating for a watch switch.")
		session.activate()
	}

	nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
		let box = UnsafeSendableBox(value: message)
		Task { @MainActor in
			await WatchBridge.shared.handleIncoming(dictionary: box.value)
		}
	}

	/// WatchConnectivity routes a `sendMessage` that expects a reply exclusively to this
	/// variant — without it, every reply-expecting send from the watch (status batches) would
	/// fail with a delegate error. The empty reply is the delivery confirmation the watch
	/// uses to delete queued changes, so it's sent only after the batch has been applied.
	nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
		// The SDK doesn't declare replyHandler @Sendable, so it rides in a box too; WCSession
		// accepts the reply from any thread.
		let box = UnsafeSendableBox(value: (message, replyHandler))
		Task { @MainActor in
			await WatchBridge.shared.handleIncoming(dictionary: box.value.0)
			box.value.1([:])
		}
	}

	nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
		let box = UnsafeSendableBox(value: userInfo)
		Task { @MainActor in
			await WatchBridge.shared.handleIncoming(dictionary: box.value)
		}
	}

	nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
		if let error {
			Self.logger.error("Snapshot file transfer failed: \(error.localizedDescription)")
		} else {
			Self.logger.debug("Snapshot file transfer finished.")
		}
		try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
	}
}
