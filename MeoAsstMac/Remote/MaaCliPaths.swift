//
//  MaaCliPaths.swift
//  Wado's MAA
//
//  Core 和资源只认 maa-cli 一个源（K7 / K20、S0a、S0b）。这里集中写 maa-cli 的目录，
//  别处不要自己拼路径。
//

import Foundation

enum MaaCliPaths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/Library/Application Support/com.loong.maa`：Core 的 `lib/` 和基础资源 `resource/`。
    static var base: URL { home.appending(path: "Library/Application Support/com.loong.maa", directoryHint: .isDirectory) }

    /// 动态库目录，rpath 指向这里。
    static var lib: URL { base.appending(path: "lib", directoryHint: .isDirectory) }

    /// MaaResource 的 git 热更新层。
    static var maaResource: URL { base.appending(path: "MaaResource", directoryHint: .isDirectory) }

    /// maa-cli 的热更新缓存（OTA tasks、活动日历）。
    static var hotUpdate: URL { home.appending(path: "Library/Caches/com.loong.maa", directoryHint: .isDirectory) }

    /// 用户资源层（`profiles/default.toml` 里 `user_resource = true`），maa-remote 的不变量 #4 / #59 落在这里。
    static var userConfig: URL { home.appending(path: ".config/maa-cli", directoryHint: .isDirectory) }

    /// maa-cli 刷新的活动日历。
    static var stageActivityFile: URL { hotUpdate.appending(path: "StageActivityV2.json") }

    /// 资源层，按 maa-cli 的加载顺序：基础 → MaaResource → 热更新缓存 → 用户层。
    /// 每一项是 `AsstLoadResource` 的参数（Core 实际加载的是它下面的 `resource/`），只列盘上存在的。
    static var resourceLayers: [URL] {
        [base, maaResource, hotUpdate, userConfig].filter {
            FileManager.default.fileExists(atPath: $0.appending(path: "resource").path)
        }
    }

    /// 在资源层里找一个文件，后加载的层优先（和 Core 的覆盖顺序一致）。
    /// - Parameter global: 外服的客户端目录名（如 `YoStarEN`），国服传 nil。
    static func resourceFile(_ relative: String, global: String? = nil) -> URL? {
        for layer in resourceLayers.reversed() {
            var dir = layer.appending(path: "resource", directoryHint: .isDirectory)
            if let global {
                dir = dir.appending(path: "global/\(global)/resource", directoryHint: .isDirectory)
            }
            let url = dir.appending(path: relative)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// 基础资源的 `version.json`（跟 Core zip 一起装）。
    static var baseVersionFile: URL { base.appending(path: "resource/version.json") }

    /// MaaResource 的 git HEAD。不起 git 子进程，直接读 `.git`。判断热更新层新旧要看它，不能只看 `last_updated`（S0b §1）。
    static func maaResourceHead() -> String? {
        let git = maaResource.appending(path: ".git", directoryHint: .isDirectory)
        guard let head = try? String(contentsOf: git.appending(path: "HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        guard head.hasPrefix("ref: ") else { return head }
        let ref = String(head.dropFirst(5))
        if let sha = try? String(contentsOf: git.appending(path: ref), encoding: .utf8) {
            return sha.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let packed = try? String(contentsOf: git.appending(path: "packed-refs"), encoding: .utf8) else {
            return nil
        }
        for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
            return String(line.split(separator: " ")[0])
        }
        return nil
    }
}
