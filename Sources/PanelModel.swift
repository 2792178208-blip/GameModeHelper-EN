import Cocoa
import SwiftUI

/// 面板数据源
final class PanelModel: ObservableObject {
    private let core = HelperCore.shared

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "在列表中选择一个正在运行的 App，为它开启系统游戏模式"
    @Published private(set) var detailText = ""
    @Published var selectedBundleID: String = "" {
        didSet { updateSelectionInfo() }
    }
    @Published private(set) var selectedState: AppEntry.SupportState = .unknown

    /// 上一次自动跟随前台选中的 bundleID。
    /// 用户手动点选后清空——此后刷新不再自动改选，直到用户重新打开面板。
    @Published private(set) var lastAutoSelected = ""

    /// 用户通过文件面板选择的 App（可能是未安装目录里的）
    @Published var customApp: AppEntry?

    init() {
        refresh()
    }

    var selectedApp: AppEntry? {
        if let custom = customApp { return custom }
        return apps.first { $0.bundleID == selectedBundleID }
    }

    func refresh() {
        core.scanRunningAppsAsync { [weak self] list in
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = list
                // 自动跟随前台：仅当用户从未选择、或当前仍是上一次自动选中的 App。
                // 用户手动选过的不覆盖。
                if self.selectedBundleID.isEmpty || self.selectedBundleID == self.lastAutoSelected {
                    if let front = list.first(where: { $0.isFrontmost }) {
                        self.selectedBundleID = front.bundleID
                        self.lastAutoSelected = front.bundleID
                    } else if self.selectedBundleID.isEmpty, let first = list.first {
                        self.selectedBundleID = first.bundleID
                        self.lastAutoSelected = first.bundleID
                    }
                }
                // 选中的 App 已经退出运行：若是自动跟随的，交给上面的前台跟随逻辑；
                // 若是手动选的则保持（操作区会显示默认提示）
                self.updateSelectionInfo()
            }
        }
    }

    /// 用户在列表里手动点了某个 App（此后刷新不再自动跟随前台）
    func userPicked(_ id: String?) {
        lastAutoSelected = ""
        customApp = nil
        selectedBundleID = id ?? ""
    }

    private func updateSelectionInfo() {
        guard let app = selectedApp else {
            selectedState = .unknown
            statusText = "在列表中选择一个正在运行的 App，为它开启系统游戏模式"
            detailText = ""
            return
        }
        selectedState = app.supportState
        if app.isBareProcess {
            selectedState = .unsupported
            statusText = "「\(app.name)」是裸程序（无 App 包，如 Java）"
            detailText = "点「开启」将自动生成游戏模式包装器并接入 HMCL：之后从 HMCL 正常启动的游戏（如 Minecraft）天生带游戏身份，原生全屏时自动开启游戏模式。当前正在运行的本局需重启后生效。\n提示：Game Mode 调度因游戏和机型而异，个别游戏开启后可能反而变卡——按 ⌘Esc 可随时关闭该 App 的游戏模式。"
            return
        }
        if app.isSystemVolume {
            statusText = "「\(app.name)」是系统自带 App（只读系统卷）"
            detailText = "它受 SIP 保护、位于只读系统卷上，无法修改声明，因此不能通过本工具开启游戏模式。"
            return
        }
        switch app.supportState {
        case .unsupported:
            statusText = "「\(app.name)」还没有游戏模式声明\(app.isFrontmost ? "（前台）" : "")"
            detailText = "开启并重启后，它以原生全屏（⌃⌘F）运行时，macOS 会自动开启游戏模式：CPU/GPU 优先调度、后台任务降载、蓝牙键鼠手柄采样率翻倍。可随时一键还原。"
        case .supported:
            statusText = "「\(app.name)」已具备游戏模式资格"
            detailText = "重启后，它以原生全屏运行时 macOS 会自动开启游戏模式；不需要时可随时「还原默认」。按 ⌘Esc 可呼出系统的 Game Overlay 查看模式状态。"
        case .unknown:
            statusText = "「\(app.name)」状态未知"
            detailText = ""
        }
    }

    // MARK: - 操作

    func enableSelected() {
        guard let app = selectedApp else { return }
        if app.isBareProcess {
            isBusy = true
            statusText = "正在生成游戏模式包装器并接入 HMCL…"
            detailText = ""
            core.setupWrapperForJava(executablePath: app.path) { [weak self] title, detail in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    self.statusText = "✅ \(title)"
                    self.detailText = detail
                    // 注意：这里不调用 refresh()——列表刷新会覆盖成功消息
                }
            }
            return
        }
        isBusy = true
        core.enableGameMode(path: app.path) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch outcome {
                case .success(let msg):
                    self.statusText = "✅ \(msg)"
                    self.detailText = "重启「\(app.name)」后生效：它以原生全屏（⌃⌘F）运行时，macOS 会自动开启游戏模式。"
                case .needsAdmin:
                    self.statusText = "❌ 需要管理员权限（意外路径）"
                case .failed(let msg):
                    self.statusText = "❌ \(msg)"
                }
                self.refresh()
            }
        }
    }

    func disableSelected() {
        guard let app = selectedApp else { return }
        if app.isBareProcess {
            isBusy = true
            core.unwireHMCL { [weak self] title, detail in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    self.statusText = "✅ \(title)"
                    self.detailText = detail
                }
            }
            return
        }
        isBusy = true
        core.disableGameMode(path: app.path) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch outcome {
                case .success(let msg):
                    self.statusText = "✅ \(msg)"
                    self.detailText = "已恢复「\(app.name)」的原始 Info.plist，重启后完全回到从前。"
                case .needsAdmin:
                    self.statusText = "❌ 需要管理员权限（意外路径）"
                case .failed(let msg):
                    self.statusText = "❌ \(msg)"
                }
                self.refresh()
            }
        }
    }

    /// 重启 App（用户明确点击 + 确认后才走到这里）
    func restartSelected() {
        guard let app = selectedApp else { return }
        let alert = NSAlert()
        alert.messageText = "重启「\(app.name)」？"
        alert.informativeText = "改动需要重启该 App 才能生效。\n它会正常退出并重新打开（未保存的内容可能丢失）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertSecondButtonReturn { return }

        isBusy = true
        core.restartApp(path: app.path) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.statusText = ok ? "✅「\(app.name)」已重启，声明已生效" : "❌ 重启未完成（App 没有正常退出，已放弃启动以避免双开）"
                if ok { self.detailText = "现在把它切到原生全屏（⌃⌘F）试试；按 ⌘Esc 可呼出 Game Overlay 查看游戏模式状态。" }
                self.refresh()
            }
        }
    }

    /// 通过文件面板选择 App
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            let name = url.lastPathComponent.replacingOccurrences(of: ".app", with: "")
            customApp = AppEntry(bundleID: core.bundleIDOfAppPublic(path: path) ?? path,
                                 name: name, path: path,
                                 isRunning: core.isAppRunning(bundleID: core.bundleIDOfAppPublic(path: path) ?? ""),
                                 supportState: core.supportStatePublic(path: path))
            lastAutoSelected = ""
            selectedBundleID = customApp?.bundleID ?? ""
            updateSelectionInfo()
        }
    }

    /// 面板「创建启动器…」：为 Java/jar/任意程序生成带游戏声明的替身 App
    func createGameLauncher() {
        let alert = NSAlert()
        alert.messageText = "创建游戏模式启动器"
        alert.informativeText = "生成一个自带游戏模式声明的替身 App：双击它即以游戏身份启动目标程序。适合你能直接启动的程序（jar、裸可执行程序等）。\n注意：HMCL 等启动器拉起的游戏请在列表中选择 java 条目自动接线，不要用本对话框包装启动器本身（替身身份不会传递给启动器的子进程）。"
        alert.alertStyle = .informational

        let name = NSTextField(string: "")
        name.placeholderString = "替身名称（如：Minecraft 游戏模式）"
        let path = NSTextField(string: "")
        path.placeholderString = "程序路径：可执行文件或 .jar"
        let args = NSTextField(string: "")
        args.placeholderString = "启动参数（可选）"
        let cwd = NSTextField(string: "")
        cwd.placeholderString = "工作目录（可选，默认程序所在目录）"

        // 透传模式：替身运行器作为启动器的"自定义 Java/包装命令"被调用，
        // 启动时把收到的参数原样转交给真实 Java（HMCL 等，实验性）
        let passthrough = NSButton(checkboxWithTitle: "透传模式（HMCL 接入：勾选后把启动器里的 Java 路径指向替身运行器）",
                                   target: nil, action: nil)
        var isPassthrough = false
        final class CheckTrampoline: NSObject {
            let handler: (NSButton) -> Void
            init(_ handler: @escaping (NSButton) -> Void) { self.handler = handler; super.init() }
            @objc func fire(_ sender: NSButton) { handler(sender) }
        }
        let checkTrampoline = CheckTrampoline { [weak path] box in
            guard let path else { return }
            if box.state == .on {
                path.placeholderString = "真实 Java 路径（留空自动探测）"
                if path.stringValue.isEmpty { path.stringValue = StubGenerator.whichJava() ?? "" }
            } else {
                path.placeholderString = "程序路径：可执行文件或 .jar"
            }
        }
        passthrough.target = checkTrampoline
        passthrough.action = #selector(CheckTrampoline.fire(_:))

        final class Trampoline: NSObject {
            let handler: () -> Void
            init(_ handler: @escaping () -> Void) { self.handler = handler; super.init() }
            @objc func fire() { handler() }
        }
        let trampoline = Trampoline {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                path.stringValue = url.path
                if name.stringValue.isEmpty {
                    name.stringValue = url.deletingPathExtension().lastPathComponent + "（游戏模式）"
                }
            }
        }
        let browse = NSButton(title: "浏览…", target: trampoline, action: #selector(Trampoline.fire))
        browse.bezelStyle = .rounded

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.addRow(with: [NSTextField(labelWithString: "名称"), name])
        grid.addRow(with: [NSTextField(labelWithString: "程序"), path])
        grid.addRow(with: [NSTextField(labelWithString: ""), browse])
        grid.addRow(with: [NSTextField(labelWithString: "参数"), args])
        grid.addRow(with: [NSTextField(labelWithString: "工作目录"), cwd])
        grid.column(at: 1).width = 250
        for row in 0..<grid.numberOfRows { grid.row(at: row).height = 26 }
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(grid.numberOfRows) * 26 + 8)
        alert.accessoryView = grid
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        if alert.runModal() != .alertFirstButtonReturn { return }

        var program = path.stringValue.trimmingCharacters(in: .whitespaces)
        let argList = args.stringValue.split(whereSeparator: { $0 == " " }).map(String.init)

        // 透传模式：程序路径 = 真实 Java（默认自动探测），替身把参数原样转交
        if passthrough.state == .on {
            let java = program.isEmpty ? StubGenerator.whichJava() : program
            guard let java, !java.isEmpty else {
                showNotice("透传模式需要真实 Java 路径（未找到 Java，请先安装 JDK）"); return
            }
            program = java
            isPassthrough = true
        }
        guard !program.isEmpty else {
            showNotice("未选择程序路径"); return
        }
        // .jar 自动包一层 java -jar
        var extraNote = ""
        var finalProgram = program
        var finalArgs = argList
        if program.hasSuffix(".jar") {
            guard let java = StubGenerator.whichJava() else {
                showNotice("未找到 Java。请先安装 JDK（HMCL 自带的 JRE 也可以：指向其 bin/java）。")
                return
            }
            finalArgs = ["-jar", program] + argList
            finalProgram = java
            extraNote = "\n将使用 Java：\(java)"
        }

        isBusy = true
        StubGenerator.generate(
            .init(name: name.stringValue.isEmpty ? "游戏模式启动器" : name.stringValue,
                  program: finalProgram,
                  args: finalArgs,
                  cwd: cwd.stringValue.isEmpty ? nil : cwd.stringValue,
                  passthrough: isPassthrough,
                  destination: nil)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let url):
                    self.statusText = "✅ 启动器已创建：\((url as NSString).lastPathComponent)"
                    if isPassthrough {
                        let runner = (url as NSString).appendingPathComponent("Contents/MacOS/GameStubRunner")
                        self.detailText = "已创建透传替身。把启动器（HMCL 等）里的 Java 路径设置为：\n\(runner)\n（实验性：以该方式启动的游戏全屏后即有游戏模式。）\(extraNote)"
                    } else {
                        self.detailText = "双击它即以游戏身份启动目标程序，全屏时 macOS 会自动开启游戏模式。\(extraNote)"
                    }
                    self.refresh()
                case .failure(let message):
                    self.statusText = "❌ 创建失败"
                    self.detailText = message
                }
            }
        }
    }


    private func showNotice(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.addButton(withTitle: "好"); a.runModal()
    }

    /// 面板「退出」：确认后结束本工具（接线配置与备份保留在磁盘，不受影响）
    func quitApp() {
        let alert = NSAlert()
        alert.messageText = "退出游戏模式助手？"
        alert.informativeText = "菜单栏图标将消失。已接入的 HMCL 配置、包装器和备份都保留在磁盘上，随时可重新打开继续使用。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    /// 面板「管理员授权」按钮：预先授权，本会话内后续操作全部免密
    func preAuthorize() {
        isBusy = true
        core.preAuthorize { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                let alert = NSAlert()
                if let err {
                    alert.messageText = "授权未完成"
                    alert.informativeText = err
                    alert.alertStyle = .warning
                } else {
                    alert.messageText = "✅ 管理员授权成功"
                    alert.informativeText = "本次运行期间，开启 / 还原 / 重启都不再需要输入密码。"
                    alert.alertStyle = .informational
                }
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    func runSelfTest() {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = self.core.runSelfTest()
            var text = ""
            var fails = 0
            for c in results {
                switch c.status {
                case .pass: text += "✅ \(c.name)：\(c.detail)\n"
                case .fail: text += "❌ \(c.name)：\(c.detail)\n"; fails += 1
                case .info: text += "ℹ️ \(c.name)：\(c.detail)\n"
                }
            }
            text += fails == 0 ? "\n全部通过。" : "\n有 \(fails) 项未通过。"
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "自检结果"
                alert.informativeText = text
                alert.alertStyle = fails == 0 ? .informational : .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }
}
