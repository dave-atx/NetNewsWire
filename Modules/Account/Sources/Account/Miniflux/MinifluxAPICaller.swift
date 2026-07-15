//
//  MinifluxAPICaller.swift
//  Account
//
//  Created by Dave Marquard on 7/7/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSWeb
import Secrets

@MainActor final class MinifluxAPICaller {

	// No server-side cap on limit for /v1/entries, so page generously.
	static let entriesPageSize = 500
	// Miniflux caps /v1/entries/ids at MaxEntryIDsLimit (10000) per response, so page at that size.
	static let entryIDsPageSize = 10000
	static let statusChunkSize = 1000

	private static let minimumVersion = MinifluxVersion(2, 3, 2)

	private let session = URLSession.webservice
	private var suspended = false

	var credentials: Credentials?
	var accountSettings: AccountSettings?

	var server: String? {
		apiBaseURL?.host
	}

	private var apiBaseURL: URL? {
		accountSettings?.endpointURL
	}

	/// Cancels all pending requests and rejects any that come in later.
	func suspend() {
		session.cancelAll()
		suspended = true
	}

	func resume() {
		suspended = false
	}

	/// Validates credentials against a caller-supplied endpoint. This runs before an Account exists,
	/// so it can’t rely on `accountSettings` (and thus not on `makeRequest`).
	func validateCredentials(endpoint: URL) async throws -> Credentials? {
		if suspended {
			throw WebserviceError.suspended
		}
		guard let credentials else {
			throw CredentialsError.missingUsername
		}

		let callURL = endpoint.appendingPathComponent("v1/me")
		let request = URLRequest(url: callURL, credentials: credentials)

		let validatedCredentials: Credentials
		do {
			let (_, me) = try await session.send(request: request, resultType: MinifluxUser.self)
			guard let me else {
				throw WebserviceError.noData
			}

			validatedCredentials = credentials.username.isEmpty ? Credentials(type: credentials.type, username: me.username, secret: credentials.secret) : credentials
		} catch {
			if case WebserviceError.httpError(let status) = error {
				if status == HTTPResponseCode.unauthorized {
					return nil
				}
				if status == HTTPResponseCode.notFound {
					throw AccountError.urlNotFound
				}
			}
			throw error
		}

		try await validateServerVersion(endpoint: endpoint)

		return validatedCredentials
	}

	func retrieveCategories() async throws -> [MinifluxCategory] {
		try await fetch("categories")
	}

	func createCategory(title: String) async throws -> MinifluxCategory {
		var request = try makeRequest(path: "categories")
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)

		let payload = try JSONEncoder().encode(MinifluxCategoryPayload(title: title))
		let (_, category) = try await session.send(request: request, method: HTTPMethod.post, data: payload, resultType: MinifluxCategory.self)

