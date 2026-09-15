import AppKit
import CrossToolCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarDestination: String, CaseIterable, Identifiable {
    case home
    case screenshot
    case imageCompression
    case recording
    case colorSampler
    case translation
    case sharing
    case inbox
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .screenshot: return "截图"
        case .imageCompression: return "图片压缩"
        case .recording: return "录屏"
        case .colorSampler: return "提取颜色"
        case .translation: return "翻译"
        case .sharing: return "课堂共享区"
        case .inbox: return "学生上传"
        case .history: return "历史记录"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .screenshot: return "camera.viewfinder"
        case .imageCompression: return "photo.badge.arrow.down"
        case .recording: return "record.circle"
        case .colorSampler: return "eyedropper"
        case .translation: return "bubble.left.and.bubble.right"
        case .sharing: return "point.3.connected.trianglepath.dotted"
        case .inbox: return "tray.and.arrow.down"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedDestination) {
                Section {
                    ForEach(SidebarDestination.allCases.filter { $0 != .settings }) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                            .padding(.vertical, 7)
                    }
                }

                Section {
                    Label(SidebarDestination.settings.title, systemImage: SidebarDestination.settings.systemImage)
                        .tag(SidebarDestination.settings)
                        .padding(.vertical, 7)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            content
                .frame(minWidth: 780, minHeight: 620)
                .background(Color.crossToolCanvas)
                .overlay(alignment: .bottom) {
                    if let notice = model.notice {
                        NoticeToast(text: notice) {
                            model.notice = nil
                        }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.notice)
        }
        .tint(.crossToolAccent)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedDestination ?? .home {
        case .home:
            DashboardView()
        case .screenshot:
            ScreenshotPage()
        case .imageCompression:
            ImageCompressionPage(model: model.imageCompression)
        case .recording:
            ScreenRecordingPage(model: model.screenRecording) { url in
                model.shareRecording(url)
            } onRecordingDeleted: { url in
                model.recordingWasDeleted(url)
            }
        case .colorSampler:
            ColorSamplerPage(model: model.colorSampler)
        case .translation:
            TextTranslationPage()
        case .sharing:
            SharingPage()
        case .inbox:
            InboxPage()
        case .history:
            HistoryPage()
        case .settings:
            SettingsPage()
        }
    }
}

enum DashboardGreeting {
    static func text(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12:
            return "早上好"
        case 12..<18:
            return "下午好"
        default:
            return "晚上好"
        }
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var showingTextSheet = false
    @State private var showingQRCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TimelineView(.everyMinute) { context in
                    Text(DashboardGreeting.text(for: context.date))
                        .font(.system(size: 30, weight: .semibold))
                }

                SharingStatusCard(showingQRCode: $showingQRCode)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 245), spacing: 14)],
                    spacing: 14
                ) {
                    QuickActionCard(
                        title: "区域截图",
                        subtitle: "全局快捷键 \(model.shortcutLabel(for: .region))",
                        systemImage: "viewfinder"
                    ) { model.capture(.region) }

                    QuickActionCard(
                        title: "图片压缩",
                        subtitle: "本机智能压缩，不上传图片",
                        systemImage: "photo.badge.arrow.down"
                    ) { model.presentImageCompression() }

                    RecordingQuickActionCard(
                        model: model.screenRecording,
                        shortcut: model.configuredShortcutLabel(for: .recordCurrentDisplay)
                    ) {
                        if model.screenRecording.isRecording {
                            model.stopRecording()
                        } else if model.screenRecording.state == .choosingSource
                            || model.screenRecording.state == .starting {
                            model.cancelRecording()
                        } else if !model.screenRecording.isBusy {
                            model.startRecording(.currentDisplay)
                        } else {
                            model.notice = "正在完成录屏文件，请稍候"
                        }
                    }

                    QuickActionCard(
                        title: "提取颜色",
                        subtitle: model.configuredShortcutLabel(for: .pickColor)
                            .map { "取色并复制 HEX · \($0)" }
                            ?? "取色并自动复制 HEX",
                        systemImage: "eyedropper"
                    ) { model.sampleAndCopyColor() }

                    QuickActionCard(
                        title: "文本翻译",
                        subtitle: model.configuredShortcutLabel(for: .translateText)
                            .map { "端侧翻译 · \($0)" }
                            ?? "端侧翻译，不上传文字",
                        systemImage: "bubble.left.and.bubble.right"
                    ) { model.presentTextTranslation() }

                    QuickActionCard(
                        title: "分享文件",
                        subtitle: "快速分享本地文件",
                        systemImage: "folder"
                    ) { showingImporter = true }

                    QuickActionCard(
                        title: "分享文字",
                        subtitle: "分享文字或链接",
                        systemImage: "text.bubble"
                    ) { showingTextSheet = true }
                }

                FileDropZone {
                    showingImporter = true
                }

                ContentSection(title: "最近内容") {
                    if model.publicItems.isEmpty {
                        EmptyContentRow(
                            systemImage: "square.and.arrow.up",
                            text: "还没有共享内容，老师或学生上传后会显示在这里"
                        )
                    } else {
                        ForEach(model.publicItems.prefix(4)) { item in
                            SharedItemRow(item: item, showsRemove: true)
                            if item.id != model.publicItems.prefix(4).last?.id {
                                Divider()
                            }
                        }
                    }
                }

                ContentSection(title: "刚刚收到") {
                    if let item = model.receivedItems.first {
                        SharedItemRow(item: item, showsRemove: false)
                    } else {
                        EmptyContentRow(systemImage: "tray", text: "浏览器上传的文件和文字会出现在这里")
                    }
                }
            }
            .padding(30)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.addFiles(urls)
            }
        }
        .sheet(isPresented: $showingTextSheet) {
            ShareTextSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showingQRCode) {
            QRCodeSheet(value: model.shareURL, accessCode: model.sessionToken)
        }
    }
}

