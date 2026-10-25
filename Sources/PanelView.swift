import SwiftUI
import Cocoa

/// 主面板
struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("游戏模式助手").font(.title3).bold()
                Spacer()
                if model.isBusy { ProgressView().scaleEffect(0.7).frame(width: 18) }
            }
            Text("为选定的 App 补上 macOS 游戏模式声明：全屏运行时自动获得 CPU/GPU 优先、后台降载与低延迟蓝牙。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // App 列表（只显示正在运行的；没在运行的用「选择 App…」手动挑）
            HStack {
                Text("正在运行的 App").font(.headline)
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .font(.caption)
                .disabled(model.isBusy)
                .help("重新检测正在运行和前台的 App")
                Button("选择 App…") { model.chooseApp() }.font(.caption)
            }
            List(selection: Binding(
                get: { model.selectedBundleID.isEmpty ? nil : model.selectedBundleID },
                set: { id in model.userPicked(id) })) {
                if model.apps.isEmpty {
                    Text("没有正在运行的 App。点「选择 App…」也可以挑选未运行的 App。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.apps) { app in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        if app.isFrontmost {
                            Text("前台").font(.caption2).bold()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.22))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if app.isBareProcess {
                            Text("裸程序").font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if app.isSystemVolume {
                            Text("系统卷").font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if app.isRunning {
                            Text("运行中").font(.caption2).foregroundStyle(.green)
                        }
                        Text(app.supportState.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(app.supportState == .supported
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.secondary.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .tag(app.bundleID)
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
            .frame(height: 180)

            // 选中 App 的操作区
            if let app = model.selectedApp {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.statusText).font(.callout).bold()
                    if !model.detailText.isEmpty {
                        Text(model.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if app.supportState == .supported {
                            Button(action: { model.disableSelected() }) {
                                Label("还原默认", systemImage: "arrow.counterclockwise")
                            }
                        } else {
                            Button(action: { model.enableSelected() }) {
                                Label("开启游戏模式支持", systemImage: "gamecontroller.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                        Button("重启 App 生效") { model.restartSelected() }
                            .font(.caption)
                            .disabled(model.isBusy)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // 底部
            HStack {
                Button("自检") { model.runSelfTest() }.font(.caption)
                Button("创建启动器…") { model.createGameLauncher() }.font(.caption)
                    .disabled(model.isBusy)
                    .help("为 Java/jar、裸可执行程序生成带游戏模式声明的替身 App")
                Button("管理员授权") { model.preAuthorize() }.font(.caption)
                    .disabled(model.isBusy)
                    .help("预先授权后，本次运行期间开启/还原/重启都不再需要密码")
                Spacer()
                Button("打开日志") {
                    NSWorkspace.shared.open(core_logDirURL())
                }
                .font(.caption)
                Button {
                    model.quitApp()
                } label: {
                    Label("退出", systemImage: "power")
                }
                .font(.caption)
                .disabled(model.isBusy)
                .help("退出本工具（配置与备份保留，随时可重新打开）")
            }
            Text("随时可一键还原；不会自行退出任何 App（重启需你确认）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 420)
    }
}

private func core_logDirURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GameModeHelper")
}
