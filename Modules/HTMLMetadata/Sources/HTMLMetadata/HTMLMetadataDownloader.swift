//
//  HTMLMetadataDownloader.swift
//  HTMLMetadata
//
//  Created by Brent Simmons on 11/26/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import Foundation
import os
import RSCore
import RSParser
import RSWeb
import ActivityLog

nonisolated public final class HTMLMetadataDownloader: Sendable {

	public static let shared = HTMLMetadataDownloader()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "HTMLMetadataDownloader")

	private static let hoursBetweenAttempts = 3

	private let attemptDates = OSAllocatedUnfairLock(initialState: [String: Date]())

	/// In-memory mirror so `cachedMetadata(for:)` can answer synchronously.
	private let cache = OSAllocatedUnfairLock(initialState: [String: HTMLMetadataRecord]())

	/// URLs whose last fetch failed and which won’t be retried yet. Callers that don’t
	/// actually need the HTML can act on this instead of waiting forever.
	private let unavailableURLs = OSAllocatedUnfairLock(initialState: Set<String>())

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidGoToBackground(_:)), name: .appDidGoToBackground, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
	}

	@objc func handleAppDidGoToBackground(_ notification: Notification) {
		cache.withLock { $0.removeAll() }
	}

	@objc func handleLowMemory(_ notification: Notification) {
		cache.withLock { $0.removeAll() }
	}

	/// Returns cached metadata synchronously, or kicks off a fetch and returns nil.
	/// Callers re-query after observing `.htmlMetadataAvailable`.
	public func cachedMetadata(for url: String) -> HTMLMetadataRecord? {
		if Self.shouldSkipDownloadingMetadata(url) {
			return nil
		}

		if let record = cache.withLock({ $0[url] }) {
			return record
		}

		fetchAndDownloadIfNeeded(url)
		return nil
	}

	/// True when the last attempt to fetch this URL’s metadata failed and no new download
	/// is pending. A caller that only needs a guess — a site’s default `/favicon.ico`, say —
	/// can proceed rather than wait for metadata that isn’t coming.
	public func metadataIsUnavailable(for url: String) -> Bool {
		unavailableURLs.withLock { $0.contains(url) }
	}

}

// MARK: - Private

nonisolated private extension HTMLMetadataDownloader {

	private static let specialCasesToSkip = [SpecialCase.rachelByTheBayHostName, SpecialCase.openRSSOrgHostName]

	static func shouldSkipDownloadingMetadata(_ urlString: String) -> Bool {
		SpecialCase.urlStringContainSpecialCase(urlString, specialCasesToSkip)
	}

	func fetchAndDownloadIfNeeded(_ url: String) {
		Task { @MainActor in
			if let record = await HTMLMetadataDatabase.shared.cachedRecord(for: url) {
				cacheRecord(record)
				postNotification(record)
				return
			}

			if await HTMLMetadataDatabase.shared.recentlyFailed(for: url) {
				markUnavailable(url)
				return
			}

			downloadMetadataIfNeeded(url)
		}
	}

	func cacheRecord(_ record: HTMLMetadataRecord) {
		cache.withLock { $0[record.url] = record }
		markAvailable(record.url)
	}

	func downloadMetadataIfNeeded(_ url: String) {
		let shouldDownload = attemptDates.withLock { dates in
			let currentDate = Date()
			if let attemptDate = dates[url], attemptDate > currentDate.bySubtracting(hours: Self.hoursBetweenAttempts) {
				return false
			}
			dates[url] = currentDate
			return true
		}

		if shouldDownload {
			downloadMetadata(url)
		}
	}

	func downloadMetadata(_ url: String) {
		guard let actualURL = URL(string: url) else {
			return
		}

		Task { @MainActor in
			let activityLog = ActivityLog.shared
			let kind = ActivityKind.downloadHTMLMetadata(urlString: url)

			let lastDownloadDate = await HTMLMetadataDatabase.shared.lastDownloadDate(for: url)
			let detail = lastDownloadDate.map { DateFormatter.logTimestamp.string(from: $0) }

			activityLog.createActivity(owner: .htmlMetadataDownloader, kind: kind, detail: detail)
			activityLog.didStart(.htmlMetadataDownloader, kind: kind)

			do {
				let downloadResponse = try await Downloader.shared.download(actualURL, userAgentStyle: .browser)

				if let data = downloadResponse.data, !data.isEmpty, let response = downloadResponse.response, response.statusIsOK {
					let urlToUse = response.url ?? actualURL
					let parserData = ParserData(url: urlToUse.absoluteString, data: data)
					let htmlMetadata = HTMLMetadataParser.htmlMetadata(with: parserData)
					let record = HTMLMetadataRecord(url: url, metadata: htmlMetadata)

					let statusCode = response.forcedStatusCode
					await HTMLMetadataDatabase.shared.save(record, statusCode: statusCode)
					cacheRecord(record)
					postNotification(record)

					activityLog.didComplete(.htmlMetadataDownloader, kind: kind, message: ActivityLog.dataSizeMessage(data), returnedFromCache: downloadResponse.returnedFromCache)
					return
				}

				let statusCode = downloadResponse.response?.forcedStatusCode ?? -1
				if (400...499).contains(statusCode) {
					await HTMLMetadataDatabase.shared.noteFailure(url: url, statusCode: statusCode)
				}

				// Download failed — try returning stale cached data.
				if await !returnStaleCacheIfAvailable(url) {
					markUnavailable(url)
				}

				let userInfo = [NSLocalizedDescriptionKey: "HTTP \(statusCode)"]
				let statusError = NSError(domain: "NetNewsWire", code: statusCode, userInfo: userInfo)
				activityLog.didFail(.htmlMetadataDownloader, kind: kind, error: statusError)

			} catch {
				// Pre-response failure (DNS, TLS, network).
				await HTMLMetadataDatabase.shared.noteTransientFailure(url: url)
				if await !returnStaleCacheIfAvailable(url) {
					markUnavailable(url)
				}

				activityLog.didFail(.htmlMetadataDownloader, kind: kind, error: error)
			}
		}
	}

	func postNotification(_ record: HTMLMetadataRecord) {
		let userInfo: [String: Any] = [
			HTMLMetadataUserInfoKey.record: record,
			HTMLMetadataUserInfoKey.url: record.url
		]
		NotificationCenter.default.postOnMainThread(
			name: .htmlMetadataAvailable, object: self, userInfo: userInfo
		)
	}

	func markUnavailable(_ url: String) {
		let wasAlreadyUnavailable = unavailableURLs.withLock { unavailableURLs -> Bool in
			let (inserted, _) = unavailableURLs.insert(url)
			return !inserted
		}
		if !wasAlreadyUnavailable {
			postUnavailableNotification(url)
		}
	}

	func markAvailable(_ url: String) {
		unavailableURLs.withLock { _ = $0.remove(url) }
	}

	func postUnavailableNotification(_ url: String) {
		let userInfo: [String: Any] = [HTMLMetadataUserInfoKey.url: url]
		NotificationCenter.default.postOnMainThread(
			name: .htmlMetadataUnavailable, object: self, userInfo: userInfo
		)
	}

	/// Returns true when stale metadata was found and handed back to callers.
	@MainActor func returnStaleCacheIfAvailable(_ url: String) async -> Bool {
		guard let record = await HTMLMetadataDatabase.shared.staleCachedRecord(for: url) else {
			return false
		}
		cacheRecord(record)
		postNotification(record)
		return true
	}
}
