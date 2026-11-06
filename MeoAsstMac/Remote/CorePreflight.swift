//
//  CorePreflight.swift
//  Wado's MAA
//
//  libMaaCore 是弱链接的（S0a §6.1）：maa-cli 更新时会先删掉整个 lib/ 再解压，这段时间里
//  App 照常能启动，但所有 Asst* 符号都是 NULL，调用就崩。所以任何 Asst* 调用之前都要先过这里。
//

import Darwin
import Foundation
import MaaCore

enum CorePreflight {
    /// 头文件钉住的版本，和 `Vendor/MaaCore/PINNED_VERSION` 一致；`tools/sync-maacore.sh` 会一起改。
    static let pinnedHeaderVersion = "v6.21.4"

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    /// libMaaCore 在启动时有没有被 dyld 找到。
    static var coreLoaded: Bool {
        dlsym(rtldDefault, "AsstGetVersion") != nil
    }

    /// `AsstGetMapLevelKey` / `AsstGetItemName` 在 `AsstCallerExtra.h` 里，是上游明说的实验接口，单独查。
    static var extraCallersAvailable: Bool {
        dlsym(rtldDefault, "AsstGetMapLevelKey") != nil && dlsym(rtldDefault, "AsstGetItemName") != nil
    }

    /// 进程里加载的 Core 版本（V4）。Core 没加载时返回 nil。
    static var loadedVersion: String? {
        guard coreLoaded, let raw = AsstGetVersion() else { return nil }
        return String(cString: raw)
    }

    /// 版本是否和头文件同一个 `vX.Y`。不同只告警，不拦：头文件只描述函数签名，次版本内一般兼容。
    static func isCompatible(_ version: String) -> Bool {
        majorMinor(version) == majorMinor(pinnedHeaderVersion)
    }

    private static func majorMinor(_ version: String) -> String {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return trimmed.split(separator: ".").prefix(2).joined(separator: ".")
    }

    // MARK: - 进程里的 Core 和盘上的是否同一份

    struct Identity: Equatable, Sendable {
        let path: String
        let inode: UInt64
        let mtime: TimeInterval
    }

    /// 进程里实际映射的 libMaaCore 的路径，用 `dladdr` 从 `AsstGetVersion` 反查。
    static var loadedImagePath: String? {
        guard let symbol = dlsym(rtldDefault, "AsstGetVersion") else { return nil }
        var info = Dl_info()
        guard dladdr(symbol, &info) != 0, let name = info.dli_fname else { return nil }
        return String(cString: name)
    }

    static func identity(atPath path: String) -> Identity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let mtime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        return Identity(path: path, inode: UInt64(st.st_ino), mtime: mtime)
    }

    /// 启动时记下的那份。maa-cli 换 Core 是「先删再解压」，新文件 inode 一定不同。
    @MainActor static private(set) var launchIdentity: Identity?

    @MainActor static func recordLaunchIdentity() {
        if let path = loadedImagePath {
            launchIdentity = identity(atPath: path)
        }
    }

    /// 盘上的 libMaaCore 已经不是进程里那份（被 maa-cli 换掉或正在更新）。
    @MainActor static var coreReplacedOnDisk: Bool {
        guard let launch = launchIdentity else { return false }
        return identity(atPath: launch.path) != launch
    }
}
