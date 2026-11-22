import AVFoundation
import SwiftUI
import VisionKit

struct PairInviteSheet: View {
    let invite: PairInvite
    let connect: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var admin = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("已扫码 · 尚未连接", systemImage: "qrcode").foregroundStyle(.mint)
                    LabeledContent(invite.isRelay ? "中转服务器" : "探针", value: invite.address)
                    if let code = invite.code { LabeledContent("配对码", value: code) }
                    if invite.isRelay { Text("链接已包含中转密码；组密钥只会在双方确认后加密传输。").font(.caption).foregroundStyle(.secondary) }
                } header: { Text("确认连接信息") } footer: { Text("只连接你信任的地址。扫码不代表已验证身份，接下来仍须对照服务器终端上的图案和六位数字。") }
                Section { Toggle("同时授权本机管理", isOn: $admin).tint(.mint) } footer: { Text("授权可控制文件、终端与电源，可能拥有 root 权限。仅完整构建支持。") }
                Button("连接并核对图案") { connect(admin) }.frame(maxWidth: .infinity).tint(.mint)
            }.navigationTitle("扫码配对").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

struct PairScanner: View {
    let result: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized: Bool?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if authorized == true && error == nil {
                    ScannerCamera(result: result, failure: { error = $0 }).ignoresSafeArea(edges: .bottom)
                } else if authorized == false || error != nil {
                    ContentUnavailableView("相机不可用", systemImage: "camera", description: Text(error ?? "请在系统设置中允许相机访问。模拟器可返回粘贴服务器上的配对链接。"))
                } else { ProgressView("正在请求相机权限…") }
            }.navigationTitle("扫描服务器二维码").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task {
                    switch AVCaptureDevice.authorizationStatus(for: .video) {
                    case .authorized: authorized = true
                    case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
                    default: authorized = false
                    }
                }
        }
    }
}

private struct ScannerCamera: UIViewControllerRepresentable {
    let result: (String) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(result: result) }
    func makeUIViewController(context: Context) -> UIViewController {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            do { try scanner.startScanning() }
            catch { DispatchQueue.main.async { failure("无法启动扫码，可返回粘贴配对链接。") } }
            return scanner
        }
        return FallbackCamera(result: context.coordinator.accept, failure: failure)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        (controller as? DataScannerViewController)?.stopScanning()
        (controller as? FallbackCamera)?.stop()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let result: (String) -> Void
        private var handled = false
        init(result: @escaping (String) -> Void) { self.result = result }
        func accept(_ text: String) {
            guard !handled, text.lowercased().hasPrefix("nodepulse://") else { return }
            handled = true; result(text)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { if case .barcode(let code) = item, let value = code.payloadStringValue { accept(value) } }
        }
    }
}

private final class FallbackCamera: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nodepulse.pair.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let result: (String) -> Void
    private let failure: (String) -> Void
    init(result: @escaping (String) -> Void, failure: @escaping (String) -> Void) { self.result = result; self.failure = failure; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            DispatchQueue.main.async { self.failure("此设备没有可用相机，可返回粘贴配对链接。") }; return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { DispatchQueue.main.async { self.failure("相机初始化失败，请使用配对链接。") }; return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; view.layer.addSublayer(preview); self.preview = preview
        queue.async { self.session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects { if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue { result(text) } }
    }
    func stop() { queue.async { self.session.stopRunning() } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
}
