import AppKit
import CoreImage.CIFilterBuiltins
import CrossToolCore
import SwiftUI

extension Color {
    static let crossToolAccent = Color(red: 0.34, green: 0.34, blue: 0.97)
    static let crossToolCanvas = Color(nsColor: .windowBackgroundColor)
    static let crossToolBorder = Color.primary.opacity(0.11)
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

struct SharingStatusCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingQRCode: Bool
    @State private var showingAccessCodeEditor = false

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(statusColor)
                .frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle)
                    .font(.headline)
                HStack(spacing: 7) {
                    Text(model.shareAddress)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("访问码 \(model.sessionToken)")
                    Button("修改") {
                        showingAccessCodeEditor = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.crossToolAccent)
                    .accessibilityLabel("修改共享访问码")
                }
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            }
            Spacer(minLength: 20)
            Button("复制链接", systemImage: "link") { model.copyShareLink() }
                .disabled(!model.isServerRunning)
            Button(model.isServerRunning ? "停止共享" : "开始共享", systemImage: model.isServerRunning ? "stop.fill" : "play.fill") {
                model.toggleServer()
            }
            .tint(model.isServerRunning ? .red : .crossToolAccent)
            Button("显示二维码", systemImage: "qrcode") { showingQRCode = true }
                .disabled(!model.isServerRunning)
        }
        .padding(20)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
        .sheet(isPresented: $showingAccessCodeEditor) {
            ShareAccessCodeEditor(accessCode: model.sessionToken)
                .environmentObject(model)
        }
    }

    private var statusColor: Color {
        switch model.serverState {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusTitle: String {
        switch model.serverState {
        case .running: return "局域网共享已开启"
        case .starting: return "正在启动共享服务…"
        case .failed(let message): return "启动失败：\(message)"
        case .stopped: return "局域网共享未开启"
        }
    }
}

struct QuickActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.crossToolAccent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(17)
            .frame(maxWidth: .infinity)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct FileDropZone: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false
    let chooseFiles: () -> Void

    var body: some View {
        Button(action: chooseFiles) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.crossToolAccent)
                Text("拖入文件，立即分享")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(isTargeted ? Color.crossToolAccent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isTargeted ? Color.crossToolAccent : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.3, dash: [6, 5])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

struct ContentSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            Divider()
            VStack(spacing: 0) {
                content
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }
}

struct EmptyContentRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}

struct SharedItemRow: View {
    @EnvironmentObject private var model: AppModel
    let item: SharedItem
    let showsRemove: Bool

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if let bytes = item.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                    if item.direction == .incoming {
                        Text("· 同学上传")
                        if let remote = item.remoteAddress {
                            Text("· \(remote)")
                        }
                    } else {
                        Text("· 老师分享")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if item.kind == .text {
                Button("复制", systemImage: "doc.on.doc") { model.copyText(item) }
                    .labelStyle(.iconOnly)
                    .help("复制文字")
            } else {
                Button("在 Finder 中显示", systemImage: "folder") { model.reveal(item) }
                    .labelStyle(.iconOnly)
                    .help("在 Finder 中显示")
            }
            if showsRemove {
                Button("从共享区移除", systemImage: "trash", role: .destructive) {
                    model.removePublicItem(item)
                }
                .labelStyle(.iconOnly)
                .help("从课堂共享区移除")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.kind == .image,
           let url = item.fileURL,
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            Image(systemName: item.kind == .text ? "text.alignleft" : "doc.fill")
                .font(.system(size: 22))
                .foregroundStyle(item.kind == .text ? Color.crossToolAccent : Color.secondary)
                .frame(width: 52, height: 42)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

struct ShareTextSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("分享文字")
                .font(.title2.weight(.semibold))
            Text("对方打开共享页面后即可复制这段文字或链接。")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
                .frame(minHeight: 150)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.crossToolBorder, lineWidth: 1)
                }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("加入共享") {
                    if model.addText(text) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct QRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let value: String
    let accessCode: String?

    init(value: String, accessCode: String? = nil) {
        self.value = value
        self.accessCode = accessCode
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("扫描二维码访问")
                .font(.title2.weight(.semibold))
            if let image = makeQRCode() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let accessCode {
                Text("访问码：\(accessCode)")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
            }
            Text("请确保设备连接到同一局域网")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360)
    }

    private func makeQRCode() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct NoticeToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThickMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
    }
}
