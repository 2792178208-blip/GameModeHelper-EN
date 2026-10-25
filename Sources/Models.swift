import Cocoa

/// 一个可参与游戏模式的 App
struct AppEntry: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let path: String
    let isRunning: Bool
    /// 当前是否为前台（frontmost）App——用户正在用的那个，通常是游戏
    var isFrontmost: Bool = false
    /// 位于只读系统卷（SIP 保护，无法修改，如 Safari）
    var isSystemVolume: Bool = false
    /// 裸程序：无 App 包直接运行的进程（java、jar 启动的 Minecraft 等）
    var isBareProcess: Bool = false
    /// 游戏模式声明状态
    var supportState: SupportState = .unknown

    var id: String { bundleID }

    enum SupportState: String {
        case unsupported = "未开启"
        case supported = "已支持"
        case unknown = "未知"
    }
}

/// 对某个 App 执行开启/还原的结果
enum PatchOutcome: CustomStringConvertible {
    case success(String)
    case needsAdmin(String)      // 携带待执行的管理员命令（调用方负责弹授权）
    case failed(String)

    var description: String {
        switch self {
        case .success(let m): return "OK \(m)"
        case .needsAdmin(let m): return "NEED-ADMIN \(m)"
        case .failed(let m): return "失败：\(m)"
        }
    }
}

/// 自检单项结果
struct CheckResult {
    enum Status { case pass, fail, info }
    let name: String
    let status: Status
    let detail: String
}