private struct RecordingQuickActionCard: View {
    @ObservedObject var model: ScreenRecordingFeatureModel
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        QuickActionCard(
            title: title,
            subtitle: subtitle,
            systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
            action: action
        )
    }

    private var title: String {
        switch model.state {
        case .recording: return "停止录屏"
        case .choosingSource, .starting: return "取消录屏"
        case .stopping: return "正在保存录屏"
        case .idle, .completed, .cancelled, .failed: return "开始录屏"
        }
    }

    private var subtitle: String {
        switch model.state {
        case .recording: return "已录制 \(model.elapsedText)"
        case .choosingSource, .starting, .stopping:
            return model.statusMessage ?? "正在处理…"
        case .completed(let url):
            return "已保存 \(url.lastPathComponent)"
        case .failed(let message):
            return "上次失败：\(message)"
        case .cancelled:
            return "上次录屏已取消"
        case .idle:
            return shortcut.map { "录制鼠标所在屏幕 · \($0)" }
                ?? "录制鼠标所在屏幕"
        }
    }
}

private struct ScreenshotPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "截图",
                    subtitle: "从普通截图到多窗口、带壳和滚动长图，完成后统一进入标注与输出流程"
                )

                if !model.hasScreenCapturePermission {
                    ScreenshotPermissionBanner()
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 235), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(ScreenshotMode.allCases) { mode in
                        ScreenshotModeCard(mode: mode)
                    }
                }

                ContentSection(title: "最近截图") {
                    let screenshots = model.sharedItems.filter { $0.kind == .image }
                    if screenshots.isEmpty {
                        EmptyContentRow(systemImage: "camera", text: "完成的截图会保存在本地并显示在这里")
                    } else {
                        ForEach(screenshots) { item in
                            SharedItemRow(item: item, showsRemove: true)
                            if item.id != screenshots.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(30)
        }
    }

}

private struct ScreenshotPermissionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要屏幕录制权限")
                    .font(.headline)
                Text("首次截图会申请权限；若系统没有弹窗，将引导你在设置中添加一爪。授权后请完全退出并重新打开。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("申请权限") {
                    model.requestScreenCapturePermission()
                }
                .buttonStyle(.borderedProminent)

                Button("打开系统设置") {
                    model.openScreenCaptureSettings()
                }
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct ScreenshotModeCard: View {
    @EnvironmentObject private var model: AppModel
    let mode: ScreenshotMode

    var body: some View {
        Button {
            model.capture(mode)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.crossToolAccent)
                HStack {
                    Text(mode.title)
                        .font(.headline)
                    Spacer()
                    Text(model.shortcutLabel(for: mode))
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Color.crossToolAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.crossToolAccent.opacity(0.09))
                        .clipShape(Capsule())
                }
                Text(mode.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isCapturing || model.screenRecording.isBusy)
    }
}

