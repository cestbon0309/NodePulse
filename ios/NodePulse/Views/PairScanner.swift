import AVFoundation
import SwiftUI
import VisionKit

struct PairInviteSheet: View {
    @Environment(\.pulseTheme) private var theme
    let invite: PairInvite
    let connect: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var admin = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L10n.text("已扫码 · 尚未连接"), systemImage: "qrcode").foregroundStyle(theme.ink)
                    LabeledContent(invite.isRelay ? L10n.text("中转服务器") : L10n.text("探针"), value: invite.address)
                    if let code = invite.code { LabeledContent(L10n.text("配对码"), value: code) }
                    if invite.isRelay { Text(L10n.text("链接已包含中转密码；组密钥只会在双方确认后加密传输。")).font(.caption).foregroundStyle(.secondary) }
                } header: { Text(L10n.text("确认连接信息")) } footer: { Text(L10n.text("只连接你信任的地址。扫码不代表已验证身份，接下来仍须对照服务器终端上的图案和六位数字。")) }
                Section { Toggle(L10n.text("同时授权本机管理"), isOn: $admin).tint(theme.accent) } footer: { Text(L10n.text("授权可控制文件、终端与电源，可能拥有 root 权限。仅完整构建支持。")) }
                Button(L10n.text("连接并核对图案")) { connect(admin) }.frame(maxWidth: .infinity).tint(theme.accent)
            }.navigationTitle(L10n.text("扫码配对")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } } }
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
                    ContentUnavailableView(L10n.text("相机不可用"), systemImage: "camera", description: Text(error ?? L10n.text("请在系统设置中允许相机访问。模拟器可返回粘贴服务器上的配对链接。")))
                } else { ProgressView(L10n.text("正在请求相机权限…")) }
            }.navigationTitle(L10n.text("扫描服务器二维码")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } } }
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
            catch { DispatchQueue.main.async { failure(L10n.text("无法启动扫码，可返回粘贴配对链接。")) } }
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
            DispatchQueue.main.async { self.failure(L10n.text("此设备没有可用相机，可返回粘贴配对链接。")) }; return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { DispatchQueue.main.async { self.failure(L10n.text("相机初始化失败，请使用配对链接。")) }; return }
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
