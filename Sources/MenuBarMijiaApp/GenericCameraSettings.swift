import AppKit
import MijiaCore
import SwiftUI

struct GenericCameraSettings: View {
    let store: HomeStore
    @State private var editing: GenericCameraSource?
    @State private var credentials = GenericCameraSource.Credentials()
    @State private var removing: GenericCameraSource?
    @State private var credentialFailure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.genericCameras) { camera in
                HStack {
                    Text(camera.name)
                    Spacer()
                    Button(L10n.tr("编辑", "Edit")) {
                        guard let saved = store.genericCameraCredentials(camera) else {
                            credentialFailure = true
                            return
                        }
                        credentials = saved
                        editing = camera
                    }
                    Button(L10n.tr("移除", "Remove"), role: .destructive) { removing = camera }
                }
            }
            Button(L10n.tr("添加通用摄像机", "Add a generic camera"), systemImage: "video.badge.plus") {
                credentials = .init()
                editing = .init()
            }
        }
        .sheet(item: $editing, onDismiss: { credentials = .init() }) { camera in
            GenericCameraEditor(store: store, camera: camera, credentials: credentials)
        }
        .alert(L10n.tr("移除摄像机？", "Remove camera?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { camera in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("移除", "Remove"), role: .destructive) {
                if !store.removeGenericCamera(camera) { credentialFailure = true }
            }
        } message: { camera in
            Text(camera.name)
        }
        .alert(L10n.tr("无法访问摄像机的钥匙串凭据", "Camera credentials are unavailable in Keychain"),
               isPresented: $credentialFailure) {
            Button(L10n.tr("好", "OK"), role: .cancel) {}
        }
    }
}

