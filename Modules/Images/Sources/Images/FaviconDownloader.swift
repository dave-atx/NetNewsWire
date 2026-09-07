//
//  FaviconDownloader.swift
//  Images
//
//  Created by Brent Simmons on 11/19/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import Foundation
import os
import CoreServices
import Articles
import Account
import RSCore
import RSWeb
import HTMLMetadata
import UniformTypeIdentifiers

extension Notification.Name {

	public static let FaviconDidBecomeAvailable = Notification.Name("FaviconDidBecomeAvailableNotification") // userInfo key: FaviconDownloader.UserInfoKey.faviconURL
}

@MainActor public final class FaviconDownloader {
	public static let shared = FaviconDownloader()

	nonisolated static private let logger = Logger(subsystem: Logger.nnwSubsystem, category: "FaviconDownloader")

	private let folder: String
	private let diskCache: BinaryDiskCache
	private var singleFaviconDownloaderCache = [String: SingleFaviconDownloader]() // faviconURL: SingleFaviconDownloader
	private var remainingFaviconURLs = [String: ArraySlice<String>]() // homePageURL: array of faviconURLs that haven't been checked yet
	private var homePagesWithOnlyDefaultFaviconURL = Set<String>() // home pages that declared no favicon of their own
	private var homePagesWithInconclusiveResult = Set<String>() // home pages whose candidates can't support a lasting verdict

	private let queue: DispatchQueue
	private var cache = [Feed: IconImage]() // faviconURL: RSImage

	public struct UserInfoKey {
		public static let faviconURL = "faviconURL"
	}

