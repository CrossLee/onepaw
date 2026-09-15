import Foundation
import Testing
@testable import CrossToolCore

@Test func multipartParserExtractsUnicodeFile() throws {
    let boundary = "CrossToolBoundary"
    let bytes = Data([0, 1, 2, 13, 10, 255])
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"图片.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    #expect(MultipartFormData.boundary(from: "multipart/form-data; boundary=\(boundary)") == boundary)
    let file = MultipartFormData.firstFile(in: body, boundary: boundary)
    #expect(file?.fieldName == "file")
    #expect(file?.filename == "图片.png")
    #expect(file?.contentType == "image/png")
    #expect(file?.data == bytes)
}

@Test func routerRequiresTokenAndCompletesTextUploadDownloadFlow() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))
    let source = root.appendingPathComponent("demo.txt")
    let sourceData = Data("download me".utf8)
    try sourceData.write(to: source)
    let shared = try store.addSharedFile(at: source)

    let router = HTTPRouter(
        store: store,
        sessionToken: "secret",
        indexHTML: Data("<html>ok</html>".utf8)
    )

    let forbidden = router.handle(HTTPRequest(method: "GET", target: "/", path: "/"))
    #expect(forbidden.statusCode == 403)

    let index = router.handle(HTTPRequest(
        method: "GET",
        target: "/?token=secret",
        path: "/",
        query: ["token": "secret"]
    ))
    #expect(index.statusCode == 200)

    let list = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=secret",
        path: "/api/items",
        query: ["token": "secret"]
    ))
    #expect(list.statusCode == 200)
    #expect(String(data: list.body, encoding: .utf8)?.contains("demo.txt") == true)

    let download = router.handle(HTTPRequest(
        method: "GET",
        target: "/download/\(shared.id)?token=secret",
        path: "/download/\(shared.id)",
        query: ["token": "secret"]
    ))
    #expect(download.statusCode == 200)
    #expect(download.body == sourceData)

    let ranged = router.handle(HTTPRequest(
        method: "GET",
        target: "/download/\(shared.id)?token=secret",
        path: "/download/\(shared.id)",
        query: ["token": "secret"],
        headers: ["range": "bytes=0-7"]
    ))
    #expect(ranged.statusCode == 206)
    #expect(String(data: ranged.body, encoding: .utf8) == "download")

    let textBody = try JSONSerialization.data(withJSONObject: ["text": "浏览器发来的文字"])
    let textResponse = router.handle(HTTPRequest(
        method: "POST",
        target: "/api/text?token=secret",
        path: "/api/text",
        query: ["token": "secret"],
        headers: ["content-type": "application/json"],
        body: textBody,
        remoteAddress: "192.168.1.8"
    ))
    #expect(textResponse.statusCode == 201)
    #expect(store.incomingSnapshot().first?.detail == "浏览器发来的文字")

    let publicList = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=secret",
        path: "/api/items",
        query: ["token": "secret"]
    ))
    let publicJSON = try #require(
        try JSONSerialization.jsonObject(with: publicList.body) as? [String: Any]
    )
    let publicItems = try #require(publicJSON["items"] as? [[String: Any]])
    let browserText = try #require(publicItems.first(where: { $0["detail"] as? String == "浏览器发来的文字" }))
    #expect(browserText["source"] as? String == "browser")
    #expect(!browserText.keys.contains("downloadURL"))
}

