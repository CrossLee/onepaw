import CrossToolCore
import Foundation
import SwiftUI

struct LoadedShareAccessCode: Equatable {
    let value: String
    let usesCustomValue: Bool
}

enum ShareAccessCodePreferences {
    static let defaultsKey = "sharing.customAccessCode.v1"

    static func load(
        from defaults: UserDefaults,
        makeRandom: () -> String = { ShareAccessCode.makeRandom() }
    ) -> LoadedShareAccessCode {
        guard let storedValue = defaults.string(forKey: defaultsKey) else {
            return LoadedShareAccessCode(value: makeRandom(), usesCustomValue: false)
        }

        do {
            let normalizedValue = try ShareAccessCode.normalized(storedValue)
            if normalizedValue != storedValue {
                defaults.set(normalizedValue, forKey: defaultsKey)
            }
            return LoadedShareAccessCode(value: normalizedValue, usesCustomValue: true)
        } catch {
            defaults.removeObject(forKey: defaultsKey)
            return LoadedShareAccessCode(value: makeRandom(), usesCustomValue: false)
        }
    }

    @discardableResult
    static func saveCustom(
        _ rawValue: String,
        to defaults: UserDefaults
    ) throws -> String {
        let normalizedValue = try ShareAccessCode.normalized(rawValue)
        defaults.set(normalizedValue, forKey: defaultsKey)
        return normalizedValue
    }

    static func clearCustom(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

struct ShareAccessCodeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var draft: String
    @State private var validationMessage: String?

    init(accessCode: String) {
        _draft = State(initialValue: accessCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("修改共享访问码")
                    .font(.title2.weight(.semibold))
                Text("访问码会显示在共享链接和二维码中，用来阻止不知道链接的人访问。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("访问码")
                    .font(.headline)
                TextField("例如 class2026", text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .onChange(of: draft) { _, _ in
                        validationMessage = nil
                    }
                Text("支持 6–24 位英文字母、数字、- 和 _；区分大小写，建议至少 8 位并避免连续数字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text("访问码更换后，旧链接和旧二维码会立即失效；共享中的文件和当前端口不会改变。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Label("访问码会明文出现在链接、二维码和浏览器记录中，不是加密密码，请勿复用重要密码。", systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.orange)

            HStack {
                Button(model.usesCustomShareAccessCode ? "恢复随机访问码" : "换一个随机访问码") {
                    model.resetShareAccessCode()
                    dismiss()
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并更新链接", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func save() {
        do {
            try model.applyShareAccessCode(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
