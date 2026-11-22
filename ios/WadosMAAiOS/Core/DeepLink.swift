//
//  DeepLink.swift
//  Wado's MAA (iOS)
//
//  `wadosmaa://run/latest`、`run/<id>`、`today`、`copilot`、`settings`、`resign`（SPEC §6.3）。
//

import Foundation

enum DeepLink: Equatable {
    case latestRun
    case run(String)
    case today
    case copilot
    case settings
    case resign
    #if DEBUG
    case demo(String)
    #endif

    init?(url: URL) {
        guard url.scheme?.lowercased() == "wadosmaa", let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.first) {
        case ("run", "latest"?): self = .latestRun
        case let ("run", id?) where Self.isSafeRunID(id): self = .run(id)
        case ("today", nil): self = .today
        case ("copilot", nil): self = .copilot
        case ("settings", nil): self = .settings
        case ("resign", nil): self = .resign
        #if DEBUG
        case let ("demo", name?): self = .demo(name)
        #endif
        default: return nil
        }
    }

    private static func isSafeRunID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 120
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
            && !id.hasPrefix(".")
    }
}
