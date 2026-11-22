import SwiftUI
import UniformTypeIdentifiers

struct AdminFile: Identifiable {
    let name: String
    let type: String
    let size: Int64
    let modified: Date
    let target: String?
    var id: String { name }
    var directory: Bool { type == "d" }
    var symbol: String { directory ? "folder.fill" : type == "l" ? "link" : "doc" }
    init?(_ json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\0"),
              let type = json["type"] as? String else { return nil }
        self.name = name; self.type = type; size = (json["size"] as? NSNumber)?.int64Value ?? 0
        modified = Date(timeIntervalSince1970: json["mtime"] as? Double ?? 0); target = json["target"] as? String
    }
}

@Observable @MainActor final class AdminFilesModel {
    let target: AdminTarget
    var path = ""
    var entries: [AdminFile] = []
    var error: String?
    var truncated = false
    var loading = false
    var progress: Double?
    var transferTitle = ""
    var committing = false
    var shared: URL?
    @ObservationIgnored private var session: AdminSession?
    @ObservationIgnored private var transfer: Task<Void, Never>?
    init(target: AdminTarget, initial: AdminSession) { self.target = target; session = initial }
    static func child(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }
    static func validName(_ name: String) -> Bool { !name.isEmpty && ![".", ".."].contains(name) && !name.contains("/") && !name.contains("\0") }
    private func active() async throws -> AdminSession {
        if let session { return session }
        let active = try await target.connect(); session = active; return active
    }
    func start() async {
        do {
            let info = try await active().request("info")
            path = info["home"] as? String ?? "/"
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-admin-initial-path"), index + 1 < args.count { path = args[index + 1] }
            #endif
            await load(path)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-admin-upload-sample") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(L10n.text("NodePulse-传输示例.bin"))
                try Data(repeating: 0x5a, count: 2 * 1024 * 1024).write(to: url)
                upload(url)
            }
            #endif
        } catch { self.error = error.localizedDescription }
    }
    func load(_ path: String) async {
        guard path.hasPrefix("/"), !path.contains("\0") else { error = L10n.text("请输入绝对路径，例如 /etc"); return }
        loading = true; defer { loading = false }
        do {
            let response = try await active().request("ls", ["path": path])
            guard let items = response["entries"] as? [[String: Any]] else { throw AdminError.disconnected }
            self.path = path
            entries = items.compactMap(AdminFile.init).sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            truncated = response["truncated"] as? Bool ?? false; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func mutate(_ type: String, _ fields: [String: Any]) async {
        do { _ = try await active().request(type, fields); await load(path) } catch { self.error = error.localizedDescription }
    }
    func upload(_ url: URL) {
        guard progress == nil else { return }
        progress = 0; transferTitle = L10n.text("正在上传 %@", String(describing: url.lastPathComponent)); error = nil
        let remote = Self.child(path, url.lastPathComponent)
        transfer = Task {
            defer { progress = nil; committing = false; transfer = nil }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var handle: Int?
            var activeSession: AdminSession?
            do {
                guard Self.validName(url.lastPathComponent) else { throw AdminError.message(L10n.text("文件名无效")) }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let size = try file.seekToEnd(); try file.seek(toOffset: 0)
                guard size <= UInt64(Int64.max) else { throw AdminError.message(L10n.text("文件过大")) }
                let active = try await active(); activeSession = active
                let response = try await active.request("put_begin", ["path": remote, "size": size, "overwrite": false])
                guard let id = response["handle"] as? Int else { throw AdminError.disconnected }; handle = id
                var offset: UInt64 = 0
                while offset < size {
                    try Task.checkCancellation()
                    let data = try file.read(upToCount: Int(min(65536, size - offset))) ?? Data()
                    guard !data.isEmpty else { throw AdminError.message(L10n.text("本地文件在上传期间发生变化")) }
                    _ = try await active.request("put", ["handle": id, "offset": offset, "data": data.base64EncodedString()])
                    offset += UInt64(data.count); progress = size == 0 ? 1 : Double(offset) / Double(size)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-admin-slow-transfer") { try await Task.sleep(for: .milliseconds(180)) }
                    #endif
                }
                try Task.checkCancellation(); committing = true; transferTitle = L10n.text("正在保存文件…")
                _ = try await active.request("put_end", ["handle": id]); handle = nil
                await load(path)
            } catch {
                if let activeSession, let handle { _ = await Task { try? await activeSession.request("put_abort", ["handle": handle]) }.value }
                else if let activeSession, Task.isCancelled { await activeSession.close(); session = nil }
                let message = error is CancellationError ? nil : error.localizedDescription
                if !Task.isCancelled { await load(path) }
                self.error = message
            }
        }
    }
    func download(_ entry: AdminFile) {
        guard progress == nil else { return }
        progress = 0; transferTitle = L10n.text("正在下载 %@", String(describing: entry.name)); error = nil
        let remote = Self.child(path, entry.name)
        transfer = Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { progress = nil; transfer = nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(entry.name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AdminError.message(L10n.text("无法创建下载文件")) }
                let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
                let active = try await active(); var offset: Int64 = 0; var identity: String?
                while true {
                    try Task.checkCancellation()
                    var fields: [String: Any] = ["path": remote, "offset": offset, "len": 65536]
                    if let identity { fields["identity"] = identity }
                    let response = try await active.request("get", fields)
                    guard let current = response["identity"] as? String, identity == nil || identity == current else { throw AdminError.message(L10n.text("文件已变化，请重新下载")) }
                    identity = current
                    guard let text = response["data"] as? String, let data = Data(base64Encoded: text), data.count <= 65536,
                          let eof = response["eof"] as? Bool else { throw AdminError.disconnected }
                    try file.write(contentsOf: data); offset += Int64(data.count)
                    let total = (response["size"] as? NSNumber)?.int64Value ?? entry.size
                    progress = total > 0 ? min(1, Double(offset) / Double(total)) : 1
                    if eof { break }; guard !data.isEmpty else { throw AdminError.disconnected }
                }
                shared = url
            } catch { try? FileManager.default.removeItem(at: directory); if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func clearShared() { if let shared { try? FileManager.default.removeItem(at: shared.deletingLastPathComponent()) }; shared = nil }
    func reconnect() async { if let session { await session.close() }; session = nil; await load(path.isEmpty ? "/" : path) }
    func cancelTransfer() { transfer?.cancel() }
    func stop() { transfer?.cancel(); if let session { Task { await session.close() } }; session = nil }
    deinit { transfer?.cancel() }
}

@MainActor struct AdminFilesScreen: View {
    @Environment(\.pulseTheme) private var theme
    @State private var model: AdminFilesModel
    @State private var importing = false
    @State private var prompt: FilePrompt?
    @State private var text = ""
    @State private var deletion: AdminFile?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    enum FilePrompt: String, Identifiable { case go, folder, rename; var id: String { rawValue } }
    @State private var renaming: AdminFile?
    init(target: AdminTarget, initial: AdminSession) { _model = State(initialValue: AdminFilesModel(target: target, initial: initial)) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                breadcrumb
                List {
                    if let error = model.error {
                        Section { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(theme.warning) }
                    }
                    if model.entries.isEmpty && !model.loading { ContentUnavailableView(L10n.text("空文件夹"), systemImage: "folder", description: Text(L10n.text("可以上传文件或新建文件夹"))) }
                    ForEach(model.entries) { entry in
                        Button { activate(entry) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: entry.symbol).font(.title2).foregroundStyle(entry.directory ? theme.ink : .secondary).frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.name).foregroundStyle(.primary).lineLimit(2).font(.subheadline.weight(.medium))
                                    Text(entry.type == "l" ? "→ \(entry.target ?? L10n.text("符号链接"))" : "\(PulseFormat.bytes(Double(entry.size))) · \(entry.modified.formatted(date: .numeric, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: entry.directory ? "chevron.right" : "arrow.down.circle").font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                            .swipeActions { Button(L10n.text("删除"), role: .destructive) { deletion = entry } }
                            .contextMenu {
                                if entry.type == "f" { Button(L10n.text("下载"), systemImage: "arrow.down.circle") { model.download(entry) } }
                                Button(L10n.text("重命名"), systemImage: "pencil") { renaming = entry; text = entry.name; prompt = .rename }
                                Button(L10n.text("删除"), systemImage: "trash", role: .destructive) { deletion = entry }
                            }
                    }
                    if model.truncated { Text(L10n.text("目录内容较多，仅显示部分条目。请前往更具体的路径。")).font(.caption).foregroundStyle(theme.warning) }
                }.listStyle(.insetGrouped).disabled(model.progress != nil)
                    .refreshable { if model.progress == nil { await model.load(model.path) } }
            }.background(theme.background)
                .navigationTitle(L10n.text("文件 · %@", String(describing: model.target.node.snapshot.name))).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("完成")) { model.stop(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L10n.text("上传文件"), systemImage: "square.and.arrow.up") { importing = true }
                            Button(L10n.text("新建文件夹"), systemImage: "folder.badge.plus") { text = ""; prompt = .folder }
                            Button(L10n.text("前往路径"), systemImage: "arrow.turn.down.right") { text = model.path; prompt = .go }
                            Button(L10n.text("重新连接"), systemImage: "arrow.clockwise") { Task { await model.reconnect() } }
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(model.progress != nil)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let progress = model.progress {
                        VStack(spacing: 12) {
                            HStack { VStack(alignment: .leading, spacing: 4) { Text(model.transferTitle).font(.subheadline.weight(.medium)); Text(L10n.text("%@%% · 端到端加密传输", String(describing: Int(progress * 100)))).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(L10n.text("取消"), role: .destructive) { model.cancelTransfer() }.disabled(model.committing) }
                            ProgressView(value: progress).tint(theme.accent)
                        }.padding(20).background(.regularMaterial)
                    }
                }
                .overlay { if model.loading { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                    do { model.upload(try result.get()) } catch { model.error = error.localizedDescription }
                }
                .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                    TextField(prompt == .go ? L10n.text("/路径") : L10n.text("名称"), text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(L10n.text("取消"), role: .cancel) { prompt = nil }
                    Button(L10n.text("确定")) { submit() }
                }
                .confirmationDialog(deletion?.directory == true ? L10n.text("递归删除此文件夹？") : L10n.text("删除此文件？"), isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                    Button(L10n.text("删除，且无法撤销"), role: .destructive) {
                        guard let entry = deletion else { return }; deletion = nil
                        Task { await model.mutate("rm", ["path": AdminFilesModel.child(model.path, entry.name), "recursive": entry.directory]) }
                    }
                    Button(L10n.text("取消"), role: .cancel) { deletion = nil }
                } message: { Text(deletion?.directory == true ? L10n.text("文件夹中的全部内容都会被删除，且不会移入废纸篓。") : L10n.text("文件不会移入废纸篓。")) }
                .sheet(isPresented: Binding(get: { model.shared != nil }, set: { if !$0 { model.clearShared() } })) { if let url = model.shared { AdminShareSheet(url: url) } }
        }.task { await model.start() }.onDisappear { model.stop() }
            .onChange(of: phase) { _, phase in if phase == .background { model.stop() } }
    }
    private var promptTitle: String { switch prompt { case .go: return L10n.text("前往路径"); case .folder: return L10n.text("新建文件夹"); case .rename: return L10n.text("重命名"); case nil: return "" } }
    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { Task { await model.load("/") } } label: { Image(systemName: "externaldrive") }
                let parts = model.path.split(separator: "/").map(String.init)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, component in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(component) { Task { await model.load("/" + parts.prefix(i + 1).joined(separator: "/")) } }.font(.caption.monospaced())
                }
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.defaultScrollAnchor(.trailing).disabled(model.progress != nil).background(.background)
    }
    private func activate(_ entry: AdminFile) {
        if entry.directory { Task { await model.load(AdminFilesModel.child(model.path, entry.name)) } }
        else if entry.type == "f" { model.download(entry) }
        else { model.error = L10n.text("符号链接：%@；请通过前往路径访问目标。", String(describing: entry.target ?? entry.name)) }
    }
    private func submit() {
        let action = prompt, name = text; prompt = nil
        guard action != .go else { Task { await model.load(name) }; return }
        guard AdminFilesModel.validName(name) else { model.error = L10n.text("名称不能为空，也不能包含 / 或使用 .、.."); return }
        guard !model.entries.contains(where: { $0.name == name }) else { model.error = L10n.text("已存在同名项目，请选择其他名称"); return }
        if action == .folder { Task { await model.mutate("mkdir", ["path": AdminFilesModel.child(model.path, name)]) } }
        else if let entry = renaming { Task { await model.mutate("mv", ["from": AdminFilesModel.child(model.path, entry.name), "to": AdminFilesModel.child(model.path, name)]) } }
    }
}

private struct AdminShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
