//
//  LegacyUserTasks.swift
//  LegacyUserTasks
//
//  Created by hguandl on 2024/12/4.
//

import Foundation

@frozen public enum MAALegacyTask: Codable {
    case startup(LegacyStartupConfiguration)
    case closedown(LegacyClosedownConfiguration)
    case recruit(LegacyRecruitConfiguration)
    case infrast(LegacyInfrastConfiguration)
    case fight(LegacyFightConfiguration)
    case mall(LegacyMallConfiguration)
    case award(LegacyAwardConfiguration)
    case roguelike(LegacyRoguelikeConfiguration)
    case reclamation(LegacyReclamationConfiguration)
}

/// - Parameter directory: 旧版 `UserTasks.plist` 所在目录。调用方必须传 App 专属目录：
///   去沙盒后 `.applicationSupportDirectory` 是 `~/Library/Application Support` 根目录，
///   这里读完会删文件，不能落在共享目录里。
public func legacyTasks(in directory: URL) throws -> [MAALegacyTask] {
    let legacyTasksURL = directory
        .appendingPathComponent("UserTasks")
        .appendingPathExtension("plist")

    if !FileManager.default.fileExists(atPath: legacyTasksURL.path) {
        throw POSIXError(.ENOENT)
    }

    let data = try Data(contentsOf: legacyTasksURL)
    let tasks = try PropertyListDecoder().decode(OrderedStore<MAALegacyTask>.self, from: data)

    try? FileManager.default.removeItem(at: legacyTasksURL)
    return tasks.values
}