@Test func routerAcceptsMultipartUploadIntoInbox() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))
    let router = HTTPRouter(store: store, sessionToken: "secret", indexHTML: Data())
    let boundary = "UploadBoundary"
    let payload = Data("uploaded payload".utf8)
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"../upload.txt\"\r\nContent-Type: text/plain\r\n\r\n".utf8)
    body.append(payload)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let response = router.handle(HTTPRequest(
        method: "POST",
        target: "/api/upload?token=secret",
        path: "/api/upload",
        query: ["token": "secret"],
        headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
        body: body,
        remoteAddress: "192.168.1.9"
    ))

    #expect(response.statusCode == 201)
    let received = try #require(store.incomingSnapshot().first)
    #expect(received.title == "upload.txt")
    #expect(try Data(contentsOf: #require(received.fileURL)) == payload)

    let list = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=secret",
        path: "/api/items",
        query: ["token": "secret"]
    ))
    let listJSON = try #require(
        try JSONSerialization.jsonObject(with: list.body) as? [String: Any]
    )
    let items = try #require(listJSON["items"] as? [[String: Any]])
    let uploadedItem = try #require(items.first(where: { $0["name"] as? String == "upload.txt" }))
    #expect(uploadedItem["source"] as? String == "browser")
    #expect(uploadedItem["downloadURL"] as? String != nil)

    let download = router.handle(HTTPRequest(
        method: "GET",
        target: "/download/\(received.id)?token=secret",
        path: "/download/\(received.id)",
        query: ["token": "secret"]
    ))
    #expect(download.statusCode == 200)
    #expect(download.body == payload)

    let deleteAttempt = router.handle(HTTPRequest(
        method: "DELETE",
        target: "/download/\(received.id)?token=secret",
        path: "/download/\(received.id)",
        query: ["token": "secret"]
    ))
    #expect(deleteAttempt.statusCode == 405)
    #expect(store.publicItem(id: received.id) != nil)

    store.hideIncomingFromPublic(id: received.id)
    let hiddenDownload = router.handle(HTTPRequest(
        method: "GET",
        target: "/download/\(received.id)?token=secret",
        path: "/download/\(received.id)",
        query: ["token": "secret"]
    ))
    #expect(hiddenDownload.statusCode == 404)
    #expect(store.incomingSnapshot().contains(where: { $0.id == received.id }))
    #expect(FileManager.default.fileExists(atPath: try #require(received.fileURL).path))
}

@Test func routerRotatesSessionTokenWithoutRestartingOrLeakingTheNewToken() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))
    let source = root.appendingPathComponent("rotation.txt")
    try Data("same shared content".utf8).write(to: source)
    _ = try store.addSharedFile(at: source)
    let router = HTTPRouter(
        store: store,
        sessionToken: "oldcode",
        indexHTML: Data("<html>ok</html>".utf8)
    )

    let oldList = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=oldcode",
        path: "/api/items",
        query: ["token": "oldcode"]
    ))
    #expect(oldList.statusCode == 200)
    #expect(String(data: oldList.body, encoding: .utf8)?.contains("token=oldcode") == true)

    router.updateSessionToken("New_code2")

    let rejectedOldList = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=oldcode",
        path: "/api/items",
        query: ["token": "oldcode"]
    ))
    #expect(rejectedOldList.statusCode == 403)
    #expect(String(data: rejectedOldList.body, encoding: .utf8)?.contains("New_code2") == false)

    let newList = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=New_code2",
        path: "/api/items",
        query: ["token": "New_code2"]
    ))
    #expect(newList.statusCode == 200)
    #expect(String(data: newList.body, encoding: .utf8)?.contains("token=New_code2") == true)
    #expect(store.publicSnapshot().count == 1)

    let wrongCase = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/health?token=new_code2",
        path: "/api/health",
        query: ["token": "new_code2"]
    ))
    #expect(wrongCase.statusCode == 403)

    let headerAuthenticated = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/health",
        path: "/api/health",
        headers: ["x-crosstool-token": "New_code2"]
    ))
    #expect(headerAuthenticated.statusCode == 200)
}

@Test func storeChangeHandlerCanRotateTokenWithoutReentrantDeadlock() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))
    let router = HTTPRouter(store: store, sessionToken: "oldcode", indexHTML: Data())
    let requestFinished = DispatchSemaphore(value: 0)
    let responseBox = HTTPResponseBox()

    store.setChangeHandler {
        router.updateSessionToken("newcode")
    }

    let textBody = try JSONSerialization.data(withJSONObject: ["text": "accepted before rotation"])
    DispatchQueue.global(qos: .userInitiated).async {
        let response = router.handle(HTTPRequest(
            method: "POST",
            target: "/api/text?token=oldcode",
            path: "/api/text",
            query: ["token": "oldcode"],
            headers: ["content-type": "application/json"],
            body: textBody
        ))
        responseBox.store(response)
        requestFinished.signal()
    }

    #expect(requestFinished.wait(timeout: .now() + 5) == .success)
    #expect(responseBox.load()?.statusCode == 201)
    #expect(store.incomingSnapshot().count == 1)

    let rejectedOldRequest = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=oldcode",
        path: "/api/items",
        query: ["token": "oldcode"]
    ))
    let acceptedNewRequest = router.handle(HTTPRequest(
        method: "GET",
        target: "/api/items?token=newcode",
        path: "/api/items",
        query: ["token": "newcode"]
    ))
    #expect(rejectedOldRequest.statusCode == 403)
    #expect(acceptedNewRequest.statusCode == 200)
}

private final class HTTPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: HTTPResponse?

    func store(_ response: HTTPResponse) {
        lock.lock()
        self.response = response
        lock.unlock()
    }

    func load() -> HTTPResponse? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crosstool-router-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