	init() {
		let folderURL = AppConfig.cacheSubfolder(named: "Favicons")
		let folder = folderURL.path
		self.folder = folder
		self.diskCache = BinaryDiskCache(folder: folder)
		self.queue = DispatchQueue(label: "FaviconDownloader serial queue - \(folder)")

		NotificationCenter.default.addObserver(self, selector: #selector(didLoadFavicon(_:)), name: .DidLoadFavicon, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(htmlMetadataIsAvailable(_:)), name: .htmlMetadataAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(htmlMetadataIsUnavailable(_:)), name: .htmlMetadataUnavailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidGoToBackground(_:)), name: .appDidGoToBackground, object: nil)
	}

	// MARK: - API

	@objc func handleLowMemory(_ notification: Notification) {
		cache.removeAll()
		singleFaviconDownloaderCache.removeAll()
	}

	@objc func handleAppDidGoToBackground(_ notification: Notification) {
		cache.removeAll()
		singleFaviconDownloaderCache.removeAll()
	}

	/// Empties the in-memory caches and deletes every cached favicon file on disk.
	public func resetCache() {
		cache.removeAll()
		singleFaviconDownloaderCache.removeAll()
		remainingFaviconURLs.removeAll()
		homePagesWithOnlyDefaultFaviconURL.removeAll()
		homePagesWithInconclusiveResult.removeAll()
		diskCache.removeAllData()
	}

	public func favicon(for feed: Feed) -> IconImage? {
		assert(Thread.isMainThread)

		if shouldSkipDownloadingFavicon(feed: feed) {
			return nil
		}

		var homePageURL = feed.homePageURL
		if let faviconURL = feed.faviconURL {
			return favicon(with: faviconURL, homePageURL: homePageURL)
		}

		if homePageURL == nil {
			// Base homePageURL off feedURL if needed. Won’t always be accurate, but is good enough.
			if let feedURL = URL(string: feed.url), let scheme = feedURL.scheme, let host = feedURL.host {
				homePageURL = scheme + "://" + host + "/"
			}
		}
		if let homePageURL = homePageURL {
			return favicon(withHomePageURL: homePageURL)
		}

		return nil
	}

	public func faviconAsIcon(for feed: Feed) -> IconImage? {

		if let image = cache[feed] {
			return image
		}

		if let iconImage = favicon(for: feed) {
			cache[feed] = iconImage
			return iconImage
		}

		return nil
	}

	/// Returns the in-memory favicon for `feed` without triggering a download.
	public func cachedFaviconAsIcon(for feed: Feed) -> IconImage? {
		if let image = cache[feed] {
			return image
		}
		guard let faviconURL = cachedFaviconURL(for: feed) else {
			return nil
		}
		guard let iconImage = singleFaviconDownloaderCache[faviconURL]?.iconImage else {
			return nil
		}
		cache[feed] = iconImage
		return iconImage
	}

	/// The known favicon URL for `feed` (from feed settings or the home-page→favicon map), without
	/// triggering any download. Both lookups are in-memory, so this is cheap to call per row.
	public func cachedFaviconURL(for feed: Feed) -> String? {
		if let faviconURL = feed.faviconURL {
			return faviconURL
		}
		if let homePageURL = feed.homePageURL, let faviconURL = ImageMetadataDatabase.shared.faviconURL(forHomePageURL: homePageURL) {
			return faviconURL
		}
		return nil
	}

	public func favicon(with faviconURL: String, homePageURL: String?) -> IconImage? {
		guard canAttemptDownload(faviconURL) else {
			return nil
		}
		let downloader = faviconDownloader(withURL: faviconURL, homePageURL: homePageURL)
		return downloader.iconImage
	}

	public func favicon(withHomePageURL homePageURL: String) -> IconImage? {

		let url = homePageURL.normalizedURL

		if ImageMetadataDatabase.shared.homePageHasNoFavicon(url) {
			Self.logger.debug("Recorded as having no favicon, skipping: \(url, privacy: .public)")
			return nil
		}

		if let faviconURL = ImageMetadataDatabase.shared.faviconURL(forHomePageURL: url) {
			Self.logger.debug("Known favicon for \(url, privacy: .public): \(faviconURL, privacy: .public)")
			return favicon(with: faviconURL, homePageURL: url)
		}

		if let faviconURLs = findFaviconURLs(with: url) {
			// A single candidate is the synthesized favicon.ico — the site declared none of its
			// own. That verdict is read back later, asynchronously, once the candidates run out,
			// so it has to be remembered per home page rather than in one shared flag.
			if faviconURLs.count == 1 {
				homePagesWithOnlyDefaultFaviconURL.insert(url)
			} else {
				homePagesWithOnlyDefaultFaviconURL.remove(url)
			}
			Self.logger.debug("Candidates for \(url, privacy: .public): \(faviconURLs.joined(separator: ", "), privacy: .public)")
			self.remainingFaviconURLs[url] = faviconURLs[...]
			downloadNextFavicon(forHomePageURL: url)
		}

		return nil
	}

	// MARK: - Notifications

	@objc func didLoadFavicon(_ note: Notification) {

		guard let singleFaviconDownloader = note.object as? SingleFaviconDownloader else {
			return
		}

		// URL-level outcome runs before the homePageURL guard so we record it even when homePageURL is nil.
		if let error = singleFaviconDownloader.error {
			ImageMetadataDatabase.shared.recordFailure(url: singleFaviconDownloader.faviconURL, statusCode: error.statusCode)
		} else if singleFaviconDownloader.iconImage != nil {
			ImageMetadataDatabase.shared.clearFailure(url: singleFaviconDownloader.faviconURL)
		}

		guard let homePageURL = singleFaviconDownloader.homePageURL else {
			return
		}
		guard singleFaviconDownloader.iconImage != nil else {
			// No image and no error means the download failed transiently. A network blip
			// must not end up recorded as “this site has no favicon”.
			if singleFaviconDownloader.error == nil {
				Self.logger.debug("Transient favicon failure for \(singleFaviconDownloader.faviconURL, privacy: .public)")
				homePagesWithInconclusiveResult.insert(homePageURL)
			} else {
				Self.logger.debug("Favicon failed for \(singleFaviconDownloader.faviconURL, privacy: .public)")
			}
			if remainingFaviconURLs[homePageURL] != nil {
				downloadNextFavicon(forHomePageURL: homePageURL)
			}
			return
		}

		remainingFaviconURLs[homePageURL] = nil
		homePagesWithOnlyDefaultFaviconURL.remove(homePageURL)
		homePagesWithInconclusiveResult.remove(homePageURL)

		Self.logger.debug("Loaded favicon for \(homePageURL, privacy: .public): \(singleFaviconDownloader.faviconURL, privacy: .public)")
		postFaviconDidBecomeAvailableNotification(singleFaviconDownloader.faviconURL)
	}

	@objc func htmlMetadataIsAvailable(_ note: Notification) {

		guard let url = note.userInfo?[HTMLMetadataUserInfoKey.url] as? String else {
			assertionFailure("Expected URL string in .htmlMetadataAvailable Notification userInfo.")
			return
		}

		Task { @MainActor in
			_ = favicon(withHomePageURL: url)
		}
	}

	@objc func htmlMetadataIsUnavailable(_ note: Notification) {

		guard let url = note.userInfo?[HTMLMetadataUserInfoKey.url] as? String else {
			assertionFailure("Expected URL string in .htmlMetadataUnavailable Notification userInfo.")
			return
		}

		// The home page isn’t coming. Retry so the default favicon.ico still gets its chance.
		Task { @MainActor in
			_ = favicon(withHomePageURL: url)
		}
	}
}

private extension FaviconDownloader {

