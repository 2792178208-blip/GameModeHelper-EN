import AppKit

/// 游戏模式启动器（替身 App）的主程序。
///
/// 原理（GameStub 模式，参考 CeciliaStudio/MinecraftGameStub）：
/// 替身 App 自带游戏模式声明；本程序以 App 身份启动后被系统识别为游戏，
/// 随后把进程镜像替换（execv）为真正的游戏程序——PID 不变，游戏天生继承
/// 本 bundle 的游戏身份。适用于 Java/jar、裸可执行程序等没有 App 包的程序。
///
/// 配置文件：本 bundle 的 Contents/config.json
///   {"program": "…", "args": ["…"], "cwd": "…", "passthrough": false}
/// passthrough=true 时忽略 args，把启动本程序时收到的参数原样透传（HMCL 等
/// 启动器以"自定义 Java 路径"方式调用本程序的场景，实验性）。

/// 注册期保存的真实 stderr（恢复用）
var savedStderr: Int32 = -1

struct StubConfig: Codable {
    var program: String?
    var args: [String] = []
    var cwd: String?
    var passthrough: Bool = false
    var wrapper: Bool = false

    // 手写解码：所有键均可缺省（wrapper 模式的 config 只有一行 {"wrapper": true}）
    init(program: String? = nil, args: [String] = [], cwd: String? = nil,
         passthrough: Bool = false, wrapper: Bool = false) {
        self.program = program; self.args = args; self.cwd = cwd
        self.passthrough = passthrough; self.wrapper = wrapper
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        program = try c.decodeIfPresent(String.self, forKey: .program)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        passthrough = try c.decodeIfPresent(Bool.self, forKey: .passthrough) ?? false
        wrapper = try c.decodeIfPresent(Bool.self, forKey: .wrapper) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case program, args, cwd, passthrough, wrapper
    }
}

final class StubDelegate: NSObject, NSApplicationDelegate {
    let cfg: StubConfig
    init(cfg: StubConfig) { self.cfg = cfg; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let cwd = cfg.cwd, !cwd.isEmpty {
            _ = FileManager.default.changeCurrentDirectoryPath(cwd)
        }
        // 给 LaunchServices/游戏策略一点注册时间，再把进程镜像替换为游戏本体
        //（透传模式下启动器探测 Java 也会经过这里，0.5s 对探测无感知）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in execProgram() }
    }

    private func execProgram() {
        // 恢复真实 stderr 再 exec，让启动器/终端能看到游戏输出
        if savedStderr != -1 { dup2(savedStderr, STDERR_FILENO); close(savedStderr) }

        // 包装模式（HMCL 等启动器的 wrapper 字段）：启动器以
        //   <本运行器> <真实程序> <程序参数…>
        // 方式调用；本进程以游戏身份注册后，把镜像替换为 argv[1]，
        // 游戏进程 PID 不变，天生继承游戏身份。
        if cfg.wrapper {
            let a = CommandLine.arguments
            guard a.count >= 2 else {
                fputs("GameStubRunner: 包装模式需要至少一个参数（要启动的程序）\n", stderr)
                exit(1)
            }
            let prog = a[1]
            // 诊断日志：记录包装调用（供排查 HMCL 接入）
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let logDir = home + "/Library/Logs/GameModeHelper"
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            let logLine = "[\(String(format: "%.2f", Date().timeIntervalSince1970))] wrapper exec → \(prog)\n"
            let logFile = logDir + "/wrapper.log"
            if !FileManager.default.fileExists(atPath: logFile) {
                FileManager.default.createFile(atPath: logFile, contents: nil)
            }
            if let h = FileHandle(forWritingAtPath: logFile) {
                h.seekToEndOfFile(); let _ = try? h.write(logLine.data(using: .utf8)!); try? h.close()
            }
            var wargv: [UnsafeMutablePointer<CChar>?] = [strdup(prog)]
            for arg in a.dropFirst(2) { wargv.append(strdup(arg)) }
            wargv.append(nil)
            execv(prog, &wargv)
            fputs("GameStubRunner: 包装启动 \(prog) 失败（errno=\(errno)）\n", stderr)
            exit(127)
        }

        let program = cfg.program ?? ""
        let argList: [String]
        if cfg.passthrough {
            // 透传模式：argv[0] 起就是目标程序需要的参数（java -Xmx… 等）
            argList = Array(CommandLine.arguments.dropFirst())
        } else {
            argList = cfg.args
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(program)]
        for a in argList { argv.append(strdup(a)) }
        argv.append(nil)

        execv(program, &argv)
        // 只有 exec 失败才会走到这里
        let reason = errno == ENOENT ? "程序不存在" : errno == EACCES ? "没有执行权限" : "errno=\(errno)"
        fputs("GameStubRunner: 无法启动 \(program)（\(reason)）。\n"
              + "透传模式请检查 config.json 里 program 指向的 Java 是否有效。\n", stderr)
        exit(127)
    }
}

// 入口
let cfgResult: Result<StubConfig, Error>
do {
    let cfgURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        .appendingPathComponent("Contents/config.json")
    let data = try Data(contentsOf: cfgURL)
    cfgResult = .success(try JSONDecoder().decode(StubConfig.self, from: data))
} catch {
    cfgResult = .failure(error)
}

switch cfgResult {
case .failure(let err):
    fputs("GameStubRunner: 读取 config.json 失败——\(err)\n", stderr)
    exit(1)
case .success(let cfg):
    // 注册期静音 stderr：直接拉起（不经 LaunchServices）时 AppKit 会输出
    // "sandbox_extension_issue_file_to_process" 噪音，会污染启动器的 Java 版本解析。
    // execv 前在 execProgram 里恢复，真实程序的输出不受影响。
    savedStderr = dup(STDERR_FILENO)
    let devnull = open("/dev/null", O_WRONLY)
    if devnull != -1 { dup2(devnull, STDERR_FILENO); close(devnull) }

    let app = NSApplication.shared
    let delegate = StubDelegate(cfg: cfg)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