private struct GenericCameraEditor: View {
    let store: HomeStore
    private let original: GenericCameraSource
    private let originalCredentials: GenericCameraSource.Credentials
    @State private var draft: GenericCameraSource
    @State private var credentials: GenericCameraSource.Credentials
    @State private var port: String
    @State private var channel: String
    @State private var testing: UUID?
    @State private var approvedAction: Action?
    @State private var frame: NSImage?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsUnsavedChanges) private var unsaved

    private enum Action { case save, test }

    init(store: HomeStore, camera: GenericCameraSource, credentials: GenericCameraSource.Credentials) {
        self.store = store
        original = camera
        originalCredentials = credentials
        _draft = State(initialValue: camera)
        _credentials = State(initialValue: credentials)
        _port = State(initialValue: camera.port.map(String.init) ?? "")
        _channel = State(initialValue: camera.channel.map(String.init) ?? "")
    }

    private var isDirty: Bool {
        draft != original || credentials != originalCredentials
            || port != (original.port.map(String.init) ?? "") || channel != (original.channel.map(String.init) ?? "")
    }

    private var camera: GenericCameraSource? {
        var camera = draft
        camera.name = camera.name.trimmingCharacters(in: .whitespacesAndNewlines)
        camera.host = camera.host.trimmingCharacters(in: .whitespacesAndNewlines)
        camera.port = Int(port)
        camera.channel = Int(channel)
        if camera.kind != .rtsp { camera.path = nil }
        if camera.kind != original.kind {
            camera.mainStream = nil
            if camera.kind != .rtsp { camera.subStream = nil }
        }
        guard port.isEmpty || camera.port != nil, channel.isEmpty || camera.channel != nil,
              camera.isValid, camera.kind != .tapo || !credentials.password.isEmpty else { return nil }
        return camera
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField(L10n.tr("名称", "Name"), text: $draft.name)
                Picker(L10n.tr("协议", "Protocol"), selection: $draft.kind) {
                    ForEach(GenericCameraSource.Kind.allCases) { Text($0.title).tag($0) }
                }
                TextField(L10n.tr("主机", "Host"), text: $draft.host, prompt: Text("camera.local"))
                TextField(L10n.tr("端口", "Port"), text: $port, prompt: Text(String(draft.kind.defaultPort)))
                if draft.kind == .rtsp {
                    TextField(L10n.tr("主码流路径", "Main stream path"), text: optionalText($draft.path), prompt: Text("/stream1"))
                    TextField(L10n.tr("子码流路径", "Substream path"), text: optionalText($draft.subStream), prompt: Text("/stream2"))
                }
                if [.isapi, .dahua, .tapo].contains(draft.kind) {
                    TextField(L10n.tr("通道", "Channel"), text: $channel, prompt: Text("1"))
                }
                if draft.kind != .tapo {
                    TextField(L10n.tr("用户名", "Username"), text: $credentials.username)
                }
                SecureField(draft.kind == .tapo ? L10n.tr("Tapo 云账号密码", "Tapo cloud password") : L10n.tr("密码", "Password"),
                            text: $credentials.password)
            }
            .disabled(testing != nil)
            if let frame {
                Image(nsImage: frame)
                    .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 140)
                    .accessibilityLabel(L10n.tr("摄像机测试画面", "Camera test picture"))
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.tr("测试连接", "Test Connection")) { request(.test) }
                    .disabled(camera == nil || testing != nil)
                if testing != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存", "Save")) { request(.save) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(camera == nil || testing != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(isDirty)
        .onChange(of: isDirty, initial: true) { _, dirty in
            unsaved?.register("generic-camera", .init(
                title: L10n.tr("通用摄像机", "Generic Camera"), isDirty: dirty,
                save: { save(confirmed: false) },
                discard: { dismiss() }
            ))
        }
        .onDisappear { unsaved?.unregister("generic-camera") }
        .onChange(of: camera) { _, _ in frame = nil }
        .onChange(of: credentials) { _, _ in frame = nil }
        .alert(L10n.tr("允许连接非局域网地址？", "Allow a non-local connection?"), isPresented: Binding(
            get: { approvedAction != nil }, set: { if !$0 { approvedAction = nil } }
        ), presenting: approvedAction) { action in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("允许", "Allow")) { run(action, confirmed: true) }
        } message: { _ in
            Text(L10n.tr("摄像机协议可能在网络上以明文传输凭据和视频。", "The camera protocol may send credentials and video unencrypted."))
        }
        .task(id: testing) {
            guard testing != nil, let camera else { return }
            do {
                let data = try await store.testGenericCamera(camera, credentials: credentials, confirmedPlaintext: testConsent)
                try Task.checkCancellation()
                frame = NSImage(data: data)
            } catch {
                if Task.isCancelled { return }
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? L10n.tr("连接测试失败。", "Connection test failed.")
            }
            testing = nil
        }
    }

    @State private var testConsent = false

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func request(_ action: Action) {
        guard let camera else { return }
        if camera.requiresPlaintextConsent && !store.hasGenericCameraConsent(camera) {
            approvedAction = action
        } else {
            run(action, confirmed: false)
        }
    }

    private func run(_ action: Action, confirmed: Bool) {
        error = nil
        switch action {
        case .save: _ = save(confirmed: confirmed)
        case .test:
            frame = nil
            testConsent = confirmed
            testing = UUID()
        }
    }

    private func save(confirmed: Bool) -> Bool {
        guard let camera, store.saveGenericCamera(camera, credentials: credentials, confirmedPlaintext: confirmed) else {
            error = L10n.tr("无法保存摄像机，请检查连接设置和钥匙串权限。", "Couldn’t save the camera. Check the connection settings and Keychain access.")
            return false
        }
        dismiss()
        return true
    }
}

struct GenericCameraCardPreview: View {
    let store: HomeStore
    let camera: GenericCameraSource
    @State private var frame: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let frame {
                Image(nsImage: frame).resizable().scaledToFit()
                    .accessibilityLabel(L10n.tr("摄像机实时预览", "Live camera preview"))
            } else if failed {
                Text(L10n.tr("预览暂不可用", "Preview unavailable"))
                    .font(.caption).foregroundStyle(DesignTokens.secondaryText)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 120)
        .task(id: store.genericCameraRevision) {
            frame = nil
            failed = false
            do {
                try await store.previewGenericCamera(camera) { data in
                    if !Task.isCancelled { frame = NSImage(data: data) }
                }
            } catch {
                if !Task.isCancelled {
                    frame = nil
                    failed = true
                }
            }
        }
    }
}
