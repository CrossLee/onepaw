import AppKit
import Foundation
import SwiftUI
@preconcurrency import Translation

/// The standalone text-translation destination used by OnePaw's main window.
///
/// Apple introduced custom `TranslationSession` workflows on macOS 15. OnePaw
/// still supports macOS 14, so the public page stays available there and shows
/// an explicit compatibility state instead of silently sending text to a cloud
/// service.
struct TextTranslationPage: View {
    @EnvironmentObject private var appModel: AppModel

    @ViewBuilder
    var body: some View {
        if #available(macOS 15.0, *) {
            TranslationAvailablePage(
                launchRequest: appModel.textTranslationLaunchRequest,
                consumeLaunchRequest: appModel.consumeTextTranslationLaunchRequest
            )
        } else {
            TranslationUnavailablePage(
                launchRequest: appModel.textTranslationLaunchRequest,
                consumeLaunchRequest: appModel.consumeTextTranslationLaunchRequest
            )
        }
    }
}

private struct TranslationUnavailablePage: View {
    let launchRequest: TextTranslationLaunchRequest?
    let consumeLaunchRequest: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "翻译",
                    subtitle: "使用系统语言模型在本机翻译文本"
                )

                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(Color.crossToolAccent)
                    Text("翻译需要 macOS 15 或更高版本")
                        .font(.title3.weight(.semibold))
                    Text("一爪不会在旧系统上改用云端翻译。升级 macOS 后即可使用系统提供的本地翻译能力。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
                .padding(.horizontal, 28)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.crossToolBorder, lineWidth: 1)
                }
            }
            .padding(30)
        }
        .task(id: launchRequest?.id) {
            if let requestID = launchRequest?.id {
                consumeLaunchRequest(requestID)
            }
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationAvailablePage: View {
    let launchRequest: TextTranslationLaunchRequest?
    let consumeLaunchRequest: (UUID) -> Void

    @StateObject private var model = TranslationFeatureModel()
    @State private var configuration: TranslationSession.Configuration?
    @State private var showingClearHistoryConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "翻译",
                    subtitle: "使用系统语言模型在本机翻译文本"
                )

                privacyBanner
                languageBar
                editorColumns

                if let feedback = model.feedback {
                    feedbackBanner(feedback)
                }

                historySection
            }
            .padding(30)
        }
        .task(id: launchRequest?.id) {
            guard let launchRequest else {
                await model.loadSupportedLanguagesIfNeeded()
                return
            }

            switch launchRequest.payload {
            case .message:
                // Permission and compatibility feedback should appear without
                // waiting for the system language catalogue to load.
                await handleLaunchRequest(launchRequest)
                await model.loadSupportedLanguagesIfNeeded()
            case .translate(let text, _):
                // Populate the editor synchronously when the page mounts. The
                // language lookup and automatic translation can then continue
                // in the background without showing a misleading empty box.
                model.stageQuickTranslationInput(text)
                await model.loadSupportedLanguagesIfNeeded()
                guard !Task.isCancelled else { return }
                await handleLaunchRequest(launchRequest)
            }
        }
        .translationTask(configuration) { session in
            guard let request = model.currentRequest() else { return }

            do {
                model.markPreparing(requestID: request.id)
                // Automatic source detection needs the actual input text. A
                // source-less prepare call has nothing to identify and can
                // fail before translate(_:) gets a chance to inspect it.
                if session.sourceLanguage != nil {
                    try await session.prepareTranslation()
                }
                try Task.checkCancellation()
                guard model.isCurrentRequest(request.id) else { return }

                model.markTranslating(requestID: request.id)
                let response = try await session.translate(request.text)
                guard model.isCurrentRequest(request.id) else { return }
                model.complete(response, requestID: request.id)
            } catch is CancellationError {
                model.cancel(requestID: request.id)
            } catch {
                let message = translationErrorMessage(error)
                model.fail(message: message, requestID: request.id)
            }
        }
        .confirmationDialog(
            "清空全部翻译历史？",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部历史", role: .destructive) {
                model.clearHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会删除保存在本机的翻译记录，无法撤销。")
        }
    }

    private var privacyBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.crossToolAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("文字内容仅在这台 Mac 上处理")
                    .font(.subheadline.weight(.semibold))
                Text("首次使用某个语言组合时，macOS 可能会请求下载对应语言模型。翻译结果不会自动加入课堂共享区。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("快捷翻译优先通过辅助功能读取选中文字；少数 App 不提供选中文字时，会短暂执行复制并尽力恢复原剪贴板。密码框和安全输入不会读取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.crossToolAccent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var languageBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("源语言", selection: sourceLanguageBinding) {
                    Text("自动检测")
                        .tag(nil as Locale.Language?)
                    ForEach(model.supportedLanguages, id: \.self) { language in
                        Text(model.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(model.isLoadingLanguages || model.supportedLanguages.isEmpty)
                .accessibilityLabel("源语言")

                Button {
                    model.exchangeLanguagesAndText()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canExchange)
                .help(model.canExchange ? "交换语言和文字" : "自动识别完成后即可交换")

                Picker("目标语言", selection: targetLanguageBinding) {
                    if model.targetLanguage == nil {
                        Text(model.isLoadingLanguages ? "正在载入语言…" : "选择目标语言")
                            .tag(nil as Locale.Language?)
                    }
                    ForEach(model.supportedLanguages, id: \.self) { language in
                        Text(model.displayName(for: language))
                            .tag(Optional(language))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(model.isLoadingLanguages || model.supportedLanguages.isEmpty)
                .accessibilityLabel("目标语言")
            }

            if let message = model.pairValidationMessage {
                Label(message, systemImage: model.pairValidationSystemImage)
                    .font(.caption)
                    .foregroundStyle(model.pairValidationColor)
            }

            if model.canRetryLanguageLoading {
                Button("重新载入翻译语言", systemImage: "arrow.clockwise") {
                    Task {
                        await model.loadSupportedLanguagesIfNeeded()
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }

    private var editorColumns: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                translationEditorCard(
                    title: sourceTitle,
                    text: inputTextBinding,
                    placeholder: "输入或粘贴要翻译的文字",
                    isEditable: true,
                    trailingActions: AnyView(
                        HStack(spacing: 8) {
                            Button("粘贴", systemImage: "doc.on.clipboard") {
                                model.pasteFromClipboard()
                            }
                            Button("清空", systemImage: "xmark") {
                                model.clearInput()
                            }
                            .disabled(model.inputText.isEmpty)
                        }
                        .buttonStyle(.borderless)
                    )
                )

                translationEditorCard(
                    title: targetTitle,
                    text: .constant(model.outputText),
                    placeholder: model.isWorking ? "正在准备翻译…" : "翻译结果会显示在这里",
                    isEditable: false,
                    trailingActions: AnyView(
                        Button("复制结果", systemImage: "doc.on.doc") {
                            model.copyResult()
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.outputText.isEmpty)
                    )
                )
            }

            Button(action: beginTranslation) {
                HStack(spacing: 8) {
                    if model.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.primaryActionTitle)
                }
                .frame(minWidth: 112)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canTranslate)
        }
    }

    private func translationEditorCard(
        title: String,
        text: Binding<String>,
        placeholder: String,
        isEditable: Bool,
        trailingActions: AnyView
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                trailingActions
            }

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }

                TextEditor(text: text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(1)
                    .disabled(!isEditable)
                    .accessibilityLabel(title)
            }
            .frame(minHeight: 210)
            .padding(8)
            .background(Color.secondary.opacity(isEditable ? 0.035 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }

            HStack {
                if isEditable {
                    Text("⌘↩ 翻译")
                } else if let detected = model.detectedSourceLanguage {
                    Text("检测为：\(model.displayName(for: detected))")
                } else {
                    Text("系统自动识别源语言")
                }
                Spacer()
                Text("\(text.wrappedValue.count) 字符")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }

    private func feedbackBanner(_ feedback: TranslationFeatureFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.systemImage)
                .foregroundStyle(feedback.color)
            Text(feedback.message)
                .font(.subheadline)
            Spacer(minLength: 8)
            Button {
                model.dismissFeedback()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(feedback.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var historySection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近翻译")
                    .font(.headline)
                Text("\(model.history.count)/\(TranslationFeatureModel.maximumHistoryCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空", systemImage: "trash", role: .destructive) {
                    showingClearHistoryConfirmation = true
                }
                .disabled(model.history.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if model.history.isEmpty {
                EmptyContentRow(
                    systemImage: "clock.arrow.circlepath",
                    text: "完成的翻译会仅保存在这台 Mac 上"
                )
            } else {
                ForEach(model.history) { item in
                    TranslationHistoryRow(
                        item: item,
                        sourceName: model.displayName(forIdentifier: item.sourceLanguageIdentifier),
                        targetName: model.displayName(forIdentifier: item.targetLanguageIdentifier),
                        restore: { model.restore(item) },
                        copy: { model.copy(item.translatedText) },
                        delete: { model.deleteHistoryItem(item.id) }
                    )

                    if item.id != model.history.last?.id {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }

    private var sourceTitle: String {
        if let sourceLanguage = model.sourceLanguage {
            return model.displayName(for: sourceLanguage)
        }
        if let detectedSourceLanguage = model.detectedSourceLanguage {
            return "自动检测 · \(model.displayName(for: detectedSourceLanguage))"
        }
        return "自动检测"
    }

    private var targetTitle: String {
        guard let targetLanguage = model.targetLanguage else { return "翻译结果" }
        return model.displayName(for: targetLanguage)
    }

    private var sourceLanguageBinding: Binding<Locale.Language?> {
        Binding(
            get: { model.sourceLanguage },
            set: { model.selectSourceLanguage($0) }
        )
    }

    private var targetLanguageBinding: Binding<Locale.Language?> {
        Binding(
            get: { model.targetLanguage },
            set: { model.selectTargetLanguage($0) }
        )
    }

    private var inputTextBinding: Binding<String> {
        Binding(
            get: { model.inputText },
            set: { model.updateInput($0) }
        )
    }

    private func beginTranslation() {
        guard model.beginTranslation() else { return }
        if configuration?.source == model.sourceLanguage,
           configuration?.target == model.targetLanguage {
            // Reuse and invalidate the mounted configuration so its internal
            // version advances for a second request using the same pair.
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(
                source: model.sourceLanguage,
                target: model.targetLanguage
            )
        }
    }

    private func handleLaunchRequest(_ request: TextTranslationLaunchRequest) async {
        switch request.payload {
        case .message(let message):
            model.showQuickTranslationMessage(message)
            consumeLaunchRequest(request.id)
        case .translate(let text, let direction):
            let isReady = await model.prepareQuickTranslation(
                text: text,
                direction: direction
            )
            guard !Task.isCancelled else { return }
            if isReady {
                beginTranslation()
            }
            consumeLaunchRequest(request.id)
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationHistoryRow: View {
    let item: TranslationHistoryItem
    let sourceName: String
    let targetName: String
    let restore: () -> Void
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: restore) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(sourceName) → \(targetName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.crossToolAccent)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.sourceText)
                        .lineLimit(1)
                    Text(item.translatedText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复这条翻译")

            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制译文")
            .accessibilityLabel("复制译文")

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除记录")
            .accessibilityLabel("删除翻译记录")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct TranslationHistoryItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let sourceLanguageIdentifier: String
    let targetLanguageIdentifier: String
    let createdAt: Date
}

struct TranslationRequestSnapshot: Sendable {
    let id: UUID
    let text: String
}

struct TranslationLanguagePair: Equatable, Hashable, Sendable {
    let sourceIdentifier: String
    let targetIdentifier: String

    init(source: Locale.Language, target: Locale.Language) {
        sourceIdentifier = source.minimalIdentifier
        targetIdentifier = target.minimalIdentifier
    }
}

enum TranslationPairAvailability: Equatable, Sendable {
    case supported
    case unsupported
}

enum TranslationPairValidationStatus: Equatable, Sendable {
    case notRequired
    case checking
    case supported
    case unsupported
    case sameLanguage
}

/// Pure latest-request-wins state for asynchronous language-pair checks.
/// Stable results are cached by the complete locale-language identifiers; no
/// language-code-only approximation is used.
struct TranslationPairValidationState: Equatable, Sendable {
    private(set) var pair: TranslationLanguagePair?
    private(set) var status: TranslationPairValidationStatus = .notRequired
    private(set) var activeRequestID: UUID?
    private(set) var cachedAvailability: [TranslationLanguagePair: TranslationPairAvailability] = [:]

    mutating func beginChecking(_ pair: TranslationLanguagePair) -> UUID? {
        self.pair = pair
        if let cached = cachedAvailability[pair] {
            status = cached.validationStatus
            activeRequestID = nil
            return nil
        }

        let requestID = UUID()
        status = .checking
        activeRequestID = requestID
        return requestID
    }

    @discardableResult
    mutating func apply(
        _ availability: TranslationPairAvailability,
        requestID: UUID
    ) -> Bool {
        guard activeRequestID == requestID, let pair else { return false }
        cachedAvailability[pair] = availability
        status = availability.validationStatus
        activeRequestID = nil
        return true
    }

    mutating func markNotRequired() {
        pair = nil
        status = .notRequired
        activeRequestID = nil
    }

    mutating func markSameLanguage(_ pair: TranslationLanguagePair) {
        self.pair = pair
        status = .sameLanguage
        activeRequestID = nil
    }
}

private extension TranslationPairAvailability {
    var validationStatus: TranslationPairValidationStatus {
        switch self {
        case .supported: return .supported
        case .unsupported: return .unsupported
        }
    }
}

typealias TranslationSupportedLanguageLoader = @MainActor () async -> [Locale.Language]
typealias TranslationPairAvailabilityLoader = @MainActor (
    Locale.Language,
    Locale.Language
) async -> TranslationPairAvailability

@available(macOS 15.0, *)
@MainActor
private func systemSupportedTranslationLanguages() async -> [Locale.Language] {
    await LanguageAvailability().supportedLanguages
}

@available(macOS 15.0, *)
@MainActor
private func systemTranslationPairAvailability(
    source: Locale.Language,
    target: Locale.Language
) async -> TranslationPairAvailability {
    let status = await LanguageAvailability().status(from: source, to: target)
    switch status {
    case .installed, .supported:
        return .supported
    case .unsupported:
        return .unsupported
    @unknown default:
        return .unsupported
    }
}

enum TranslationFeatureActivity: Equatable {
    case idle
    case preparing
    case translating
}

struct TranslationFeatureFeedback: Equatable {
    enum Kind: Equatable {
        case information
        case success
        case error
    }

    let kind: Kind
    let message: String

    var systemImage: String {
        switch kind {
        case .information: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch kind {
        case .information: return .crossToolAccent
        case .success: return .green
        case .error: return .red
        }
    }
}

@available(macOS 15.0, *)
@MainActor
final class TranslationFeatureModel: ObservableObject {
    static let maximumHistoryCount = 100

    @Published private(set) var supportedLanguages: [Locale.Language] = []
    @Published private(set) var isLoadingLanguages = false
    @Published private(set) var sourceLanguage: Locale.Language?
    @Published private(set) var targetLanguage: Locale.Language?
    @Published private(set) var detectedSourceLanguage: Locale.Language?
    @Published private(set) var inputText = ""
    @Published private(set) var outputText = ""
    @Published private(set) var activity: TranslationFeatureActivity = .idle
    @Published private(set) var feedback: TranslationFeatureFeedback?
    @Published private(set) var history: [TranslationHistoryItem]
    @Published private(set) var pairValidationState = TranslationPairValidationState()

    private static let historyDefaultsKey = "translation.history.v1"
    private static let sourceLanguageDefaultsKey = "translation.sourceLanguage.v1"
    private static let targetLanguageDefaultsKey = "translation.targetLanguage.v1"
    private static let automaticSourceIdentifier = "automatic"

    private let defaults: UserDefaults
    private let supportedLanguageLoader: TranslationSupportedLanguageLoader
    private let pairAvailabilityLoader: TranslationPairAvailabilityLoader
    private var pendingRequest: TranslationRequestSnapshot?
    private var didLoadLanguages = false
    private var pairValidationTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        supportedLanguageLoader: @escaping TranslationSupportedLanguageLoader = systemSupportedTranslationLanguages,
        pairAvailabilityLoader: @escaping TranslationPairAvailabilityLoader = systemTranslationPairAvailability
    ) {
        self.defaults = defaults
        self.supportedLanguageLoader = supportedLanguageLoader
        self.pairAvailabilityLoader = pairAvailabilityLoader
        history = Self.loadHistory(from: defaults)
    }

    var isWorking: Bool {
        activity != .idle
    }

    var canTranslate: Bool {
        guard !isWorking,
              targetLanguage != nil,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if sourceLanguage != nil {
            return pairValidationState.status == .supported
        }
        return true
    }

    var canRetryLanguageLoading: Bool {
        !didLoadLanguages && !isLoadingLanguages && supportedLanguages.isEmpty
    }

    var pairValidationMessage: String? {
        switch pairValidationState.status {
        case .checking:
            return "正在检查这组语言是否受 macOS 翻译支持…"
        case .unsupported:
            return "macOS 暂不支持这组语言之间的翻译，请更换源语言或目标语言。"
        case .sameLanguage:
            return "源语言和目标语言不能相同。"
        case .notRequired, .supported:
            return nil
        }
    }

    var pairValidationSystemImage: String {
        pairValidationState.status == .checking
            ? "arrow.triangle.2.circlepath"
            : "exclamationmark.triangle.fill"
    }

    var pairValidationColor: Color {
        pairValidationState.status == .checking ? .secondary : .red
    }

    var canExchange: Bool {
        targetLanguage != nil && (sourceLanguage != nil || detectedSourceLanguage != nil)
    }

    var primaryActionTitle: String {
        switch activity {
        case .idle: return "翻译"
        case .preparing: return "正在准备语言…"
        case .translating: return "正在翻译…"
        }
    }

    func loadSupportedLanguagesIfNeeded() async {
        if isLoadingLanguages {
            while isLoadingLanguages && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            return
        }
        guard !didLoadLanguages else { return }
        didLoadLanguages = true
        isLoadingLanguages = true
        feedback = nil

        let available = await supportedLanguageLoader()
        supportedLanguages = available.sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
        isLoadingLanguages = false

        if supportedLanguages.isEmpty {
            didLoadLanguages = false
            pairValidationTask?.cancel()
            pairValidationTask = nil
            pairValidationState.markNotRequired()
            feedback = TranslationFeatureFeedback(
                kind: .error,
                message: "未能载入系统翻译语言，请重试。"
            )
            return
        }

        restoreLanguageSelections()
        refreshPairValidation()
    }

    func displayName(for language: Locale.Language) -> String {
        displayName(forIdentifier: language.minimalIdentifier)
    }

    func displayName(forIdentifier identifier: String) -> String {
        Locale.autoupdatingCurrent.localizedString(forIdentifier: identifier)
            ?? identifier
    }

    func selectSourceLanguage(_ language: Locale.Language?) {
        sourceLanguage = language
        defaults.set(
            language?.minimalIdentifier ?? Self.automaticSourceIdentifier,
            forKey: Self.sourceLanguageDefaultsKey
        )
        invalidateResult()
        refreshPairValidation()
    }

    func selectTargetLanguage(_ language: Locale.Language?) {
        targetLanguage = language
        if let language {
            defaults.set(language.minimalIdentifier, forKey: Self.targetLanguageDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.targetLanguageDefaultsKey)
        }
        invalidateResult()
        refreshPairValidation()
    }

    func updateInput(_ text: String) {
        guard inputText != text else { return }
        inputText = text
        invalidateResult()
    }

    func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.isEmpty else {
            feedback = TranslationFeatureFeedback(
                kind: .information,
                message: "剪贴板中没有可翻译的文字。"
            )
            return
        }
        inputText = pasted
        invalidateResult()
    }

    func clearInput() {
        inputText = ""
        invalidateResult()
        feedback = nil
    }

    func showQuickTranslationMessage(_ message: String) {
        feedback = TranslationFeatureFeedback(kind: .information, message: message)
    }

    func stageQuickTranslationInput(_ text: String) {
        inputText = text
        outputText = ""
        detectedSourceLanguage = nil
        invalidatePendingRequest()
        feedback = nil
    }

    func prepareQuickTranslation(
        text: String,
        direction: QuickTranslationDirection
    ) async -> Bool {
        guard !supportedLanguages.isEmpty else {
            feedback = TranslationFeatureFeedback(
                kind: .error,
                message: "系统翻译语言尚未载入，请点击“重新载入翻译语言”后重试。"
            )
            return false
        }

        guard let source = language(matching: direction.sourceLanguageIdentifier),
              let target = language(matching: direction.targetLanguageIdentifier) else {
            feedback = TranslationFeatureFeedback(
                kind: .error,
                message: "macOS 当前没有可用的中英翻译语言，请联网安装语言模型后重试。"
            )
            return false
        }

        stageQuickTranslationInput(text)
        sourceLanguage = source
        targetLanguage = target
        defaults.set(source.minimalIdentifier, forKey: Self.sourceLanguageDefaultsKey)
        defaults.set(target.minimalIdentifier, forKey: Self.targetLanguageDefaultsKey)
        feedback = nil
        refreshPairValidation()

        await waitForCurrentPairValidation()
        guard !Task.isCancelled else { return false }
        guard pairValidationState.status == .supported else {
            feedback = TranslationFeatureFeedback(
                kind: pairValidationState.status == .unsupported ? .error : .information,
                message: pairValidationMessage ?? "正在检查中英翻译语言是否可用，请稍后重试。"
            )
            return false
        }
        return true
    }

    func beginTranslation() -> Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feedback = TranslationFeatureFeedback(kind: .information, message: "请先输入要翻译的文字。")
            return false
        }
        guard let targetLanguage else {
            feedback = TranslationFeatureFeedback(kind: .information, message: "请选择目标语言。")
            return false
        }
        if let sourceLanguage, sourceLanguage.isEquivalent(to: targetLanguage) {
            feedback = TranslationFeatureFeedback(kind: .information, message: "源语言和目标语言不能相同。")
            return false
        }
        if sourceLanguage != nil, pairValidationState.status != .supported {
            let message = pairValidationMessage ?? "正在检查这组语言是否受 macOS 翻译支持。"
            feedback = TranslationFeatureFeedback(
                kind: pairValidationState.status == .unsupported ? .error : .information,
                message: message
            )
            return false
        }

        let request = TranslationRequestSnapshot(id: UUID(), text: inputText)
        pendingRequest = request
        activity = .preparing
        feedback = nil
        return true
    }

    func currentRequest() -> TranslationRequestSnapshot? {
        pendingRequest
    }

    func isCurrentRequest(_ requestID: UUID) -> Bool {
        pendingRequest?.id == requestID
    }

    func waitForCurrentPairValidation() async {
        await pairValidationTask?.value
    }

    func markPreparing(requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        activity = .preparing
    }

    func markTranslating(requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        activity = .translating
    }

    func complete(_ response: TranslationSession.Response, requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }

        outputText = response.targetText
        detectedSourceLanguage = response.sourceLanguage
        activity = .idle
        pendingRequest = nil
        feedback = nil

        let item = TranslationHistoryItem(
            id: UUID(),
            sourceText: response.sourceText,
            translatedText: response.targetText,
            sourceLanguageIdentifier: response.sourceLanguage.minimalIdentifier,
            targetLanguageIdentifier: response.targetLanguage.minimalIdentifier,
            createdAt: Date()
        )
        history.insert(item, at: 0)
        if history.count > Self.maximumHistoryCount {
            history.removeLast(history.count - Self.maximumHistoryCount)
        }
        persistHistory()
    }

    func cancel(requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        activity = .idle
        pendingRequest = nil
    }

    func fail(message: String, requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        activity = .idle
        pendingRequest = nil
        feedback = TranslationFeatureFeedback(kind: .error, message: message)
    }

    func exchangeLanguagesAndText() {
        guard let oldTarget = targetLanguage,
              let oldSource = sourceLanguage ?? detectedSourceLanguage else { return }

        sourceLanguage = oldTarget
        targetLanguage = oldSource
        defaults.set(oldTarget.minimalIdentifier, forKey: Self.sourceLanguageDefaultsKey)
        defaults.set(oldSource.minimalIdentifier, forKey: Self.targetLanguageDefaultsKey)

        if !outputText.isEmpty {
            let oldInput = inputText
            inputText = outputText
            outputText = oldInput
            detectedSourceLanguage = oldTarget
        } else {
            detectedSourceLanguage = nil
        }

        invalidatePendingRequest()
        feedback = nil
        refreshPairValidation()
    }

    func copyResult() {
        guard !outputText.isEmpty else { return }
        copy(outputText)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = TranslationFeatureFeedback(kind: .success, message: "翻译结果已复制。")
    }

    func restore(_ item: TranslationHistoryItem) {
        inputText = item.sourceText
        outputText = item.translatedText
        sourceLanguage = language(matching: item.sourceLanguageIdentifier)
            ?? Locale.Language(identifier: item.sourceLanguageIdentifier)
        targetLanguage = language(matching: item.targetLanguageIdentifier)
            ?? Locale.Language(identifier: item.targetLanguageIdentifier)
        detectedSourceLanguage = sourceLanguage
        invalidatePendingRequest()
        feedback = nil
        refreshPairValidation()
    }

    func deleteHistoryItem(_ id: UUID) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    func dismissFeedback() {
        feedback = nil
    }

    private func restoreLanguageSelections() {
        let storedSource = defaults.string(forKey: Self.sourceLanguageDefaultsKey)
        if let storedSource, storedSource != Self.automaticSourceIdentifier {
            sourceLanguage = language(matching: storedSource)
        } else {
            sourceLanguage = nil
        }

        if let storedTarget = defaults.string(forKey: Self.targetLanguageDefaultsKey),
           let restored = language(matching: storedTarget) {
            targetLanguage = restored
            return
        }

        let interfaceLanguage = Locale.preferredLanguages.first.map {
            Locale.Language(identifier: $0)
        } ?? Locale.autoupdatingCurrent.language
        let simplifiedChinese = Locale.Language(identifier: "zh-Hans")
        let english = Locale.Language(identifier: "en")
        // On a Chinese Mac, English is the useful first target for automatic
        // source detection; on other systems, prefer Simplified Chinese.
        let preferredTargets = interfaceLanguage.isEquivalent(to: simplifiedChinese)
            ? [english, simplifiedChinese]
            : [simplifiedChinese, english]
        let preferredCandidates = preferredTargets + Locale.Language.systemLanguages
        targetLanguage = preferredCandidates.lazy.compactMap { candidate in
            self.supportedLanguages.first { $0.isEquivalent(to: candidate) }
        }.first ?? supportedLanguages.first

        if let targetLanguage {
            defaults.set(targetLanguage.minimalIdentifier, forKey: Self.targetLanguageDefaultsKey)
        }
    }

    private func language(matching identifier: String) -> Locale.Language? {
        let candidate = Locale.Language(identifier: identifier)
        if let exact = supportedLanguages.first(where: {
            $0.minimalIdentifier == identifier || $0.isEquivalent(to: candidate)
        }) {
            return exact
        }

        let candidateLanguageCode = Locale(identifier: identifier).language.languageCode?.identifier
        return supportedLanguages.first { language in
            guard let candidateLanguageCode else { return false }
            let supportedLanguageCode = Locale(identifier: language.minimalIdentifier)
                .language.languageCode?.identifier
            if candidateLanguageCode == "zh" {
                let requestedScript = Locale(identifier: identifier).language.script?.identifier
                let supportedScript = Locale(identifier: language.minimalIdentifier).language.script?.identifier
                return supportedLanguageCode == candidateLanguageCode
                    && (requestedScript == nil || requestedScript == supportedScript)
            }
            return supportedLanguageCode == candidateLanguageCode
        }
    }

    private func refreshPairValidation() {
        pairValidationTask?.cancel()
        pairValidationTask = nil

        guard let sourceLanguage, let targetLanguage else {
            pairValidationState.markNotRequired()
            return
        }

        let pair = TranslationLanguagePair(source: sourceLanguage, target: targetLanguage)
        guard !sourceLanguage.isEquivalent(to: targetLanguage) else {
            pairValidationState.markSameLanguage(pair)
            return
        }

        guard let requestID = pairValidationState.beginChecking(pair) else {
            return
        }

        let loader = pairAvailabilityLoader
        pairValidationTask = Task { @MainActor [weak self] in
            let availability = await loader(sourceLanguage, targetLanguage)
            guard !Task.isCancelled, let self else { return }
            self.pairValidationState.apply(availability, requestID: requestID)
        }
    }

    private func invalidateResult() {
        outputText = ""
        detectedSourceLanguage = nil
        feedback = nil
        invalidatePendingRequest()
    }

    private func invalidatePendingRequest() {
        pendingRequest = nil
        activity = .idle
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.historyDefaultsKey)
    }

    private static func loadHistory(from defaults: UserDefaults) -> [TranslationHistoryItem] {
        guard let data = defaults.data(forKey: historyDefaultsKey),
              let decoded = try? JSONDecoder().decode([TranslationHistoryItem].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(maximumHistoryCount))
    }
}

@available(macOS 15.0, *)
private func translationErrorMessage(_ error: any Error) -> String {
    if TranslationError.unsupportedSourceLanguage ~= error {
        return "系统不支持识别或翻译当前源语言，请手动选择其他源语言。"
    }
    if TranslationError.unsupportedTargetLanguage ~= error {
        return "系统不支持当前目标语言，请选择其他目标语言。"
    }
    if TranslationError.unsupportedLanguagePairing ~= error {
        return "系统暂不支持这组语言之间的翻译，请更换语言组合。"
    }
    if TranslationError.unableToIdentifyLanguage ~= error {
        return "无法识别输入文字的语言，请手动选择源语言后重试。"
    }
    if TranslationError.nothingToTranslate ~= error {
        return "没有可翻译的文字，请检查输入内容。"
    }
    if #available(macOS 26.0, *) {
        if TranslationError.notInstalled ~= error {
            return "所需语言模型尚未安装。请联网下载语言模型后重试。"
        }
        if TranslationError.alreadyCancelled ~= error {
            return "翻译任务已取消，请重新尝试。"
        }
    }
    if TranslationError.internalError ~= error {
        return "系统翻译暂时不可用，请稍后重试。"
    }

    let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.isEmpty ? "翻译失败，请稍后重试。" : "翻译失败：\(description)"
}
