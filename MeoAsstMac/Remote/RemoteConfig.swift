//
//  RemoteConfig.swift
//  Wado's MAA
//
//  maa-remote 在哪、用哪个 Python 跑、带什么环境（DEV_GUIDE §12.1）。
//  状态只有一份，在 `$HERMES_HOME/state/maa/`；GUI 不存副本（K3）。
//

import Foundation

enum RemoteConfig {
    /// 开发期（K1）用状态副本；S7 切线上时改成 `~/.hermes`，或在设置里改。
    static let developmentHermesHome = "~/Developer/forks/maa-remote-devhome"
    static let liveHermesHome = "~/.hermes"

    static let hermesHomeKey = "RemoteHermesHome"
    static let pythonKey = "RemotePython"

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 解析顺序：进程环境 `HERMES_HOME` → 设置里填的 → 开发副本。
    static var hermesHome: URL {
        if let env = ProcessInfo.processInfo.environment["HERMES_HOME"], !env.isEmpty {
            return expand(env)
        }
        if let stored = UserDefaults.standard.string(forKey: hermesHomeKey), !stored.isEmpty {
            return expand(stored)
        }
        return expand(developmentHermesHome)
    }

    static var isLiveHome: Bool {
        hermesHome.resolvingSymlinksInPath().standardizedFileURL.path
            == expand(liveHermesHome).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static var stateDirectory: URL { hermesHome.appending(path: "state/maa", directoryHint: .isDirectory) }
    static var scriptsDirectory: URL { hermesHome.appending(path: "scripts", directoryHint: .isDirectory) }
    static var actionScript: URL { scriptsDirectory.appending(path: "maa_action.py") }
    static var runLockFile: URL { stateDirectory.appending(path: "run.lock") }
    static var configFile: URL { stateDirectory.appending(path: "config.json") }

    /// maa-remote 的脚本兼容 3.9（`/usr/bin/python3`），有 Homebrew 的就用新的。
    static var python: String {
        if let stored = UserDefaults.standard.string(forKey: pythonKey), !stored.isEmpty {
            return (stored as NSString).expandingTildeInPath
        }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    /// 子进程环境：从 Finder 起的 App 没有 Homebrew 的 PATH；改动记成「由 Wado's MAA 改的」。
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HERMES_HOME"] = hermesHome.path
        env["MAA_ACTION_SOURCE"] = "gui"
        env["PYTHONIOENCODING"] = "utf-8"
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }
}
