//
//  UpstreamStatus.swift
//  WadosMAAShared
//
//  `upstream status` 的结果。
//

import Foundation

public struct UpstreamStatus: Decodable, Sendable {
    public struct Versions: Decodable, Sendable {
        public let maaCli: String?
        public let maaCore: String?
        public let maaCoreRecorded: String?
        public let resourceLastUpdated: String?
        public let maaResourceHead: String?
        public let betaCoreLatest: String?
        public let betaCoreCheckedAt: String?
    }

    public struct Check: Decodable, Sendable {
        public let ok: Bool
        public let problems: [String]?
        public let reason: String?
    }

    public struct Lock: Decodable, Sendable {
        public let held: Bool
        public let text: String?
    }

    public struct Online: Decodable, Sendable {
        public let maaCliLatest: String?
        public let maaResourceRemoteHead: String?
        public let maaCliOutdated: Bool?
        public let maaResourceOutdated: Bool?
        public let errors: [String]?
    }

    public let verdict: String
    public let blockReason: String?
    public let running: Bool
    public let fresh: Bool
    public let lastSuccessAt: String?
    public let gameDayStart: String?
    public let updateBlocked: String?
    public let versions: Versions
    public let pinned: Check
    public let consistent: Check
    public let lock: Lock
    public let online: Online?
}
