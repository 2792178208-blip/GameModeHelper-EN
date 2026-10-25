import Cocoa

/// 「游戏模式助手」核心引擎。
///
/// 原理（Apple 官方公开机制，见开发者论坛 DTS 工程师答复）：
///   在 App 的 Info.plist 中声明 `LSSupportsGameMode`（macOS 26+）/ `GCSupportsGameMode`
///   （macOS 14+  legacy）为 true，并设置 `LSApplicationCategoryType` 为游戏类后，
///   系统即把该 App 视为游戏——它进入全屏时，macOS 会自动为它开启游戏模式
///   （CPU/GPU 优先、后台任务降载、蓝牙采样率翻倍）。
///   很多游戏/模拟器（CrossOver、RetroArch、GeForce NOW、Parallels、浏览器游戏等）
///   没有这些声明，所以系统不会为它们开启——本工具就是补上这一步。
///
/// 安全设计：
///   1. 不退出、不强杀任何进程；「重启 App」仅在你明确点击并确认后发生
///   2. 改动前备份 Info.plist，一键还原（恢复原始文件）
///   3. 改 plist 后做 ad-hoc 重签，保证 App 签名有效、可正常启动
///   4. 修改 /Applications 下 App 需要管理员授权时，走系统标准密码框
///   5. 只改 Info.plist 的三个键，不碰 App 任何资源文件
final class HelperCore {
    static let shared = HelperCore()

