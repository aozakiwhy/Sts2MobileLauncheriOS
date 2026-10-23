import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

@main
struct LauncherApp: App {
    @StateObject private var model = LauncherModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            LauncherView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { phase in
                    if phase == .background { model.cancelImport() }
                }
        }
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var state = LibraryState()
    @Published private(set) var isImporting = false
    @Published private(set) var ready = false
    @Published var message: String?
    private var library: PayloadLibrary?
    private var importTask: Task<Void, Never>?
    private var payloadIndex: [UUID: InstalledPayload] = [:]

    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let root = support.appendingPathComponent("Sts2Launcher", isDirectory: true)
            library = try PayloadLibrary(root: root)
            ready = true
            Task { await reload() }
        } catch { message = error.localizedDescription }
    }

    private func reload() async {
        if let library {
            let snapshot = await library.snapshot()
            payloadIndex = Dictionary(uniqueKeysWithValues: snapshot.payloads.map { ($0.id, $0) })
            state = snapshot
        }
    }

    func payload(for profile: LaunchProfile) -> InstalledPayload? { payloadIndex[profile.payloadID] }

    func importFolder(_ url: URL) {
        guard let library, !isImporting else { return }
        isImporting = true
        importTask = Task(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isImporting = false
                importTask = nil
            }
            do {
                let worker = Task.detached(priority: .utility) {
                    try await library.importDirectory(url)
                }
                _ = try await withTaskCancellationHandler {
                    // Cover cancellation that arrived before the detached task was created.
                    if Task.isCancelled { worker.cancel() }
                    return try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                await reload()
                message = "本地版本已导入，并创建了独立存档和模组目录。游戏运行时尚未集成。"
            } catch is CancellationError {
                message = "已取消导入，原有版本保留。请保持应用在前台后重试。"
            } catch { message = error.localizedDescription }
        }
    }

    func cancelImport() { importTask?.cancel() }

    func select(_ profile: LaunchProfile) {
        guard let library, !isImporting, state.selectedProfileID != profile.id else { return }
        Task {
            do {
                try await library.select(profile.id)
                await reload()
            } catch { message = error.localizedDescription }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @State private var choosingFolder = false

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        Label("iOS 移植开发预览", systemImage: "hammer.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text("可管理本地游戏版本。目前无法启动游戏，Steam 登录、云存档与模组下载尚未接通。")
                            .font(.subheadline)
                    }
                    Section("当前配置") {
                        LabeledContent("游玩身份", value: "本地游客")
                        LabeledContent("所选版本", value: model.state.selectedProfile?.name ?? "未导入")
                        Text("每个导入版本使用独立的存档和模组目录，切换时保留旧版本数据。游客模式也需要自行提供已拥有的游戏文件。")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("游戏运行时尚未集成", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Section("版本库") {
                        if model.state.profiles.isEmpty {
                            Text("在“文件”App 中解压 PC 游戏包，再选择包含 SlayTheSpire2.pck 和 release_info.json 的游戏根目录。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.state.profiles) { profile in
                            Button { model.select(profile) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(profile.name).foregroundStyle(.primary)
                                        if let payload = model.payload(for: profile) {
                                            Text(ByteCountFormatter.string(fromByteCount: payload.byteCount, countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text("DLL SHA256 · \(payload.dllSHA256.prefix(12))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if model.state.selectedProfileID == profile.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                                    }
                                }
                            }
                            .disabled(model.isImporting)
                        }
                        if model.isImporting {
                            ProgressView("正在复制并校验，请保持前台；低电量或温度偏高时会减速…")
                            Button("取消导入", role: .cancel) { model.cancelImport() }
                        } else {
                            Button { choosingFolder = true } label: {
                                Label("导入本地游戏目录", systemImage: "folder.badge.plus")
                            }.disabled(!model.ready)
                        }
                    }
                }
                .navigationTitle("尖塔 · iOS")
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): model.importFolder(url)
                    case .failure(let error): model.message = error.localizedDescription
                    }
                }
            }.tabItem { Label("版本库", systemImage: "square.stack.3d.up") }

            NavigationStack {
                List {
                    Section("Steam 接入状态") {
                        Label("尚未实现 Steam 登录", systemImage: "person.crop.circle.badge.clock")
                        Text("此构建不收集 Steam 密码或令牌。浏览器登录身份不能直接用来读取 Steam Cloud 或下载付费游戏。")
                        Text("计划接入：登录与 Steam Guard、拥有权校验、可访问的分支 / 精确 Manifest 下载、手动云存档同步及冲突备份。")
                    }
                    Section("历史版本") {
                        Text("已拥有的历史版本可通过本地目录导入和切换。尚未提供在线版本目录，也不能承诺所有历史快照始终可下载。")
                    }
                }.navigationTitle("Steam")
            }.tabItem { Label("Steam", systemImage: "cloud") }

            NavigationStack {
                List {
                    Section("创意工坊") {
                        Link(destination: URL(string: "https://steamcommunity.com/app/2868840/workshop/")!) {
                            Label("在浏览器中查看创意工坊", systemImage: "safari")
                        }
                        Text("目前仅提供网页浏览入口。原生下载、依赖管理和模组加载尚未实现。PC / Android 的 C# 模组不等于兼容 iOS，需要先验证运行时和补丁机制。")
                    }
                }.navigationTitle("模组")
            }.tabItem { Label("模组", systemImage: "puzzlepiece.extension") }
        }
        .tint(.mint)
        .alert("启动器", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } }
        )) { Button("好") { model.message = nil } } message: { Text(model.message ?? "") }
    }
}
