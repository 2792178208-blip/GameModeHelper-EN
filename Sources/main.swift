import Cocoa

// 带 CLI 参数时进入无界面模式（供脚本/自测使用），否则以菜单栏 App 运行。
let cliFlags: Set<String> = ["--list", "--enable", "--disable", "--status",
                             "--restart", "--selftest", "--auth-test"]
let headless = !Set(CommandLine.arguments).intersection(cliFlags).isEmpty

let app = NSApplication.shared
let delegate = AppDelegate(headless: headless)
app.delegate = delegate
app.run()