	static let specialCasesToSkip = [SpecialCase.rachelByTheBayHostName, SpecialCase.openRSSOrgHostName]

	func shouldSkipDownloadingFavicon(feed: Feed) -> Bool {
		SpecialCase.urlStringContainSpecialCase(feed.url, Self.specialCasesToSkip)
	}

	static let localeForLowercasing = Locale(identifier: "en_US")

	func findFaviconURLs(with homePageURL: String) -> [String]? {

		guard let url = URL(string: homePageURL) else {
			return nil
		}

		guard let htmlMetadata = HTMLMetadataDownloader.shared.cachedMetadata(for: homePageURL) else {
			// Metadata that is merely still downloading brings us back here via
			// htmlMetadataIsAvailable. Metadata that isn’t coming at all used to cost the feed
			// its icon entirely — even though a site’s default favicon.ico needs no HTML to find.
			guard HTMLMetadataDownloader.shared.metadataIsUnavailable(for: homePageURL), let defaultFaviconURL = Self.defaultFaviconURL(for: url) else {
				return nil
			}
			// We never read the home page, so an exhausted queue proves nothing about it.
			homePagesWithInconclusiveResult.insert(homePageURL)
			Self.logger.debug("No metadata for \(homePageURL, privacy: .public), trying the default favicon")
			return [defaultFaviconURL]
		}

		let faviconURLs = htmlMetadata.usableFaviconURLs() ?? [String]()

		guard let defaultFaviconURL = Self.defaultFaviconURL(for: url) else {
			return faviconURLs.isEmpty ? nil : faviconURLs
		}
		return faviconURLs + [defaultFaviconURL]
	}

	/// Every site is entitled to a favicon.ico at its root, whether or not it says so.
	static func defaultFaviconURL(for url: URL) -> String? {
		guard let scheme = url.scheme, let host = url.host else {
			return nil
		}
		return "\(scheme)://\(host)/favicon.ico".lowercased(with: localeForLowercasing)
	}

	func canAttemptDownload(_ faviconURL: String) -> Bool {
		if !faviconURL.hasPrefix("http://") && !faviconURL.hasPrefix("https://") {
			Self.logger.debug("Skipping non-http(s) URL: \(faviconURL)")
			return false
		}
		if ImageMetadataDatabase.shared.recentlyFailed(url: faviconURL) {
			Self.logger.debug("Skipping recently-failed URL: \(faviconURL)")
			return false
		}
		return true
	}

