import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MenuBarPanelLayout {
    enum Action: Hashable {
        case copyShareLink
        case toggleServer
        case openMainWindow
        case terminate
    }

    static let statusActions: [Action] = [.copyShareLink, .toggleServer]
    static let footerActions: [Action] = [.openMainWindow, .terminate]
}

struct MenuBarPanelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var showingTextSheet = false

    private let screenshotColumns = Array(repeating: GridItem(.flexible()), count: 3)
    private let sharingColumns = Array(repeating: GridItem(.flexible()), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            Text(ApplicationBrand.displayName)
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                Circle()
                    .fill(model.isServerRunning ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isServerRunning ? "共享已开启" : "共享未开启")
                        .font(.subheadline.weight(.medium))
                    Text("\(model.shareAddress) · \(model.sessionToken)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    ForEach(MenuBarPanelLayout.statusActions, id: \.self) { action in
                        actionButton(for: action)
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 11))

            LazyVGrid(columns: screenshotColumns, spacing: 10) {
                ForEach(ScreenshotMode.allCases) { mode in
                    MenuActionButton(
                        title: mode.title,
                        systemImage: mode.systemImage,
                        shortcut: model.configuredShortcutLabel(for: mode.shortcutCommand)
                    ) {
                        model.capture(mode)
                    }
                }
            }

            Text("工具")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            RecordingMenuSection(
                recording: model.screenRecording,
                start: model.startRecording,
                stop: model.stopRecording,
                cancel: model.cancelRecording,
                sampleColor: model.sampleAndCopyColor
            )

            Text("课堂共享")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: sharingColumns, spacing: 10) {
                MenuActionButton(title: "分享文件", systemImage: "folder") {
                    showingImporter = true
                }
                MenuActionButton(title: "分享文字", systemImage: "text.bubble") {
                    showingTextSheet = true
                }
            }

            Button {
                openMainWindow()
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text("共享区 \(model.publicItems.count) 项 · 学生上传 \(model.receivedItems.count) 项")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(11)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

                Divider()
                HStack {
                    ForEach(MenuBarPanelLayout.footerActions, id: \.self) { action in
                        actionButton(for: action)
                        if action != MenuBarPanelLayout.footerActions.last {
                            Spacer()
                        }
                    }
                }
                .font(.subheadline)
            }
            .padding(16)
        }
        // A ScrollView has no intrinsic height. Giving it only a maximum lets
        // MenuBarExtra's window choose its smallest possible size, which can
        // collapse the popover to little more than a scroll indicator.
        .frame(width: 350, height: 620)
        .tint(.crossToolAccent)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        .sheet(isPresented: $showingTextSheet) {
            ShareTextSheet().environmentObject(model)
        }
    }

    private func openMainWindow() {
        model.presentMainWindow()
    }

    @ViewBuilder
    private func actionButton(for action: MenuBarPanelLayout.Action) -> some View {
        switch action {
        case .copyShareLink:
            Button {
                model.copyShareLink()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(!model.isServerRunning)
            .accessibilityLabel("复制链接")
            .help("复制共享链接")

        case .toggleServer:
            Button {
                model.toggleServer()
            } label: {
                Image(systemName: model.isServerRunning ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isServerRunning ? Color.red : Color.crossToolAccent)
            .accessibilityLabel(model.isServerRunning ? "停止共享" : "开始共享")
            .help(model.isServerRunning ? "停止共享" : "开始共享")

        case .openMainWindow:
            Button("打开主窗口", systemImage: "macwindow") {
                openMainWindow()
            }
            .buttonStyle(.plain)

        case .terminate:
            Button("退出", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出一爪")
            .help("完全退出一爪")
        }
    }
}

private struct RecordingMenuSection: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var recording: ScreenRecordingFeatureModel
    let start: (ScreenRecordingSource) -> Void
    let stop: () -> Void
    let cancel: () -> Void
    let sampleColor: () -> Void

    private let columns = Array(repeating: GridItem(.flexible()), count: 2)

    var body: some View {
        if recording.isRecording {
            Button(action: stop) {
                HStack(spacing: 11) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("停止录屏")
                            .font(.subheadline.weight(.semibold))
                        Text(recording.elapsedText)
                            .font(.system(.caption, design: .monospaced))
                        if let source = recording.activeSource,
                           let shortcut = appModel.configuredShortcutLabel(
                               for: source.shortcutCommand
                           ) {
                            Text("再次按 \(shortcut) 停止")
                                .font(.system(.caption2, design: .monospaced))
                                .opacity(0.9)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
        } else if recording.isBusy {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(recording.statusMessage ?? "正在准备录屏…")
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                if recording.state != .stopping {
                    Button("取消", role: .destructive, action: cancel)
                }
            }
            .padding(11)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 11))
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                MenuActionButton(
                    title: "录制屏幕",
                    systemImage: "display",
                    shortcut: appModel.configuredShortcutLabel(for: .recordCurrentDisplay)
                ) {
                    start(.currentDisplay)
                }
                MenuActionButton(
                    title: "录制区域",
                    systemImage: "viewfinder",
                    shortcut: appModel.configuredShortcutLabel(for: .recordRegion)
                ) {
                    start(.region)
                }
                MenuActionButton(
                    title: "录制窗口",
                    systemImage: "macwindow",
                    shortcut: appModel.configuredShortcutLabel(for: .recordWindow)
                ) {
                    start(.window)
                }
                MenuActionButton(
                    title: "提取颜色",
                    systemImage: "eyedropper",
                    shortcut: appModel.configuredShortcutLabel(for: .pickColor)
                ) {
                    sampleColor()
                }
                MenuActionButton(
                    title: "文本翻译",
                    systemImage: "bubble.left.and.bubble.right",
                    shortcut: appModel.configuredShortcutLabel(for: .translateText)
                ) {
                    appModel.presentTextTranslation()
                }
                MenuActionButton(
                    title: "图片压缩",
                    systemImage: "photo.badge.arrow.down"
                ) {
                    appModel.presentImageCompression()
                }
            }
        }
    }
}

private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void

    init(title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.crossToolAccent)
                VStack(spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.82)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
