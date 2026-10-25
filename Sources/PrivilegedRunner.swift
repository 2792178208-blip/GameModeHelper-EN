import Foundation
import Security

/// 管理员授权执行器：**同一会话只输一次密码**。
///
/// 原理：Security 框架的 AuthorizationCreate 拿到授权（首次弹系统密码框，可取消），
/// AuthorizationRef 缓存在 App 进程内；之后所有特权操作走
/// AuthorizationExecuteWithPrivileges，直接复用该授权，不再弹框。
/// 该 C API 在 Swift overlay 里标记为不可用，但符号仍在 libSecurity 中——运行时 dlsym 绑定；
/// 若未来符号被移除，自动回退到 osascript（每次都可能要密码，行为同旧版）。
/// App 退出后授权随之失效，下次启动的第一次特权操作会再要一次密码。
///
/// 线程约定：仅在 HelperCore 的串行 patchQueue 上调用。
final class PrivilegedRunner {
    static let shared = PrivilegedRunner()
    private var authRef: AuthorizationRef?
    private var execFn: AEPFn?
    private init() {}

    enum RunOutcome: Equatable {
        case success(output: String)
        case canceled
        case failed(message: String)
    }

    /// C: OSStatus AuthorizationExecuteWithPrivileges(AuthorizationRef, const char *toolPath,
    ///        AuthorizationFlags options, char *const arguments[], FILE **communicationsPipe)
    private typealias AEPFn = @convention(c) (
        OpaquePointer?,                                // authorization
        UnsafePointer<CChar>,                          // toolPath
        UInt32,                                        // options
        UnsafeRawPointer?,                             // char *const arguments[]（NULL 结尾）
        UnsafeMutableRawPointer?                       // FILE **communicationsPipe
    ) -> Int32

    /// 是否已持有本会话的管理员授权
    var hasAuthorization: Bool { authRef != nil }

    /// 预先获取授权（供面板「管理员授权」按钮调用）。
    /// 返回 nil 表示授权成功；返回字符串为取消/失败原因。
    func preAuthorize() -> String? {
        if authRef != nil { return nil }
        return obtain()
    }

    /// 拿（或复用）授权。失败/取消返回原因。
    private func obtain() -> String? {
        if let authRef { return nil }
        var ref: AuthorizationRef?
        let flags = AuthorizationFlags([.preAuthorize, .extendRights, .interactionAllowed])
        let status = AuthorizationCreate(nil, nil, flags, &ref)
        guard status == errAuthorizationSuccess, let ref else {
            if status == errAuthorizationCanceled { return "已取消授权" }
            return "授权失败（\(status)）"
        }
        authRef = ref
        return nil
    }

    /// 运行时绑定 AuthorizationExecuteWithPrivileges（Swift overlay 标记不可用但符号存在）
    private func boundExecFn() -> AEPFn? {
        if let execFn { return execFn }
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        execFn = unsafeBitCast(sym, to: AEPFn.self)
        return execFn
    }

    /// 以 root 执行 shell 脚本。脚本写入临时文件（避免转义地狱），
    /// 外包一层子 shell 后用哨兵带回真实退出码（该 API 不返回退出码）。
    func run(_ script: String) -> RunOutcome {
        if let err = obtain() { return .canceled }
        guard let auth = authRef else { return .failed(message: "无授权") }
        guard let exec = boundExecFn() else {
            // 符号不存在（未来 macOS 移除）：回退 osascript——功能等价，但每次都可能要密码
            return runViaOSAScript(script)
        }

        let fm = FileManager.default
        let scriptURL = fm.temporaryDirectory
            .appendingPathComponent("gmhelper-priv-\(Int.random(in: 100_000...999_999)).sh")
        let wrapped = "(\n" + script + "\n); echo __GM_EXIT_$?__\n"
        guard (try? wrapped.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else {
            return .failed(message: "无法写入临时脚本")
        }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)
        defer { try? fm.removeItem(atPath: scriptURL.path) }

        // C 语义的 NULL 结尾参数数组：/bin/sh <脚本路径>
        let buf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
        buf[0] = strdup(scriptURL.path)
        buf[1] = nil
        defer {
            if let p = buf[0] { free(p) }
            buf.deallocate()
        }
        var pipePtr: UnsafeMutablePointer<FILE>?
        let status = exec(auth, "/bin/sh", 0,
                          UnsafeRawPointer(buf), &pipePtr)
        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled {
                authRef = nil   // 会话授权可能已失效，下次重建
                return .canceled
            }
            authRef = nil
            return .failed(message: "授权执行失败（\(status)）")
        }

        var output = ""
        if let fptr = pipePtr {
            let fd = fileno(fptr)
            let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            output = String(data: fh.readDataToEndOfFile(), encoding: .utf8) ?? ""
            close(fd)
        }

        if let range = output.range(of: "__GM_EXIT_[0-9]+__", options: .regularExpression) {
            let token = String(output[range])
            let code = Int32(token.dropFirst("__GM_EXIT_".count).dropLast("__".count)) ?? -1
            let clean = output.replacingOccurrences(of: token, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return code == 0
                ? .success(output: clean)
                : .failed(message: clean.isEmpty ? "退出码 \(code)" : clean)
        }
        return .failed(message: output.isEmpty ? "执行中断（无输出）" : output)
    }

    /// 兜底：osascript 执行（每次都可能要密码）。返回 nil 表示成功。
    private func runViaOSAScript(_ script: String) -> RunOutcome {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch { return .failed(message: "无法启动 osascript：\(error)") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus == 1, msg.contains("User canceled") { return .canceled }
            return .failed(message: msg.isEmpty ? "osascript 退出码 \(task.terminationStatus)" : msg)
        }
        return .success(output: "")
    }
}
