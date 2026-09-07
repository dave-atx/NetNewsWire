//
//  HTMLMetadataNotification.swift
//  HTMLMetadata
//
//  Created by Brent Simmons on 4/6/26.
//

import Foundation

public extension Notification.Name {

	/// Posted when HTMLMetadata is cached. Posted on any thread.
	nonisolated static let htmlMetadataAvailable = Notification.Name("htmlMetadataAvailable")

	/// Posted when a home page’s metadata could not be fetched and no retry is pending.
	/// Posted on any thread. userInfo key: HTMLMetadataUserInfoKey.url
	nonisolated static let htmlMetadataUnavailable = Notification.Name("htmlMetadataUnavailable")
}

public struct HTMLMetadataUserInfoKey {

	public static let record = "htmlMetadataRecord" // HTMLMetadataRecord value
	public static let url = "url" // String value
}
