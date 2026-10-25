import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = HelperCore.shared
    private lazy var model: PanelModel = PanelModel()
    private var window: NSWindow?
    let headless: Bool

    init(headless: Bool) {
        self.headless = headless
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if headless {
            // 推迟到主运行循环开始转动之后再执行（子进程/XPC 需要运行循环分发事件）
            DispatchQueue.main.async { [weak self] in
                self?.runCLI()
            }
            return
        }
        // 主窗口应用：Dock 图标 + 标准窗口（⌘Q / 红色关闭即退出）
        let rootView = PanelView(model: model)
        let hosting = NSHostingController(rootView: rootView)
        let w = NSWindow(contentViewController: hosting)
        w.title = "游戏模式助手"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.contentMinSize = NSSize(width: 440, height: 480)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        core.log("App 启动（主窗口模式）")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true   // 关窗口即退出（工具型 App 的标准行为）
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.log("App 退出——HMCL 接线配置与备份保留在磁盘")
    }

    // MARK: - 命令行

    private func runCLI() {
        let core = HelperCore.shared
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func has(_ flag: String) -> Bool { args.contains(flag) }

        if has("--list") {
            for a in core.scanInstalledApps() {
                print("\(a.bundleID)\t\(a.name)\t\(a.path)\t\(a.supportState.rawValue)\t\(a.isRunning ? "running" : "stopped")")
            }
            exit(0)
        }

        if has("--enable") {
            guard let target = value("--enable") else { print("用法：--enable <app路径或bundleID>"); exit(2) }
            guard let path = resolveAppPath(target) else { print("找不到 App：\(target)"); exit(1) }
            let sem = DispatchSemaphore(value: 0)
            var outcome: PatchOutcome = .failed("未知")
            core.enableGameMode(path: path) { outcome = $0; sem.signal() }
            while sem.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            print(outcome.description)
            if case .success = outcome { exit(0) } else { exit(1) }
        }

        if has("--disable") {
            guard let target = value("--disable") else { print("用法：--disable <app路径或bundleID>"); exit(2) }
            guard let path = resolveAppPath(target) else { print("找不到 App：\(target)"); exit(1) }
            let sem = DispatchSemaphore(value: 0)
            var outcome: PatchOutcome = .failed("未知")
            core.disableGameMode(path: path) { outcome = $0; sem.signal() }
            while sem.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            print(outcome.description)
            exit(0)
        }

        if has("--status") {
            guard let target = value("--status") else { print("用法：--status <app路径或bundleID>"); exit(2) }
            guard let path = resolveAppPath(target) else { print("找不到 App：\(target)"); exit(1) }
            print("\(core.supportStatePublic(path: path).rawValue)")
            exit(0)
        }

        if has("--restart") {
            guard let target = value("--restart") else { print("用法：--restart <app路径或bundleID>"); exit(2) }
            guard let path = resolveAppPath(target) else { print("找不到 App：\(target)"); exit(1) }
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            core.restartApp(path: path) { ok = $0; sem.signal() }
            while sem.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            print(ok ? "OK 已重启" : "重启未完成")
            exit(ok ? 0 : 1)
        }

        if has("--auth-test") {
            // 诊断：同进程连续两次特权操作。第一次如需密码请输入；第二次应静默（<1 秒）。
            var t0 = Date()
            var r = PrivilegedRunner.shared.run("echo first-ok")
            print(String(format: "第一次：%.2f 秒 → %@", Date().timeIntervalSince(t0),
                         r == .success(output: "") ? "成功" : "\(r)"))
            t0 = Date()
            r = PrivilegedRunner.shared.run("echo second-ok")
            print(String(format: "第二次：%.2f 秒 → %@", Date().timeIntervalSince(t0),
                         r == .success(output: "") ? "成功（静默复用授权）" : "\(r)"))
            exit(0)
        }

        if has("--selftest") {
            let results = core.runSelfTest(dummyPath: value("--dummy"))
            var fails = 0
            for c in results {
                let mark: String
                switch c.status {
                case .pass: mark = "PASS"
                case .fail: mark = "FAIL"; fails += 1
                case .info: mark = "INFO"
                }
                print("[\(mark)] \(c.name) — \(c.detail)")
            }
            print("自检完成：共 \(results.count) 项，失败 \(fails) 项")
            exit(fails == 0 ? 0 : 1)
        }

        print("""
        游戏模式助手 GameModeHelper 命令行用法：
          --list                                    列出已安装 App 及其游戏模式状态
          --enable <app路径或bundleID>              为 App 开启游戏模式支持
          --disable <app路径或bundleID>             还原 App 的原始状态
          --status <app路径或bundleID>              查看游戏模式支持状态
          --restart <app路径或bundleID>             重启该 App（改动需要重启才生效）
          --selftest [--dummy <app路径>]            运行内置自检
        """)
        exit(0)
    }

    /// 把用户输入（路径或 bundleID）解析为 .app 路径
    private func resolveAppPath(_ target: String) -> String? {
        if target.hasSuffix(".app"), FileManager.default.fileExists(atPath: target) {
            return target
        }
        // bundleID：在已安装列表里找
        for a in core.scanInstalledApps() where a.bundleID == target {
            return a.path
        }
        return nil
    }
}
