//
//  MinifluxError.swift
//  MinifluxAPI
//
//  Created by Dave Marquard on 7/7/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Miniflux error responses look like: {"error_message": "This feed already exists (feed_id: 123)"}
struct MinifluxErrorResponse: Decodable, Sendable {
	let errorMessage: String

	enum CodingKeys: String, CodingKey {
		case errorMessage = "error_message"
	}
}

public enum MinifluxError: LocalizedError, Sendable {

	case serverVersionTooOld(foundVersion: String?)
	case serverError(message: String)
	/// The credential-validation endpoint (`/v1/me`) returned a not-found response —
	/// the server predates Miniflux's `/v1/me`, or the endpoint URL is wrong.
	case endpointNotFound
	/// `createFeed` failed because the feed already exists on the server.
	case feedAlreadySubscribed

	public var errorDescription: String? {
		switch self {
		case .serverVersionTooOld(let foundVersion):
			guard let foundVersion else {
				return NSLocalizedString("NetNewsWire requires Miniflux 2.0.49 or later.", comment: "Server version too old")
			}
			let localizedText = NSLocalizedString("This Miniflux server is version %@, but NetNewsWire requires Miniflux 2.0.49 or later.", comment: "Server version too old")
			return NSString.localizedStringWithFormat(localizedText as NSString, foundVersion) as String
		case .serverError(let message):
			let localizedText = NSLocalizedString("The Miniflux server reported an error: %@", comment: "Server error")
			return NSString.localizedStringWithFormat(localizedText as NSString, message) as String
		case .endpointNotFound:
			return NSLocalizedString("The URL request resulted in a not found error.", comment: "URL not found")
		case .feedAlreadySubscribed:
			return NSLocalizedString("You are already subscribed to this feed and can’t add it again.", comment: "Already subscribed")
		}
	}
}