		guard let category else {
			throw WebserviceError.noData
		}
		return category
	}

	func renameCategory(categoryID: Int64, title: String) async throws {
		try await session.send(request: makeRequest(path: "categories/\(categoryID)"), method: HTTPMethod.put, payload: MinifluxCategoryPayload(title: title))
	}

	func deleteCategory(categoryID: Int64) async throws {
		try await session.send(request: makeRequest(path: "categories/\(categoryID)"), method: HTTPMethod.delete)
	}

	func retrieveFeeds() async throws -> [MinifluxFeed] {
		try await fetch("feeds")
	}

	/// On failure, attempts to decode a `MinifluxErrorResponse` from the response body to distinguish
	/// “feed already exists” from other errors. Miniflux has no machine-readable error code for this,
	/// so this is a heuristic based on the human-readable `error_message` text. Any other decodable
	/// server error is surfaced as `MinifluxError.serverError` with the server's message; otherwise
	/// the failure is reported as a plain HTTP error.
	func createFeed(url urlString: String, categoryID: Int64) async throws -> Int64 {
		var request = try makeRequest(path: "feeds")
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)
		request.httpMethod = HTTPMethod.post
		request.httpBody = try JSONEncoder().encode(MinifluxCreateFeed(feedURL: urlString, categoryID: categoryID))

		let (data, urlResponse) = try await session.data(for: request)

		guard (200...399).contains(urlResponse.forcedStatusCode) else {
			if let errorResponse = try? JSONDecoder().decode(MinifluxErrorResponse.self, from: data) {
				if errorResponse.errorMessage.contains("already exists") {
					throw AccountError.createErrorAlreadySubscribed
				}
				throw MinifluxError.serverError(message: errorResponse.errorMessage)
			}
			throw WebserviceError.httpError(status: urlResponse.forcedStatusCode)
		}

		guard !data.isEmpty else {
			throw WebserviceError.noData
		}
		let response = try JSONDecoder().decode(MinifluxCreateFeedResponse.self, from: data)
		return response.feedID
	}

	func retrieveFeed(feedID: Int64) async throws -> MinifluxFeed {
		try await fetch("feeds/\(feedID)")
	}

	func renameFeed(feedID: Int64, title: String) async throws {
		try await session.send(request: makeRequest(path: "feeds/\(feedID)"), method: HTTPMethod.put, payload: MinifluxUpdateFeed(title: title, categoryID: nil))
	}

	func moveFeed(feedID: Int64, categoryID: Int64) async throws {
		try await session.send(request: makeRequest(path: "feeds/\(feedID)"), method: HTTPMethod.put, payload: MinifluxUpdateFeed(title: nil, categoryID: categoryID))
	}

	func deleteFeed(feedID: Int64) async throws {
		try await session.send(request: makeRequest(path: "feeds/\(feedID)"), method: HTTPMethod.delete)
	}

	func retrieveEntries(offset: Int, changedAfter: Date?, publishedAfter: Date?) async throws -> MinifluxEntriesResponse {
		var query = Self.entriesPageQueryItems(offset: offset)
		if let changedAfter {
			query.append(URLQueryItem(name: "changed_after", value: String(Int(changedAfter.timeIntervalSince1970))))
		}
		if let publishedAfter {
			query.append(URLQueryItem(name: "published_after", value: String(Int(publishedAfter.timeIntervalSince1970))))
		}

		return try await fetch("entries", query: query)
	}

	func retrieveEntries(feedID: Int64, offset: Int) async throws -> MinifluxEntriesResponse {
		try await fetch("feeds/\(feedID)/entries", query: Self.entriesPageQueryItems(offset: offset))
	}

	/// Returns `nil` if the entry has been removed server-side.
	func retrieveEntry(entryID: Int64) async throws -> MinifluxEntry? {
		do {
			return try await fetch("entries/\(entryID)")
		} catch {
			if case WebserviceError.httpError(let status) = error, status == HTTPResponseCode.notFound {
				return nil
			}
			throw error
		}
	}

	func retrieveUnreadEntryIDs() async throws -> Set<Int64> {
		try await retrieveEntryIDs(matching: [URLQueryItem(name: "status", value: "unread")])
	}

	func retrieveStarredEntryIDs() async throws -> Set<Int64> {
		try await retrieveEntryIDs(matching: [URLQueryItem(name: "starred", value: "true")])
	}

	func updateEntries(entryIDs: [Int64], read: Bool) async throws {
		try await updateEntries(entryIDs: entryIDs, payload: MinifluxUpdateEntriesPayload(entryIDs: entryIDs, status: read ? "read" : "unread", starred: nil))
	}

	/// Requires Miniflux 2.3.2 or later. `starred` is absolute state, not a toggle.
	func updateEntries(entryIDs: [Int64], starred: Bool) async throws {
		try await updateEntries(entryIDs: entryIDs, payload: MinifluxUpdateEntriesPayload(entryIDs: entryIDs, status: nil, starred: starred))
	}

	/// Synchronous — Miniflux’s OPML import doesn’t require polling for completion.
	func importOPML(opmlData: Data) async throws {
		var request = try makeRequest(path: "import")
		request.addValue("text/xml; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)

		_ = try await session.send(request: request, method: HTTPMethod.post, payload: opmlData)
	}
}

