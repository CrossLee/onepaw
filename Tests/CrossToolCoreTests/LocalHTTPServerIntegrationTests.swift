import Foundation
import Testing
@testable import CrossToolCore

@Test
func liveHTTPServerCompletesBrowserFlow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("crosstool-live-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))
    let source = root.appendingPathComponent("shared.txt")
    let sharedBytes = Data("real network download".utf8)
    try sharedBytes.write(to: source)
    let shared = try store.addSharedFile(at: source)

    let token = "integration-secret"
    let port = UInt16.random(in: 20_000...45_000)
    let router = HTTPRouter(
        store: store,
        sessionToken: token,
        indexHTML: Data("<html>integration</html>".utf8)
    )
    let server = LocalHTTPServer(router: router, port: port)
    try server.start()
    defer { server.stop() }
    let browserA = URLSession(configuration: .ephemeral)
    let browserB = URLSession(configuration: .ephemeral)
    defer {
        browserA.invalidateAndCancel()
        browserB.invalidateAndCancel()
    }

    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    try await waitUntilReady(base: base, token: token)

    let listURL = try #require(URL(string: "\(base.absoluteString)/api/items?token=\(token)"))
    let (listData, listResponse) = try await browserA.data(from: listURL)
    #expect((listResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(data: listData, encoding: .utf8)?.contains("shared.txt") == true)

    let downloadURL = try #require(URL(string: "\(base.absoluteString)/download/\(shared.id)?token=\(token)"))
    let (downloadData, downloadResponse) = try await browserB.data(from: downloadURL)
    #expect((downloadResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(downloadData == sharedBytes)

    let textURL = try #require(URL(string: "\(base.absoluteString)/api/text?token=\(token)"))
    var textRequest = URLRequest(url: textURL)
    textRequest.httpMethod = "POST"
    textRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    textRequest.httpBody = try JSONSerialization.data(withJSONObject: ["text": "真实网络文字"])
    let (_, textResponse) = try await browserA.data(for: textRequest)
    #expect((textResponse as? HTTPURLResponse)?.statusCode == 201)

    let boundary = "URLSessionBoundary"
    var uploadBody = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"live-upload.txt\"\r\nContent-Type: text/plain\r\n\r\n".utf8)
    uploadBody.append(Data("real upload".utf8))
    uploadBody.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let uploadURL = try #require(URL(string: "\(base.absoluteString)/api/upload?token=\(token)"))
    var uploadRequest = URLRequest(url: uploadURL)
    uploadRequest.httpMethod = "POST"
    uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    uploadRequest.httpBody = uploadBody
    let (_, uploadResponse) = try await browserA.data(for: uploadRequest)
    #expect((uploadResponse as? HTTPURLResponse)?.statusCode == 201)

    let received = store.incomingSnapshot()
    #expect(received.contains(where: { $0.detail == "真实网络文字" }))
    let uploaded = try #require(received.first(where: { $0.title == "live-upload.txt" }))
    #expect(try Data(contentsOf: #require(uploaded.fileURL)) == Data("real upload".utf8))

    let (updatedListData, updatedListResponse) = try await browserB.data(from: listURL)
    #expect((updatedListResponse as? HTTPURLResponse)?.statusCode == 200)
    let updatedListText = try #require(String(data: updatedListData, encoding: .utf8))
    #expect(updatedListText.contains("live-upload.txt"))
    #expect(updatedListText.contains("真实网络文字"))
    #expect(updatedListText.contains("\"source\":\"browser\""))

    let uploadedDownloadURL = try #require(
        URL(string: "\(base.absoluteString)/download/\(uploaded.id)?token=\(token)")
    )
    let (uploadedDownloadData, uploadedDownloadResponse) = try await browserB.data(from: uploadedDownloadURL)
    #expect((uploadedDownloadResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(uploadedDownloadData == Data("real upload".utf8))

    let forbiddenURL = try #require(URL(string: "\(base.absoluteString)/api/items"))
    let (_, forbiddenResponse) = try await URLSession.shared.data(from: forbiddenURL)
    #expect((forbiddenResponse as? HTTPURLResponse)?.statusCode == 403)

    let publicItemCountBeforeRotation = store.publicSnapshot().count
    router.updateSessionToken("class2026")

    let (_, staleListResponse) = try await browserA.data(from: listURL)
    #expect((staleListResponse as? HTTPURLResponse)?.statusCode == 403)
    let (_, staleDownloadResponse) = try await browserB.data(from: downloadURL)
    #expect((staleDownloadResponse as? HTTPURLResponse)?.statusCode == 403)

    let rotatedListURL = try #require(
        URL(string: "\(base.absoluteString)/api/items?token=class2026")
    )
    let (rotatedListData, rotatedListResponse) = try await browserA.data(from: rotatedListURL)
    #expect((rotatedListResponse as? HTTPURLResponse)?.statusCode == 200)
    let rotatedListText = try #require(String(data: rotatedListData, encoding: .utf8))
    #expect(rotatedListText.contains("shared.txt"))
    #expect(rotatedListText.contains("live-upload.txt"))
    #expect(rotatedListText.contains("token=class2026"))

    let rotatedDownloadURL = try #require(
        URL(string: "\(base.absoluteString)/download/\(shared.id)?token=class2026")
    )
    let (rotatedDownloadData, rotatedDownloadResponse) = try await browserB.data(
        from: rotatedDownloadURL
    )
    #expect((rotatedDownloadResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(rotatedDownloadData == sharedBytes)
    #expect(store.publicSnapshot().count == publicItemCountBeforeRotation)
}

private func waitUntilReady(base: URL, token: String) async throws {
    let healthURL = try #require(URL(string: "\(base.absoluteString)/api/health?token=\(token)"))
    for _ in 0..<80 {
        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
        } catch {
            // The listener transitions to ready asynchronously.
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("本地 HTTP 服务未在预期时间内启动")
}
