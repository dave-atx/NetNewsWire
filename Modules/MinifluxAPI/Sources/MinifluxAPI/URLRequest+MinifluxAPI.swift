//
//  URLRequest+MinifluxAPI.swift
//  MinifluxAPI
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSWeb
import Secrets

extension URLRequest {

	/// Builds an authenticated request for one of Miniflux's two credential types.
	init(url: URL, minifluxCredentials: Credentials?) {
		self.init(url: url)

		guard let minifluxCredentials else {
			return
		}

		switch minifluxCredentials.type {
		case .minifluxBasic:
			let data = Data("\(minifluxCredentials.username):\(minifluxCredentials.secret)".utf8)
			let base64 = data.base64EncodedString()
			setValue("Basic \(base64)", forHTTPHeaderField: HTTPRequestHeader.authorization)
		case .minifluxAPIToken:
			setValue(minifluxCredentials.secret, forHTTPHeaderField: "X-Auth-Token")
		default:
			assertionFailure("Unexpected credentials type for Miniflux: \(minifluxCredentials.type)")
		}
	}
}