// MARK: Private

private extension MinifluxAPICaller {

	/// Builds an authenticated request for `v1/<path>`, honoring `suspend()`. Auth for both
	/// `.minifluxBasic` and `.minifluxAPIToken` is applied inside `URLRequest(url:credentials:)`.
	func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
		if suspended {
			throw WebserviceError.suspended
		}
		return URLRequest(url: try apiURL(path: path, queryItems: query), credentials: credentials)
	}

	/// Sends a GET for `v1/<path>` and decodes the JSON body.
	func fetch<R: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> R {
		let (_, result) = try await session.send(request: makeRequest(path: path, query: query), resultType: R.self)
		guard let result else {
			throw WebserviceError.noData
		}
		return result
	}

	/// Pages through `/v1/entries/ids` — which caps each response at `entryIDsPageSize` — and
	/// returns the complete set. `filter` is `status=unread`, `starred=true`, etc.
	func retrieveEntryIDs(matching filter: [URLQueryItem]) async throws -> Set<Int64> {
		var entryIDs = Set<Int64>()
		var offset = 0

		while true {
			let query = filter + [
				URLQueryItem(name: "limit", value: String(Self.entryIDsPageSize)),
				URLQueryItem(name: "offset", value: String(offset))
			]
			let response: MinifluxEntryIDsResponse = try await fetch("entries/ids", query: query)

			entryIDs.formUnion(response.entryIDs)
			offset += response.entryIDs.count
			if response.entryIDs.isEmpty || offset >= response.total {
				break
			}
		}

		return entryIDs
	}

	func updateEntries(entryIDs: [Int64], payload: MinifluxUpdateEntriesPayload) async throws {
		guard !entryIDs.isEmpty else {
			return
		}
		try await session.send(request: makeRequest(path: "entries"), method: HTTPMethod.put, payload: payload)
	}

	static func entriesPageQueryItems(offset: Int) -> [URLQueryItem] {
		[
			URLQueryItem(name: "order", value: "id"),
			URLQueryItem(name: "direction", value: "asc"),
			URLQueryItem(name: "limit", value: String(entriesPageSize)),
			URLQueryItem(name: "offset", value: String(offset))
		]
	}

	/// Requires the server response before this call to have already confirmed credentials
	/// are valid — a plain 404 here means the server predates `/v1/version` (< 2.0.49).
	func validateServerVersion(endpoint: URL) async throws {
		let response: MinifluxVersionResponse
		do {
			let callURL = endpoint.appendingPathComponent("v1/version")
			let request = URLRequest(url: callURL, credentials: credentials)
			let (_, versionResponse) = try await session.send(request: request, resultType: MinifluxVersionResponse.self)
			guard let versionResponse else {
				throw WebserviceError.noData
			}
			response = versionResponse
		} catch {
			if case WebserviceError.httpError(let status) = error, status == HTTPResponseCode.notFound {
				throw MinifluxError.serverVersionTooOld(foundVersion: nil)
			}
			throw error
		}

		guard let version = MinifluxVersion(string: response.version) else {
			return
		}
		guard version >= Self.minimumVersion else {
			throw MinifluxError.serverVersionTooOld(foundVersion: response.version)
		}
	}

	func apiURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
		guard let apiBaseURL else {
			throw CredentialsError.missingEndpointURL
		}

		let base = apiBaseURL.appendingPathComponent("v1/\(path)")
		guard !queryItems.isEmpty else {
			return base
		}

		guard let url = base.appendingQueryItems(queryItems) else {
			throw WebserviceError.noURL
		}
		return url
	}
}