private struct SharingPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var showingTextSheet = false
    @State private var showingQRCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "课堂共享区",
                    subtitle: "老师和学生上传的内容会公开显示，持有课堂链接的人都能查看和下载"
                )
                SharingStatusCard(showingQRCode: $showingQRCode)

                HStack {
                    Button("添加文件", systemImage: "plus") { showingImporter = true }
                        .buttonStyle(.borderedProminent)
                    Button("分享文字", systemImage: "text.bubble") { showingTextSheet = true }
                    Spacer()
                    Button("清空共享区", systemImage: "trash", role: .destructive) {
                        model.clearPublicItems()
                    }
                    .disabled(model.publicItems.isEmpty)
                }

                ContentSection(title: "全部共享内容") {
                    if model.publicItems.isEmpty {
                        EmptyContentRow(systemImage: "doc.on.doc", text: "老师添加或学生上传后，所有浏览器都会看到")
                    } else {
                        ForEach(model.publicItems) { item in
                            SharedItemRow(item: item, showsRemove: true)
                            if item.id != model.publicItems.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(30)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        .sheet(isPresented: $showingTextSheet) {
            ShareTextSheet().environmentObject(model)
        }
        .sheet(isPresented: $showingQRCode) {
            QRCodeSheet(value: model.shareURL, accessCode: model.sessionToken)
        }
    }
}

private struct InboxPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "学生上传",
                    subtitle: "学生从浏览器上传后会立即进入课堂共享区，原文件保存在本机接收箱"
                )
                HStack {
                    Button("打开接收箱文件夹", systemImage: "folder") {
                        model.openInboxDirectory()
                    }
                    Spacer()
                    Button("清空记录", systemImage: "trash", role: .destructive) {
                        model.clearInbox()
                    }
                    .disabled(model.receivedItems.isEmpty)
                }

                ContentSection(title: "学生上传记录") {
                    if model.receivedItems.isEmpty {
                        EmptyContentRow(systemImage: "tray.and.arrow.down", text: "暂时没有收到文件或文字")
                    } else {
                        ForEach(model.receivedItems) { item in
                            SharedItemRow(
                                item: item,
                                showsRemove: model.publicItems.contains(where: { $0.id == item.id }),
                                showsPublish: !model.publicItems.contains(where: { $0.id == item.id })
                            )
                            if item.id != model.receivedItems.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(30)
        }
    }
}

private struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "历史记录", subtitle: "保存在本机的分享和接收记录")
                ContentSection(title: "全部记录") {
                    let items = (model.sharedItems + model.receivedItems).sorted { $0.createdAt > $1.createdAt }
                    if items.isEmpty {
                        EmptyContentRow(systemImage: "clock", text: "还没有内容记录")
                    } else {
                        ForEach(items) { item in
                            SharedItemRow(
                                item: item,
                                showsRemove: model.publicItems.contains(where: { $0.id == item.id }),
                                showsPublish: item.direction == .incoming
                                    && !model.publicItems.contains(where: { $0.id == item.id })
                            )
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(30)
        }
    }
}

private struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loginItemSettings = LoginItemSettingsModel()
    @State private var showingAccessCodeEditor = false

    var body: some View {
        Form {
            LoginItemSettingsSection(model: loginItemSettings)
            Section("Finder 右键服务") {
                LabeledContent("操作", value: "服务 → 复制路径")
                Text("在 Finder 中选中文件或文件夹，右键选择“服务 → 复制路径”。支持多选，每行一个完整路径；仅复制路径，不读取或修改文件内容。")
                    .foregroundStyle(.secondary)
                Text("请将一爪安装到“应用程序”并打开一次。若菜单未显示，请在 macOS 的键盘快捷键“服务”设置中检查是否已启用“复制路径”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("共享服务") {
                LabeledContent("默认端口", value: String(model.port))
                LabeledContent("传输范围", value: "当前局域网")
                LabeledContent("当前访问码") {
                    HStack(spacing: 10) {
                        Text(model.sessionToken)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("修改") {
                            showingAccessCodeEditor = true
                        }
                    }
                }
                Text(model.usesCustomShareAccessCode
                    ? "当前使用自定义访问码。更新后旧链接和二维码会立即失效。"
                    : "当前使用 10 位随机访问码；可改成便于课堂输入的 6–24 位自定义访问码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("启动 App 时自动开启共享", isOn: .constant(true))
                    .disabled(true)
            }
            Section("存储") {
                Text("一爪数据目录：~/Library/Application Support/crosstool（包含 Inbox、Screenshots 与 Recordings）")
                    .foregroundStyle(.secondary)
            }
            GlobalShortcutSettingsSection()
            Section("关于") {
                LabeledContent("版本", value: appVersion)
                Text("无账号、无云端，文件直接在设备之间传输。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .sheet(isPresented: $showingAccessCodeEditor) {
            ShareAccessCodeEditor(accessCode: model.sessionToken)
                .environmentObject(model)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)):
            return "\(version) (\(build))"
        case let (.some(version), .none):
            return version
        default:
            return "未知"
        }
    }
}
