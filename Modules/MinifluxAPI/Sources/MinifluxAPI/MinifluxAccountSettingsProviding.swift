//
//  MinifluxAccountSettingsProviding.swift
//  MinifluxAPI
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

/// The subset of an account's persisted settings that `MinifluxAPICaller` needs. The
/// concrete settings storage (`AccountSettings`) lives in the `Account` module, which
/// depends on `MinifluxAPI` — this protocol lets `MinifluxAPICaller` read and update
/// those settings without a reverse dependency back on `Account`.
@MainActor public protocol MinifluxAccountSettingsProviding: AnyObject {
	var endpointURL: URL? { get }
	var detectedServerVersion: String? { get set }
}