	// A skipped candidate advances to the next one — otherwise the queue
	// would stall and the remaining candidates would never be tried.
	// <https://github.com/Ranchero-Software/NetNewsWire/issues/4868>
	func downloadNextFavicon(forHomePageURL homePageURL: String) {
		while let faviconURL = remainingFaviconURLs[homePageURL]?.first {
			remainingFaviconURLs[homePageURL] = remainingFaviconURLs[homePageURL]?.dropFirst()
			if canAttemptDownload(faviconURL) {
				Self.logger.debug("Trying favicon for \(homePageURL, privacy: .public): \(faviconURL, privacy: .public)")
				_ = faviconDownloader(withURL: faviconURL, homePageURL: homePageURL)
				return
			}
		}

		remainingFaviconURLs[homePageURL] = nil

		let declaredNoFaviconOfItsOwn = homePagesWithOnlyDefaultFaviconURL.remove(homePageURL) != nil
		let resultWasInconclusive = homePagesWithInconclusiveResult.remove(homePageURL) != nil

		// A lasting “no favicon” verdict is only earned by a home page we actually read and
		// whose own favicon.ico we actually reached and rejected. A blip, or a home page we
		// never managed to fetch, must not suppress retries for days.
		guard declaredNoFaviconOfItsOwn, !resultWasInconclusive else {
			Self.logger.debug("Out of favicon candidates for \(homePageURL, privacy: .public), recording no verdict")
			return
		}

		Self.logger.debug("Recording no favicon for \(homePageURL, privacy: .public)")
		ImageMetadataDatabase.shared.saveHomePageFavicon(homePageURL: homePageURL, faviconURL: nil)
	}

	func faviconDownloader(withURL faviconURL: String, homePageURL: String?) -> SingleFaviconDownloader {

		var firstTimeSeeingHomepageURL = false

		if let homePageURL, ImageMetadataDatabase.shared.faviconURL(forHomePageURL: homePageURL) == nil {
			ImageMetadataDatabase.shared.saveHomePageFavicon(homePageURL: homePageURL, faviconURL: faviconURL)
			firstTimeSeeingHomepageURL = true
		}

		if let downloader = singleFaviconDownloaderCache[faviconURL] {
			if firstTimeSeeingHomepageURL && !downloader.downloadFaviconIfNeeded() {
				// This is to handle the scenario where we have different homepages, but the same favicon.
				// This happens for Twitter and probably other sites like Blogger.  Because the favicon
				// is cached, we wouldn't send out a notification that it is now available unless we send
				// it here.
				postFaviconDidBecomeAvailableNotification(faviconURL)
			}
			return downloader
		}

		let downloader = SingleFaviconDownloader(faviconURL: faviconURL, homePageURL: homePageURL, diskCache: diskCache, queue: queue)
		singleFaviconDownloaderCache[faviconURL] = downloader
		return downloader
	}

	func postFaviconDidBecomeAvailableNotification(_ faviconURL: String) {

		DispatchQueue.main.async {
			let userInfo: [AnyHashable: Any] = [UserInfoKey.faviconURL: faviconURL]
			NotificationCenter.default.post(name: .FaviconDidBecomeAvailable, object: self, userInfo: userInfo)
		}
	}
}

private extension HTMLMetadataRecord {

	func usableFaviconURLs() -> [String]? {

		favicons.compactMap { favicon in
			shouldAllowFavicon(favicon) ? favicon.urlString : nil
		}
	}

	static let ignoredTypes = [UTType.svg]

	private func shouldAllowFavicon(_ favicon: HTMLMetadataRecord.Favicon) -> Bool {

		// Only http(s) — a data: or other non-web URL can't be downloaded as a favicon.
		guard let urlString = favicon.urlString,
			  urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
			return false
		}

		// Check mime type.
		if let mimeType = favicon.type, let utType = UTType(mimeType: mimeType) {
			if Self.ignoredTypes.contains(utType) {
				return false
			}
		}

		// Check file extension.
		if let url = URL(string: urlString), let utType = UTType(filenameExtension: url.pathExtension) {
			if Self.ignoredTypes.contains(utType) {
				return false
			}
		}

		return true
	}
}
