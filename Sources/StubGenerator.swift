import AppKit

/// 「游戏模式启动器」生成器：为没有 App 包的程序（Java/jar、裸可执行程序、脚本）
/// 生成一个带游戏模式声明的替身 .app。双击替身 = 以游戏身份启动目标程序。
enum StubGenerator {

    /// 替身运行时配置（与 Resources/GameStubRunner 读取的 config.json 同构）
    struct StubConfig: Codable {
        var program: String?
        var args: [String] = []
        var cwd: String?
        var passthrough: Bool = false
        var wrapper: Bool = false
    }

    enum StubResult {
        case success(String)
        case failure(String)
    }

    struct Spec {
        let name: String        // 替身 App 显示名
        let program: String     // 真实程序（可执行文件 / java 路径）
        let args: [String]      // 启动参数
        let cwd: String?        // 工作目录（可为空）
        let passthrough: Bool   // 透传模式：启动器把本程序当"自定义 Java/包装命令"调用时，参数原样转交
        var wrapper: Bool = false // 包装模式：HMCL 的 wrapper 字段调用（<运行器> <程序> <参数…>）
        let destination: URL?   // 目标目录；nil = ~/Applications
    }

    /// 生成替身 App，成功返回其路径。
    static func generate(_ spec: Spec, completion: @escaping (StubResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default

            // 0. runner 二进制随主 App 分发（自检用裸二进制时在同目录查找）
            let exeDir = (CommandLine.arguments.first.flatMap { NSString(string: $0).deletingLastPathComponent }) ?? "."
            let candidates: [String?] = [
                Bundle.main.resourceURL?.appendingPathComponent("GameStubRunner").path,
                Bundle.main.bundlePath + "/Contents/Resources/GameStubRunner",
                (exeDir as NSString).appendingPathComponent("GameStubRunner"),
                (exeDir as NSString).appendingPathComponent("../Resources/GameStubRunner"),
            ]
            guard let runner = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0) }) else {
                completion(.failure("找不到 GameStubRunner（安装不完整，请重新安装本工具）"))
                return
            }

            // 1. 临时目录组装 bundle（完成后整体搬入目标目录）
            let tmpRoot = fm.temporaryDirectory
                .appendingPathComponent("gmstub-\(Int.random(in: 100_000...999_999))", isDirectory: true)
            let tmpApp = tmpRoot.appendingPathComponent("\(spec.name).app", isDirectory: true)
            do {
                try fm.createDirectory(at: tmpApp.appendingPathComponent("Contents/MacOS", isDirectory: true),
                                       withIntermediateDirectories: true)
            } catch {
                completion(.failure("无法创建临时目录：\(error.localizedDescription)"))
                return
            }

            // 2. Info.plist：游戏模式声明在生成时就写入，无需再打补丁
            let bundleID = "com.gamemodehelper.stub.\(sanitized(spec.name))"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>\(bundleID)</string>
              <key>CFBundleName</key><string>\(xmlEscape(spec.name))</string>
              <key>CFBundleDisplayName</key><string>\(xmlEscape(spec.name))</string>
              <key>CFBundleExecutable</key><string>GameStubRunner</string>
              <key>CFBundlePackageType</key><string>APPL</string>
              <key>CFBundleShortVersionString</key><string>1.0</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>NSPrincipalClass</key><string>NSApplication</string>
              <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
              <key>LSSupportsGameMode</key><true/>
              <key>GCSupportsGameMode</key><true/>
            </dict></plist>
            """
            do {
                try plist.write(to: tmpApp.appendingPathComponent("Contents/Info.plist"),
                                atomically: true, encoding: .utf8)
            } catch {
                completion(.failure("无法写入 Info.plist：\(error.localizedDescription)"))
                return
            }

            // 3. config.json（替身运行时读取）
            let config = StubConfig(program: spec.program, args: spec.args,
                                    cwd: spec.cwd, passthrough: spec.passthrough,
                                    wrapper: spec.wrapper)
            do {
                let data = try JSONEncoder().encode(config)
                try data.write(to: tmpApp.appendingPathComponent("Contents/config.json"))
            } catch {
                completion(.failure("无法写入 config.json：\(error.localizedDescription)"))
                return
            }

            // 4. 拷入 runner
            do {
                try fm.copyItem(atPath: runner,
                                toPath: tmpApp.appendingPathComponent("Contents/MacOS/GameStubRunner").path)
            } catch {
                completion(.failure("无法拷入运行器：\(error.localizedDescription)"))
                return
            }

            // 5. 清 provenance 等扩展属性（否则 codesign 报"子组件未签名"）+ ad-hoc 签名
            _ = runHelper("/usr/bin/xattr", ["-rc", tmpApp.path])
            let sign = Process()
            sign.launchPath = "/usr/bin/codesign"
            sign.arguments = ["--force", "--deep", "--sign", "-", tmpApp.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            do { try sign.run(); sign.waitUntilExit() } catch {
                completion(.failure("签名失败：\(error.localizedDescription)"))
                return
            }
            guard sign.terminationStatus == 0 else {
                completion(.failure("签名失败（退出码 \(sign.terminationStatus)）"))
                return
            }

            // 6. 搬入目标目录（重名自动加序号）
            let appsDir = spec.destination ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            try? fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
            var finalURL = appsDir.appendingPathComponent("\(spec.name).app", isDirectory: true)
            var idx = 2
            while fm.fileExists(atPath: finalURL.path) {
                finalURL = appsDir.appendingPathComponent("\(spec.name) \(idx).app", isDirectory: true)
                idx += 1
            }
            do {
                try fm.moveItem(at: tmpApp, to: finalURL)
                try? fm.removeItem(at: tmpRoot)
            } catch {
                // 直接搬入被拒（权限/TCC）：回退到管理员授权完成最后一步
                let mv = "mkdir -p \(quote(appsDir.path)) && cp -R \(quote(tmpApp.path)) \(quote(finalURL.path)) && rm -rf \(quote(tmpApp.path)) \(quote(tmpRoot.path))"
                var adminFailed: String?
                DispatchQueue.main.sync {
                    switch PrivilegedRunner.shared.run(mv) {
                    case .success: adminFailed = nil
                    case .canceled: adminFailed = "已取消授权"
                    case .failed(let m): adminFailed = m
                    }
                }
                if let adminFailed {
                    completion(.failure("无法写入目标目录：\(adminFailed)"))
                    return
                }
            }

            // 7. 刷新 LaunchServices
            let lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            _ = runHelper(lsreg, ["-f", "-R", finalURL.path])

            completion(.success(finalURL.path))
        }
    }

    // MARK: - 工具

    /// 解析可用的 java（GUI 进程 PATH 受限，优先常见路径，再查登录 shell 的 PATH）
    static func whichJava() -> String? {
        let fm = FileManager.default
        for c in ["/usr/bin/java", "/opt/homebrew/opt/openjdk/bin/java", "/opt/homebrew/bin/java"] {
            if fm.isExecutableFile(atPath: c) { return c }
        }
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-lc", "which java"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func sanitized(_ name: String) -> String {
        let ok = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        let s = String(ok)
        return s.isEmpty ? "app" : s
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func runHelper(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
