// wados-maa-launcher — S0-4 方案 B 极简固定签名 Swift launcher。
//
// 为什么需要它（见 P0_PREREQUISITE_SPIKES.md S0-4 实证结论）：
//   本机 `/Users/wadorudi/.local/bin/python3` 是 uv 管理的 ad-hoc 签名二进制（Identifier=-），
//   在 macOS 应用防火墙开启时按精确版本号路径放行（升级 Python 会失效），且无固定 Team/Identifier
//   无法长期稳定持有辅助功能（winmove）与录屏（screencapture）TCC 授权。
//
// 职责：
//   由 deploy.py 编译并以固定 Apple Development 身份 + Identifier `io.github.ffkiyo7.wados-maa.launcher`
//   签名；作为 LaunchAgent 入口监督拉起 Python 守护进程，统一承载防火墙入站放行与 TCC 授权，
//   并透传 SIGTERM / SIGINT / SIGHUP 信号（不杀守护进程已脱离会话的业务子进程）。

import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: wados-maa-launcher <executable> [args...]\n".utf8))
    exit(2)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: args[1])
process.arguments = Array(args.dropFirst(2))
process.environment = ProcessInfo.processInfo.environment
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)

let signalQueue = DispatchQueue(label: "io.github.ffkiyo7.wados-maa.launcher.signals")
var sources: [DispatchSourceSignal] = []

func forward(_ sig: Int32) {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler {
        if process.isRunning {
            kill(process.processIdentifier, sig)
        }
    }
    src.resume()
    sources.append(src)
}

forward(SIGTERM)
forward(SIGINT)
forward(SIGHUP)

do {
    try process.run()
} catch {
    FileHandle.standardError.write(Data("wados-maa-launcher failed to start \(args[1]): \(error)\n".utf8))
    exit(127)
}

process.waitUntilExit()
exit(process.terminationStatus)