    // MARK: - 路径
    private let fm = FileManager.default
    private var supportDir: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameModeHelper", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var backupDir: URL { supportDir.appendingPathComponent("backups", isDirectory: true) }
    private var logDir: URL {
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GameModeHelper")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var logFile: URL { logDir.appendingPathComponent("helper.log") }

    private let plistBuddy = "/usr/libexec/PlistBuddy"
    private let plutil = "/usr/bin/plutil"
    private let codesign = "/usr/bin/codesign"
    private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 所有补丁（开启/还原）串行执行——副本替换(swap)绝不允许并发交错
    private let patchQueue = DispatchQueue(label: "com.gamemodehelper.app.patch")

    private init() {}

    // MARK: - 日志
    func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: line.data(using: .utf8)!)
            _ = try? handle.close()
        } else {
            _ = try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 扫描

    /// 扫描本机已安装的 App（用户域 + 系统域）。
    /// frontmostBundleID 非空时，该 App 标记为前台并排在列表最前。
    func scanInstalledApps(frontmostBundleID: String? = nil) -> [AppEntry] {
        var result: [AppEntry] = []
        var seen = Set<String>()
        let dirs = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = "\(dir)/\(item)"
                guard let bid = bundleIDOfApp(at: path), !bid.isEmpty else { continue }
                if seen.contains(bid) { continue }
                seen.insert(bid)
                let name = (item as NSString).deletingPathExtension
                let entry = AppEntry(bundleID: bid, name: name, path: path,
                                     isRunning: isAppRunning(bundleID: bid),
                                     isFrontmost: bid == frontmostBundleID,
                                     isSystemVolume: isReadOnlyVolume(path),
                                     supportState: supportState(at: path))
                result.append(entry)
            }
        }
        // 运行中但未在上述目录的 App（例如 /tmp 下的测试 App）
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  let url = app.bundleURL, url.path.hasSuffix(".app"),
                  !seen.contains(bid) else { continue }
            seen.insert(bid)
            let path = url.path
            result.append(AppEntry(bundleID: bid,
                                   name: app.localizedName ?? (path as NSString).lastPathComponent,
                                   path: path,
                                   isRunning: true,
                                   isFrontmost: bid == frontmostBundleID,
                                   supportState: supportState(at: path)))
        }
        return result.sorted {
            if $0.isFrontmost != $1.isFrontmost { return $0.isFrontmost }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }

    /// 扫描当前正在运行的 App（前台 App 排最前）——面板列表用，避免全量安装列表太长。
    /// 没在运行的 App 由用户通过「选择 App…」手动指定。
    func scanRunningApps(frontmostBundleID: String? = nil) -> [AppEntry] {
        var result: [AppEntry] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            // .regular = 有窗口界面的 App；菜单栏常驻类（如本工具自身）不算
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier, !bid.isEmpty,
                  let url = app.bundleURL, url.path.hasSuffix(".app"),
                  !seen.contains(bid) else { continue }
            seen.insert(bid)
            result.append(AppEntry(bundleID: bid,
                                   name: app.localizedName ?? (url.path as NSString).lastPathComponent,
                                   path: url.path,
                                   isRunning: true,
                                   isFrontmost: bid == frontmostBundleID,
                                   isSystemVolume: isReadOnlyVolume(url.path),
                                   supportState: supportState(at: url.path)))
        }
        // 裸进程合并进列表（java、jar 启动的 Minecraft 等无 App 包的程序）
        var known = Set(result.map { $0.path })
        for path in runningBareProcessPaths() where !known.contains(path) {
            known.insert(path)
            result.append(AppEntry(bundleID: "bare:" + path,
                                   name: (path as NSString).lastPathComponent,
                                   path: path,
                                   isRunning: true,
                                   isBareProcess: true,
                                   supportState: .unsupported))
        }
        return result.sorted {
            if $0.isFrontmost != $1.isFrontmost { return $0.isFrontmost }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 枚举正在运行的「裸进程」（无 App 包、当前用户启动）：java、jar 启动的 Minecraft 等。
    /// 通过 sysctl 全量进程表 + proc_pidpath 取真实可执行路径。
    func runningBareProcessPaths() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        let myUID = getuid()
        var out: Set<String> = []
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 1, Int(p.kp_eproc.e_ucred.cr_uid) == myUID else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            // 排除：App 包内的（已在 App 列表）、系统目录、本工具自身、常见 shell
            if path.contains("/.app/") || path.contains("GameModeHelper") { continue }
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
                || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/") || path.hasPrefix("/usr/lib/") { continue }
            let base = (path as NSString).lastPathComponent
            if ["zsh", "bash", "sh", "fish", "tcsh", "login"].contains(base) { continue }
            out.insert(path)
        }
        return out.sorted()
    }

    /// 为裸程序（java 等）生成包装器替身，并自动接入 HMCL 实例配置（wrapper 字段，带备份）。
    /// 返回 (标题, 详情)。
    func setupWrapperForJava(executablePath: String, completion: @escaping (String, String) -> Void) {
        patchQueue.async { [weak self] in
            guard let self else { return }
            let fm = self.fm
            let base = (executablePath as NSString).lastPathComponent
            // HMCL 的 wrapper 按空格分词，替身名不能有空格
            let isJava = base.lowercased().contains("java")
            let stubName = isJava ? "HMCL游戏模式包装器" : "\(base)游戏模式包装器".replacingOccurrences(of: " ", with: "_")

            // 固定路径：重复点击收敛到同一个替身（重命名会产生编号替身并破坏已接线配置）
            let appsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            let stubURL = appsDir.appendingPathComponent("\(stubName).app", isDirectory: true)
            let stubPath = stubURL.path
            let runnerPath = stubURL.appendingPathComponent("Contents/MacOS/GameStubRunner").path
            let configPath = stubURL.appendingPathComponent("Contents/config.json").path

            if !fm.fileExists(atPath: stubPath) {
                let sem = DispatchSemaphore(value: 0)
                var genErr = ""
                StubGenerator.generate(.init(name: stubName, program: executablePath, args: [],
                                             cwd: nil, passthrough: false, wrapper: true,
                                             destination: appsDir)) { r in
                    switch r {
                    case .success(let u): _ = u
                    case .failure(let m): genErr = m
                    }
                    sem.signal()
                }
                sem.wait()
                guard fm.fileExists(atPath: stubPath) else {
                    self.log("包装器生成失败：\(genErr)")
                    completion("生成失败", genErr); return
                }
            } else {
                // 已存在：确保 config 与 runner 为最新（游戏 Java 路径可能变化）
                let config = StubGenerator.StubConfig(program: executablePath, args: [],
                                                      cwd: nil, passthrough: false, wrapper: true)
                if let data = try? JSONEncoder().encode(config) {
                    try? data.write(to: URL(fileURLWithPath: configPath))
                }
                if !fm.fileExists(atPath: runnerPath),
                   let bundled = Bundle.main.path(forResource: "GameStubRunner", ofType: nil) {
                    try? fm.copyItem(atPath: bundled, toPath: runnerPath)
                    _ = self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", stubPath])
                }
                _ = self.run("/usr/bin/xattr", ["-rc", stubPath])
                _ = self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", stubPath])
            }

            // 双保险：把便携/用户两处 home 的全局 game-settings.json 里所有 preset 的
            // commandWrapper 一并设置（未来新实例无实例文件时也能继承到包装器）
            var presetHomes: [String] = []
            let localHome = "/Users/\(NSUserName())/hmcl/.hmcl/config/game-settings.json"
            let userHome = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/hmcl/config/game-settings.json").path
            for h in [localHome, userHome] where fm.fileExists(atPath: h) { presetHomes.append(h) }
            for presetFile in presetHomes {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: presetFile)),
                      var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var presets = obj["presets"] as? [[String: Any]] else { continue }
                if !fm.fileExists(atPath: presetFile + ".gmhelper-bak") {
                    try? fm.copyItem(at: URL(fileURLWithPath: presetFile),
                                     to: URL(fileURLWithPath: presetFile + ".gmhelper-bak"))
                }
                for i in presets.indices { presets[i]["commandWrapper"] = runnerPath }
                obj["presets"] = presets
                if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                    try? out.write(to: URL(fileURLWithPath: presetFile))
                    self.log("已设置全局 preset 的 commandWrapper：\(presetFile)")
                }
            }

            // 发现 HMCL 游戏目录并接线（versions/*/hmclversion.cfg 的 wrapper 字段）
            var gameDirs: [String] = []
            let dirsFile = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/hmcl/config/user-game-directories.json")
            if let data = try? Data(contentsOf: dirsFile),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dirs = obj["directories"] as? [[String: Any]] {
                for d in dirs { if let p = d["path"] as? String { gameDirs.append(p) } }
            }
            let defaultDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/minecraft").path
            if fm.fileExists(atPath: defaultDir), !gameDirs.contains(defaultDir) { gameDirs.append(defaultDir) }

            var wired = 0, skipped = 0, already = 0
            for dir in gameDirs {
                let versionsDir = dir + "/versions"
                guard let items = try? fm.contentsOfDirectory(atPath: versionsDir) else { continue }
                for v in items {
                    // ── HMCL 3.16+ 新系统：<版本>/.hmcl/config/instance-game-settings.json ──
                    let instDir = versionsDir + "/" + v + "/.hmcl/config"
                    let instCfg = instDir + "/instance-game-settings.json"
                    var instObj: [String: Any] = [:]
                    var instExists = fm.fileExists(atPath: instCfg)
                    if instExists,
                       let data = try? Data(contentsOf: URL(fileURLWithPath: instCfg)),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        instObj = obj
                    } else {
                        instObj = ["$schema": "https://schemas.glavo.site/hmcl/instance-game-settings/1.0.0"]
                    }
                    let curWrapper = instObj["commandWrapper"] as? String ?? ""
                    if curWrapper == runnerPath { already += 1 }
                    else {
                        if instExists, !fm.fileExists(atPath: instCfg + ".gmhelper-bak") {
                            try? fm.copyItem(at: URL(fileURLWithPath: instCfg), to: URL(fileURLWithPath: instCfg + ".gmhelper-bak"))
                        }
                        if !instExists { try? fm.createDirectory(at: URL(fileURLWithPath: instDir), withIntermediateDirectories: true) }
                        instObj["commandWrapper"] = runnerPath
                        var ov = instObj["overrideProperties"] as? [String] ?? []
                        if !ov.contains("commandWrapper") { ov.append("commandWrapper") }
                        instObj["overrideProperties"] = ov
                        if let out = try? JSONSerialization.data(withJSONObject: instObj, options: [.prettyPrinted]),
                           (try? out.write(to: URL(fileURLWithPath: instCfg))) != nil {
                            wired += 1
                            self.log("已接线 HMCL 实例 \(v)（instance-game-settings：commandWrapper）")
                        }
                    }

                    // ── 旧版 HMCL 兼容：hmclversion.cfg 的 wrapper 字段 ──
                    let cfg = versionsDir + "/" + v + "/hmclversion.cfg"
                    if !fm.fileExists(atPath: cfg) {
                        // 实例没有配置文件：创建最小配置
                        // usesGlobal=false 必须显式声明——缺失时 HMCL 按全局设置处理，wrapper 会被忽略
                        let minimal: [String: Any] = ["usesGlobal": false, "wrapper": runnerPath]
                        guard let out = try? JSONSerialization.data(withJSONObject: minimal, options: [.prettyPrinted, .sortedKeys]),
                              (try? out.write(to: URL(fileURLWithPath: cfg))) != nil else { continue }
                        wired += 1
                        self.log("已创建并接线 HMCL 实例 \(v)（原无配置文件）")
                        continue
                    }
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: cfg)),
                          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let cur = obj["wrapper"] as? String ?? ""
                    if cur == runnerPath { already += 1; continue }   // 重复点击：已接线
                    if !cur.isEmpty { skipped += 1; continue }   // 用户手动配过包装命令，不覆盖
                    if !fm.fileExists(atPath: cfg + ".gmhelper-bak") {
                        try? fm.copyItem(at: URL(fileURLWithPath: cfg), to: URL(fileURLWithPath: cfg + ".gmhelper-bak"))
                    }
                    obj["wrapper"] = runnerPath
                    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                          (try? out.write(to: URL(fileURLWithPath: cfg))) != nil else { continue }
                    wired += 1
                    self.log("已接线 HMCL 实例 \(v)：wrapper → 包装器")
                }
            }
            self.log("包装器：\(stubPath)；接线 \(wired) 个实例（已接线 \(already)、跳过 \(skipped)）")

            // 幂等：所有实例都已指向本包装器时不重复生成——删除刚生成的多余替身
            if wired == 0, already > 0 {
                try? fm.removeItem(atPath: stubPath)
                completion("已经接入过了", "所有 HMCL 实例都已指向包装器，无需重复操作。从 HMCL 重启游戏即可生效。")
                return
            }

            // 清理历史遗留的编号替身
            for item in (try? fm.contentsOfDirectory(atPath: appsDir.path)) ?? [] where item.hasPrefix("\(stubName) ") && item.hasSuffix(".app") {
                try? fm.removeItem(at: appsDir.appendingPathComponent(item))
            }

            let title = wired > 0 ? "已自动接入 HMCL（\(wired) 个实例）" : "包装器已生成"
            let detail = wired > 0
                ? "从 HMCL 正常启动游戏即可：HMCL 会经由包装器启动 java，游戏天生带游戏身份，原生全屏（⌃⌘F）时自动开启游戏模式。当前正在运行的本局需重启游戏后生效。\n包装器：\(runnerPath)\n已跳过 \(skipped) 个手动配置过包装命令的实例。"
                : "未找到可自动接线的 HMCL 实例配置。可在 HMCL 实例设置的「包装命令/Wrapper」中填入：\(runnerPath)"
            completion(title, detail)
        }
    }

    /// 还原：把接线时备份的 hmclversion.cfg 恢复（清空 wrapper）
    func unwireHMCL(completion: @escaping (String, String) -> Void) {
        patchQueue.async { [weak self] in
            guard let self else { return }
            let fm = self.fm
            var restored = 0
            // 恢复全局 preset 备份（两处 home）
            let localHome = "/Users/\(NSUserName())/hmcl/.hmcl/config/game-settings.json"
            let userHome = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/hmcl/config/game-settings.json").path
            for presetFile in [localHome, userHome] {
                let bak = presetFile + ".gmhelper-bak"
                guard fm.fileExists(atPath: bak) else { continue }
                try? fm.removeItem(atPath: presetFile)
                try? fm.moveItem(atPath: bak, toPath: presetFile)
                restored += 1
                self.log("已还原全局 preset：\(presetFile)")
            }
            let dirsFile = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/hmcl/config/user-game-directories.json")
            var gameDirs: [String] = []
            if let data = try? Data(contentsOf: dirsFile),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dirs = obj["directories"] as? [[String: Any]] {
                for d in dirs { if let p = d["path"] as? String { gameDirs.append(p) } }
            }
            let defaultDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/minecraft").path
            gameDirs.append(defaultDir)
            for dir in gameDirs {
                let versionsDir = dir + "/versions"
                guard let items = try? fm.contentsOfDirectory(atPath: versionsDir) else { continue }
                for v in items {
                    // 新系统：instance-game-settings.json 恢复备份
                    let instBak = versionsDir + "/" + v + "/.hmcl/config/instance-game-settings.json.gmhelper-bak"
                    let instCfg = versionsDir + "/" + v + "/.hmcl/config/instance-game-settings.json"
                    if fm.fileExists(atPath: instBak) {
                        try? fm.removeItem(atPath: instCfg)
                        try? fm.moveItem(atPath: instBak, toPath: instCfg)
                        restored += 1
                        self.log("已还原 HMCL 实例 \(v) 的实例设置（新系统）")
                        continue
                    }
                    // 旧系统：hmclversion.cfg 恢复备份
                    let bak = versionsDir + "/" + v + "/hmclversion.cfg.gmhelper-bak"
                    guard fm.fileExists(atPath: bak) else { continue }
                    let cfg = (bak as NSString).deletingPathExtension
                    try? fm.removeItem(atPath: cfg)
                    try? fm.moveItem(atPath: bak, toPath: cfg)
                    restored += 1
                    self.log("已还原 HMCL 实例 \(v) 的包装命令配置")
                }
            }
            completion(restored > 0 ? "已还原 \(restored) 个 HMCL 实例的包装命令设置" : "没有需要还原的接线",
                      "重启对应游戏后生效。")
        }
    }

    /// 异步扫描运行中 App（供 UI 用）。前台 App 在主线程取样，扫描在后台执行。
    func scanRunningAppsAsync(_ completion: @escaping ([AppEntry]) -> Void) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            completion(self.scanRunningApps(frontmostBundleID: frontmost))
        }
    }

    /// 异步扫描已安装 App（全量；CLI/解析用）
    func scanInstalledAppsAsync(_ completion: @escaping ([AppEntry]) -> Void) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            completion(self.scanInstalledApps(frontmostBundleID: frontmost))
        }
    }

    func bundleIDOfAppPublic(path: String) -> String? { bundleIDOfApp(at: path) }
    func supportStatePublic(path: String) -> AppEntry.SupportState { supportState(at: path) }

    private func bundleIDOfApp(at path: String) -> String? {
        let r = run(plistBuddy, ["-c", "Print :CFBundleIdentifier", "\(path)/Contents/Info.plist"])
        let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: - 状态读取

    /// 读取 App 的游戏模式声明状态。键不存在视为未开启。
    func supportState(at path: String) -> AppEntry.SupportState {
        let plist = "\(path)/Contents/Info.plist"
        let modern = readBool(plist, key: "LSSupportsGameMode")    // macOS 26+
        let legacy = readBool(plist, key: "GCSupportsGameMode")    // macOS 14+
        if modern == true || legacy == true { return .supported }
        return .unsupported
    }

    private func readBool(_ plist: String, key: String) -> Bool? {
        let r = run(plistBuddy, ["-c", "Print :\(key)", plist])
        guard r.status == 0 else { return nil }
        switch r.output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    // MARK: - 开启 / 还原

    /// 是否位于只读卷（SIP 系统卷，如 /System、/System/Cryptexes）。root 也无法写入。
    private func isReadOnlyVolume(_ path: String) -> Bool {
        var fs = statfs()
        if statfs(path, &fs) == 0, (fs.f_flags & UInt32(MNT_RDONLY)) != 0 { return true }
        // 兜底：statfs 对部分符号链接（如 /Applications/Safari.app → /System/Cryptexes/...）
        // 不带只读标志，解析后落在 /System 下的一律视为系统卷
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/System/")
    }

    /// 真实写入探针：往 Contents 里实际建一个临时文件再删掉。
    /// 不用 isWritableFile——它受「App 管理」TCC 按进程身份判定的影响会误报 false，
    /// 导致本可用户态完成的操作误走管理员路径（弹密码框）。
    private func canWriteBundle(_ path: String) -> Bool {
        let probe = "\(path)/Contents/.gmhelper-probe-\(Int.random(in: 1000...9999))"
        guard fm.createFile(atPath: probe, contents: Data()) else { return false }
        try? fm.removeItem(atPath: probe)
        return true
    }

    /// 注入三个键的命令串（含分类键的智能处理：已有游戏分类保留，非游戏分类覆盖为 games）
    private func injectCommands(plist: String) -> String {
        let pb = plistBuddy
        var inject = """
        \(pb) -c "Delete :LSSupportsGameMode" -c "Add :LSSupportsGameMode bool true" \
        -c "Delete :GCSupportsGameMode" -c "Add :GCSupportsGameMode bool true" \(quoted(plist)) 2>/dev/null || true
        """
        let cat = run(plistBuddy, ["-c", "Print :LSApplicationCategoryType", plist])
        let curCat = cat.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if cat.status != 0 || curCat.isEmpty {
            inject += "\n\(pb) -c \"Add :LSApplicationCategoryType string public.app-category.games\" \(quoted(plist)) 2>/dev/null || true"
        } else if !curCat.lowercased().contains("game") {
            inject += "\n\(pb) -c \"Delete :LSApplicationCategoryType\" -c \"Add :LSApplicationCategoryType string public.app-category.games\" \(quoted(plist)) 2>/dev/null || true"
        }
        return inject
    }

    /// 组装补丁脚本。
    ///
    /// 关键点：对**正在运行**的 App，codesign 无法改写其内存中的二进制签名（Operation not
    /// permitted），必须走 Sparkle 式「副本替换」：把原包 rename 走（运行中进程仍持有 vnode），
    /// 复制一份副本 → 在副本上注入 + 重签 → 原子占回原路径。任何一步失败都回滚到原包。
    /// - Parameters:
    ///   - patch: 作用于 path 的修改命令（注入 / 从备份还原 / 删除注入键）
    ///   - verify: 脚本内的修改结果断言（失败视为整体失败并回滚）
    private func patchScript(path: String, running: Bool, entsFile: String?,
                             patch: String, verify: String, backupPlist: String?) -> String {
        let resign = resignCommand(path: path, entsFile: entsFile)
        if !running {
            // 原地修改：重签失败时从备份把 plist 还原回去，避免留下坏签名的半成品
            let rollback = backupPlist.map { "cp \(quoted($0)) \(quoted("\(path)/Contents/Info.plist")) 2>/dev/null || true;" } ?? ""
            return """
            \(patch)
            if ! ( \(resign) ); then \(rollback) exit 4; fi
            \(verify) || { \(rollback) exit 5; }
            """
        }
        // 副本替换
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let stem = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let old = "\(parent)/\(stem).gmhelper-old-\(Int.random(in: 1000...9999)).app"
        return """
        OLD=\(quoted(old))
        mv \(quoted(path)) "$OLD" || exit 9
        if ! cp -R "$OLD" \(quoted(path)); then mv "$OLD" \(quoted(path)); exit 9; fi
        \(patch)
        if ! ( \(resign) ); then rm -rf \(quoted(path)) 2>/dev/null; mv "$OLD" \(quoted(path)); exit 4; fi
        \(verify) || { rm -rf \(quoted(path)) 2>/dev/null; mv "$OLD" \(quoted(path)); exit 5; }
        rm -rf "$OLD" 2>/dev/null || true
        """
    }

    /// 为 App 开启游戏模式支持（注入声明 + ad-hoc 重签 + 用户身份刷新 LaunchServices）
    func enableGameMode(path: String, completion: @escaping (PatchOutcome) -> Void) {
        patchQueue.async { [weak self] in
            guard let self else { return }
            guard fm_fileExists(self.fm, path) else {
                completion(.failed("找不到 App：\(path)")); return
            }
            let plist = "\(path)/Contents/Info.plist"
            guard self.fm.fileExists(atPath: plist) else {
                completion(.failed("找不到 Info.plist：\(plist)")); return
            }
            // 0. 只读系统卷（SIP）：连 root 都写不了，直接说清楚，不弹密码框
            if self.isReadOnlyVolume(path) {
                self.log("拒绝修改（只读系统卷）：\(path)")
                completion(.failed("该 App 位于只读系统卷（系统 SIP 保护），无法修改")); return
            }
            // 1. 备份（只备份一次，不覆盖既有备份）
            let bid = self.bundleIDOfApp(at: path) ?? ""
            let backupPlist = self.backupDir.appendingPathComponent(bid)
                .appendingPathComponent("Info.plist.orig").path
            if !bid.isEmpty, !self.fm.fileExists(atPath: backupPlist) {
                try? self.fm.createDirectory(at: self.backupDir.appendingPathComponent(bid),
                                             withIntermediateDirectories: true)
                try? self.fm.copyItem(atPath: plist, toPath: backupPlist)
                self.log("已备份 \(bid) 的 Info.plist")
            }
            let hasBackup = self.fm.fileExists(atPath: backupPlist)
            // 2. 重签前提取可保留的 entitlements（原签名仍完好时提取）
            let entsFile = self.preparePreservedEntitlements(path: path)
            defer { if let entsFile { try? self.fm.removeItem(atPath: entsFile) } }
            let running = self.isAppRunning(bundleID: bid)
            let script = self.patchScript(path: path, running: running, entsFile: entsFile,
                                          patch: self.injectCommands(plist: plist),
                                          verify: "\(self.plistBuddy) -c 'Print :LSSupportsGameMode' \(quoted(plist)) >/dev/null 2>&1",
                                          backupPlist: hasBackup ? backupPlist : nil)
            // 3. 执行：用户域直跑；root 属主走管理员授权（密码框，osascript 子进程）
            let userWritable = self.canWriteBundle(path)
            self.log("补丁方式：\(running ? "运行中·副本替换" : "原地修改")（真实写入探针=\(userWritable)）：\(path)")
            if userWritable {
                let r = self.run("/bin/sh", ["-c", script])
                if r.status != 0 {
                    self.log("开启脚本失败(\(r.status))：\(path)")
                    completion(.failed(r.status == 9 ? "无法复制 App 副本（权限不足）" : "执行失败：请查看日志"))
                    return
                }
            } else {
                switch PrivilegedRunner.shared.run(script) {
                case .success:
                    self.log("管理员补丁完成（会话内授权复用）")
                case .canceled:
                    self.log("管理员授权被取消：\(path)")
                    completion(.failed("已取消管理员授权")); return
                case .failed(let message):
                    self.log("管理员授权执行失败：\(message)")
                    completion(.failed("管理员操作失败：\(message)")); return
                }
            }
            // 4. lsregister 一律以当前用户身份执行——root 跑的 lsregister 写的是 root 的注册库，无效
            _ = self.run(self.lsregister, ["-f", "-R", path])
            // 5. 验证：键注入成功 + 签名有效
            if self.supportState(at: path) != .supported {
                self.log("开启验证失败（未检测到声明）：\(path)")
                completion(.failed("注入后未检测到游戏模式声明")); return
            }
            let sign = self.run(self.codesign, ["-v", path])
            if sign.status != 0 {
                self.log("开启验证失败（签名无效）：\(path)")
                completion(.failed("重签后签名验证失败")); return
            }
            self.log("已为 \(path) 开启游戏模式支持（\(running ? "运行中·副本替换" : "原地修改")）")
            completion(.success("已开启游戏模式支持"))
        }
    }

    /// 还原 App 的原始 Info.plist（从备份恢复），再重签 + 用户身份刷新 LaunchServices
    func disableGameMode(path: String, completion: @escaping (PatchOutcome) -> Void) {
        patchQueue.async { [weak self] in
            guard let self else { return }
            guard let bid = self.bundleIDOfApp(at: path) else {
                completion(.failed("读取不到 bundleID")); return
            }
            // 只读系统卷：本工具从未成功修改过它，无需还原，也不弹密码框
            if self.isReadOnlyVolume(path) {
                if self.supportState(at: path) == .unsupported {
                    completion(.success("无需还原：该 App 在只读系统卷上且未被修改")); return
                }
                completion(.failed("该 App 位于只读系统卷，无法修改")); return
            }
            let plist = "\(path)/Contents/Info.plist"
            let backupPlist = self.backupDir.appendingPathComponent(bid)
                .appendingPathComponent("Info.plist.orig").path
            let hasBackup = self.fm.fileExists(atPath: backupPlist)
            // 重签前提取可保留的 entitlements（当前签名仍完好时提取）
            let entsFile = self.preparePreservedEntitlements(path: path)
            defer { if let entsFile { try? self.fm.removeItem(atPath: entsFile) } }
            let running = self.isAppRunning(bundleID: bid)

            let patch: String
            let verify: String
            if hasBackup {
                patch = "cp \(quoted(backupPlist)) \(quoted(plist))"
                verify = "cmp -s \(quoted(backupPlist)) \(quoted(plist))"
            } else {
                // 没有备份：直接删掉注入的键
                patch = "\(self.plistBuddy) -c \"Delete :LSSupportsGameMode\" -c \"Delete :GCSupportsGameMode\" \(quoted(plist)) 2>/dev/null || true"
                verify = "if \(self.plistBuddy) -c 'Print :LSSupportsGameMode' \(quoted(plist)) >/dev/null 2>&1; then exit 6; fi"
            }
            let script = self.patchScript(path: path, running: running, entsFile: entsFile,
                                          patch: patch, verify: verify,
                                          backupPlist: hasBackup ? backupPlist : nil)
            let userWritable = self.canWriteBundle(path)
            self.log("补丁方式：\(running ? "运行中·副本替换" : "原地修改")（真实写入探针=\(userWritable)）：\(path)")
            if userWritable {
                let r = self.run("/bin/sh", ["-c", script])
                if r.status != 0 {
                    self.log("还原脚本失败(\(r.status))：\(path)")
                    completion(.failed(r.status == 9 ? "无法复制 App 副本（权限不足）" : "还原失败：请查看日志"))
                    return
                }
            } else {
                switch PrivilegedRunner.shared.run(script) {
                case .success:
                    self.log("管理员补丁完成（会话内授权复用）")
                case .canceled:
                    self.log("管理员授权被取消：\(path)")
                    completion(.failed("已取消管理员授权")); return
                case .failed(let message):
                    self.log("管理员授权执行失败：\(message)")
                    completion(.failed("管理员操作失败：\(message)")); return
                }
            }
            _ = self.run(self.lsregister, ["-f", "-R", path])
            let sign = self.run(self.codesign, ["-v", path])
            if sign.status != 0 {
                self.log("还原验证失败（签名无效）：\(path)")
                completion(.failed("还原后签名验证失败")); return
            }
            if hasBackup {
                self.log("已还原 \(bid)（从备份恢复）")
                completion(.success("已还原到原始状态"))
            } else {
                self.log("已还原 \(bid)（无备份，直接删除注入键）")
                completion(.success("已还原（无备份，删除了注入的键）"))
            }
        }
    }

    /// 预先获取管理员授权（面板「管理员授权」按钮）。成功后本会话内所有特权操作免密。
    func preAuthorize(completion: @escaping (String?) -> Void) {
        patchQueue.async { [weak self] in
            let err = PrivilegedRunner.shared.preAuthorize()
            if err == nil { self?.log("管理员授权成功（本会话后续操作免密）") }
            completion(err)
        }
    }

    // MARK: - 重启 App（仅用户明确点击后）

    /// 重启指定 App：先记录运行状态，退出后重新启动。
    /// 仅在用户明确确认后调用。
    func restartApp(path: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let wasRunning = self.isAppRunning(bundleID: self.bundleIDOfApp(at: path) ?? "")
            if !wasRunning {
                // 没在运行：直接启动
                self.run("/usr/bin/open", ["-a", path])
                completion(true)
                return
            }
            // 优雅退出
            if let bid = self.bundleIDOfApp(at: path) {
                _ = self.run("/usr/bin/osascript", ["-e", "tell application id \"\(bid)\" to quit"])
                // 等待退出（最多 8 秒）
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline, self.isAppRunning(bundleID: bid) {
                    self.sleepWithRunLoop(0.2)
                }
                if self.isAppRunning(bundleID: bid) {
                    // AppleScript 退出失败：用户已明确确认重启，改发 SIGTERM（正常终止信号，App 可收尾）
                    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bid }
                    for a in apps { kill(a.processIdentifier, SIGTERM) }
                    self.log("AppleScript 退出无效，已改发 SIGTERM：\(bid)")
                    let deadline2 = Date().addingTimeInterval(5)
                    while Date() < deadline2, self.isAppRunning(bundleID: bid) {
                        self.sleepWithRunLoop(0.2)
                    }
                    if self.isAppRunning(bundleID: bid) {
                        completion(false)   // 仍没退成，不启动（避免双开）
                        return
                    }
                }
            }
            self.sleepWithRunLoop(1)
            self.run("/usr/bin/open", ["-a", path])
            completion(true)
        }
    }

    // MARK: - 内置自检

    /// 自检：用测试假 App 验证 开启→生效→还原 全流程，不碰任何真实 App。
    func runSelfTest(dummyPath: String? = nil) -> [CheckResult] {
        var results: [CheckResult] = []
        func add(_ name: String, _ ok: Bool, _ detail: String, info: Bool = false) {
            let status: CheckResult.Status = info ? .info : (ok ? .pass : .fail)
            results.append(CheckResult(name: name, status: status, detail: detail))
        }

        // 1. 依赖工具检查
        add("PlistBuddy 可用", fm.fileExists(atPath: plistBuddy), plistBuddy)
        add("plutil 可用", fm.fileExists(atPath: plutil), plutil)
        add("codesign 可用", fm.fileExists(atPath: codesign), codesign)
        add("lsregister 可用", fm.fileExists(atPath: lsregister), "LaunchServices 注册工具在位")

        // 2. 假 App 往返
        guard let path = dummyPath else {
            add("假 App 往返测试", true, "未提供 --dummy 路径，跳过（外层 selftest.sh 会提供）", info: true)
            return results
        }
        let bid = bundleIDOfApp(at: path) ?? ""
        if bid.isEmpty {
            add("假 App", false, "无法读取 \(path) 的 bundleID")
            return results
        }

        // 2pre. 给假 App 预埋一个 com.apple.security.* entitlement，
        //       用于验证重签会保留 security entitlements（沙盒 App 不丢容器/存档）
        let testEntsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gmhelper-test-ents.plist")
        let testEntsXML = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
        """
        if let data = testEntsXML.data(using: .utf8) {
            try? data.write(to: testEntsURL)
            _ = run(codesign, ["--force", "--sign", "-", "--entitlements", testEntsURL.path, path])
        }

        // 2a. 开启前状态应为未开启
        let before = supportState(at: path)
        add("开启前状态", before == .unsupported, "注入前为「未开启」")

        // 2b. 开启（用户域路径可直接执行；/tmp 属于用户域）
        var enableOK = false
        let sem = DispatchSemaphore(value: 0)
        enableGameMode(path: path) { outcome in
            switch outcome {
            case .success: enableOK = true
            case .needsAdmin: enableOK = false
            case .failed: enableOK = false
            }
            sem.signal()
        }
        // 等待时保持运行循环转动（AppleScript/子进程需要）
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        let afterEnable = supportState(at: path)
        add("开启游戏模式支持", enableOK && afterEnable == .supported,
            "注入 LSSupportsGameMode/GCSupportsGameMode 并刷新注册（当前：\(afterEnable.rawValue)）")

        // 2c. 签名仍有效
        let sign = run(codesign, ["-v", path])
        add("代码签名有效", sign.status == 0, "ad-hoc 重签后 App 可正常启动")

        // 2c-2. 重签应保留 com.apple.security.* entitlements
        let entsOut = run(codesign, ["-d", "--entitlements", ":-", path])
        add("重签保留 security entitlements",
            entsOut.status == 0 && entsOut.output.contains("get-task-allow"),
            "重签只保留 com.apple.security.* 键（沙盒 App 存档/设置不丢）")

        // 2d. 备份已创建
        let backupFile = backupDir.appendingPathComponent(bid).appendingPathComponent("Info.plist.orig")
        add("原始 Info.plist 已备份", fm.fileExists(atPath: backupFile.path), backupFile.path)

        // 2e. 假 App 仍能启动（不退出任何进程，只验证二进制可执行）
        let launchOK = run("/usr/bin/open", ["-a", path])
        var running = false
        for _ in 0..<20 {
            if isAppRunning(bundleID: bid) { running = true; break }
            sleepWithRunLoop(0.25)
        }
        add("假 App 改动后可正常启动", launchOK.status == 0 && running, "重启后进程正常运行")

        // 2e-2. 退出假 App（自检自建的测试实例）：退出后还原走用户态路径，自检全程无需密码
        //（运行中 App 的 bundle 在用户态不可写——这正是需要管理员路径的真实原因）
        if running {
            _ = run("/usr/bin/osascript", ["-e", "tell application id \"\(bid)\" to quit"])
            let qDeadline = Date().addingTimeInterval(8)
            while Date() < qDeadline, isAppRunning(bundleID: bid) { sleepWithRunLoop(0.2) }
        }
        add("假 App 可正常优雅退出", !isAppRunning(bundleID: bid), "自检实例测试完毕后退出")

        // 2f. 还原
        var disableOK = false
        let sem2 = DispatchSemaphore(value: 0)
        disableGameMode(path: path) { outcome in
            switch outcome {
            case .success: disableOK = true
            case .needsAdmin: disableOK = false
            case .failed: disableOK = false
            }
            sem2.signal()
        }
        while sem2.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        let afterDisable = supportState(at: path)
        add("还原到原始状态", disableOK && afterDisable == .unsupported,
            "恢复备份的 Info.plist 并重签（当前：\(afterDisable.rawValue)）")

        // 2g. 还原后仍可启动
        let launchOK2 = run("/usr/bin/open", ["-a", path])
        var running2 = false
        for _ in 0..<20 {
            if isAppRunning(bundleID: bid) { running2 = true; break }
            sleepWithRunLoop(0.25)
        }
        add("还原后假 App 可正常启动", launchOK2.status == 0 && running2, "还原不影响 App 启动")

        // 3. 游戏模式启动器生成器（结构检查，不执行目标程序）
        do {
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("gmstub-selftest-\(Int.random(in: 100_000...999_999))", isDirectory: true)
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let sem3 = DispatchSemaphore(value: 0)
            var genPath: String?
            var genError = ""
            StubGenerator.generate(.init(name: "GM自检替身", program: "/usr/bin/true", args: [], cwd: nil,
                                         passthrough: false, destination: tempDir)) { r in
                switch r {
                case .success(let u): genPath = u
                case .failure(let m): genError = m
                }
                sem3.signal()
            }
            while sem3.wait(timeout: .now() + 0.1) == .timedOut {
                sleepWithRunLoop(0.02)
            }
            var stubOK = false, keysOK = false
            if let genPath {
                let appURL = URL(fileURLWithPath: genPath)
                stubOK = fm.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS/GameStubRunner").path)
                    && fm.fileExists(atPath: appURL.appendingPathComponent("Contents/config.json").path)
                let pbOut = run(plistBuddy, [
                    "-c", "Print :LSSupportsGameMode", "-c", "Print :GCSupportsGameMode",
                    "-c", "Print :LSApplicationCategoryType",
                    appURL.appendingPathComponent("Contents/Info.plist").path])
                keysOK = pbOut.status == 0 && pbOut.output.contains("true")
                    && pbOut.output.contains("public.app-category.games")
            }
            add("游戏模式启动器生成", stubOK, stubOK ? "替身 App 结构完整（运行器 + 配置）" : "失败原因：\(genError)")
            add("启动器游戏声明齐全", keysOK, "Info.plist 含双声明键与游戏分类")
            try? fm.removeItem(at: tempDir)
        }

        log("自检完成：\(results.filter { $0.status == .pass }.count) 通过 / \(results.filter { $0.status == .fail }.count) 失败")
        return results
    }

    // MARK: - 工具

    /// 提取当前签名中可安全保留的 entitlements，写入临时文件并返回路径。
    ///
    /// 只保留 `com.apple.security.*`（沙盒等——丢掉它们会让沙盒 App 丢容器/存档）。
    /// 其余键（`com.apple.application-identifier`、`com.apple.developer.*`、`com.apple.private.*`）
    /// 不能出现在 ad-hoc 签名里：实测 codesign 能嵌进去，但 launchd 会拒绝启动（POSIX 163）。
    /// 提取失败或无可用键时返回 nil（调用方回退为纯 ad-hoc 重签）。
    private func preparePreservedEntitlements(path: String) -> String? {
        // :- 把 XML 格式的 entitlements 写到 stdout（:文件 的写法已废弃且写不出内容）
        let r = run(codesign, ["-d", "--entitlements", ":-", path])
        guard r.status == 0,
              let data = r.output.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let kept = dict.filter { $0.key.hasPrefix("com.apple.security.") }
        guard !kept.isEmpty else { return nil }
        guard let xml = try? PropertyListSerialization.data(
            fromPropertyList: kept, format: .xml, options: 0) else { return nil }
        let bid = (bundleIDOfApp(at: path) ?? "app")
            .replacingOccurrences(of: "/", with: "_")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.gamemodehelper.ents.\(bid).plist")
        do { try xml.write(to: tmp) } catch { return nil }
        return tmp.path
    }

    /// 组装重签命令：有可保留的 entitlements 就带上。注意：失败必须向外传播（调用方包括号判定），
    /// 因此这里绝不能有 `|| true` 之类的吞错尾巴。
    private func resignCommand(path: String, entsFile: String?) -> String {
        guard let entsFile else { return "\(codesign) --force --sign - \(quoted(path)) 2>&1" }
        return "\(codesign) --force --sign - --entitlements \(quoted(entsFile)) \(quoted(path)) 2>/dev/null || \(codesign) --force --sign - \(quoted(path)) 2>&1"
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func sleepWithRunLoop(_ interval: TimeInterval) {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: interval))
    }

    /// sh 单引号安全包裹
    private func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 文件存在性辅助（供后台线程安全调用）
private func fm_fileExists(_ fm: FileManager, _ path: String) -> Bool {
    fm.fileExists(atPath: path)
}
