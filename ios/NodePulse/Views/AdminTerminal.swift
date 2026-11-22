import SwiftUI
import SwiftTerm

@Observable @MainActor
final class AdminTerminalModel {
    let target: AdminTarget
    var status = "正在打开终端…"
    var running = false
    var connecting = false
    var control = false
    @ObservationIgnored weak var terminal: TerminalView?
    @ObservationIgnored private var session: AdminSession?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var resizing: Task<Void, Never>?
    private var pty: Int?
    private var cols = 80
    private var rows = 24
    init(target: AdminTarget, initial: AdminSession) { self.target = target; session = initial }
    func start() async {
        guard !connecting else { return }; connecting = true
        defer { connecting = false }
        do {
            let active: AdminSession
            if let session { active = session } else { active = try await target.connect(); session = active }
            let reply = try await active.request("pty_open", ["cols": cols, "rows": rows])
            guard let id = reply["pty"] as? Int else { throw AdminError.disconnected }
            pty = id; running = true; status = "已连接 · \(cols) × \(rows)"
            terminal?.feed(text: "\u{1b}[2J\u{1b}[H")
            events = Task { [weak self] in
                for await event in active.events {
                    guard let self else { return }
                    switch event {
                    case .output(let pty, let data) where pty == id: self.terminal?.feed(byteArray: Array(data)[...])
                    case .exit(let pty, let code) where pty == id:
                        self.running = false; self.status = "终端已退出 · 代码 \(code)"
                        await active.close(); self.session = nil
                    default: break
                    }
                }
                if let self, self.running { self.running = false; self.status = "连接已断开，可重新连接"; self.session = nil }
            }
            resize(cols: cols, rows: rows)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-admin-command"), index + 1 < args.count {
                try await active.input(pty: id, data: Data((args[index + 1] + "\r").utf8))
            }
            #endif
        } catch {
            status = error.localizedDescription; running = false
            if let session { await session.close() }; session = nil
        }
    }
    func send(_ data: Data, modifier: Bool = true) {
        guard let pty, let session, running else { return }
        var data = data
        if modifier, control, data.count == 1, let byte = data.first, byte == 32 || (byte >= 64 && byte <= 126) {
            data = Data([byte == 32 ? 0 : byte & 31]); control = false
        }
        Task {
            do {
                for offset in stride(from: 0, to: data.count, by: 16384) {
                    try await session.input(pty: pty, data: data.subdata(in: offset..<min(data.count, offset + 16384)))
                }
            } catch { status = error.localizedDescription; running = false; self.session = nil; await session.close() }
        }
    }
    func resize(cols: Int, rows: Int) {
        self.cols = max(2, min(cols, 1000)); self.rows = max(2, min(rows, 1000))
        guard let pty, let session, running else { return }
        resizing?.cancel()
        let columns = self.cols, lines = self.rows
        resizing = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                _ = try await session.request("pty_resize", ["pty": pty, "cols": columns, "rows": lines])
                status = "已连接 · \(columns) × \(lines)"
            } catch is CancellationError {} catch { status = error.localizedDescription }
        }
    }
    func stop() {
        running = false; status = "连接已关闭"; pty = nil
        resizing?.cancel(); events?.cancel(); events = nil
        if let session { Task { await session.close() } }; session = nil
    }
    deinit { events?.cancel(); resizing?.cancel() }
}

@MainActor struct AdminTerminalScreen: View {
    @State private var model: AdminTerminalModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    init(target: AdminTarget, initial: AdminSession) { _model = State(initialValue: AdminTerminalModel(target: target, initial: initial)) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(model.running ? .mint : .orange).frame(width: 6, height: 6)
                    Text(model.status).font(.caption).lineLimit(3)
                    Spacer()
                    if model.connecting { ProgressView().tint(.mint) }
                    if !model.running && !model.connecting { Button("重新连接") { Task { await model.start() } }.font(.caption.bold()) }
                }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10).background(.white.opacity(0.04))
                TerminalSurface(model: model)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        key("Esc", bytes: [27]); key("Tab", bytes: [9])
                        Button("Ctrl") { model.control.toggle() }
                            .font(.system(.caption, design: .monospaced).bold()).padding(.horizontal, 13).frame(height: 38)
                            .background(model.control ? Color.teal : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        ForEach([("↑", "A"), ("↓", "B"), ("←", "D"), ("→", "C")], id: \.0) { title, code in
                            key(title, bytes: Array("\u{1b}[\(code)".utf8))
                        }
                        ForEach(["|", "~", "/", "-"], id: \.self) { key($0, bytes: Array($0.utf8)) }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }.background(.white.opacity(0.04))
            }.background(Color(red: 0.035, green: 0.05, blue: 0.07))
                .navigationTitle(model.target.node.snapshot.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.stop(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("键盘", systemImage: "keyboard") {
                        if model.terminal?.isFirstResponder == true { _ = model.terminal?.resignFirstResponder() }
                        else { _ = model.terminal?.becomeFirstResponder() }
                    } }
                }
        }.preferredColorScheme(.dark).tint(.mint)
            .task { await model.start() }
            .onDisappear { model.stop() }
            .onChange(of: phase) { _, phase in if phase == .background { model.stop() } }
    }
    private func key(_ title: String, bytes: [UInt8]) -> some View {
        Button { model.send(Data(bytes), modifier: false) } label: {
            Text(title).font(.system(.subheadline, design: .monospaced).weight(.medium)).frame(minWidth: 38, minHeight: 38)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(!model.running)
    }
}

@MainActor private struct TerminalSurface: UIViewRepresentable {
    let model: AdminTerminalModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = UIColor(red: 0.035, green: 0.05, blue: 0.07, alpha: 1)
        terminal.nativeForegroundColor = UIColor(red: 0.84, green: 0.91, blue: 0.91, alpha: 1)
        terminal.inputAccessoryView = nil; terminal.terminalDelegate = context.coordinator
        model.terminal = terminal
        return terminal
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) { uiView.terminalDelegate = nil }
    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: AdminTerminalModel
        init(model: AdminTerminalModel) { self.model = model }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { Task { @MainActor in model.resize(cols: newCols, rows: newRows) } }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { let bytes = Data(data); Task { @MainActor in model.send(bytes) } }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
