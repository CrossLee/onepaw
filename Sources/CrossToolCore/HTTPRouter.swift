import Foundation

public struct StaticWebAsset: Sendable {
    public let data: Data
    public let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

public final class HTTPRouter: @unchecked Sendable {
    private struct SessionCredential: Equatable {
        let token: String
        let generation: UInt64
    }

    private struct WebItem: Encodable {
        let id: UUID
        let kind: SharedItemKind
        let name: String
        let detail: String?
        let size: Int64?
        let mimeType: String
        let source: String
        let downloadURL: String?
        let createdAt: Date
    }

    private struct ItemsPayload: Encodable {
        let items: [WebItem]
    }

    private struct OperationPayload: Encodable {
        let ok: Bool
        let id: UUID?
        let name: String?
        let error: String?
    }

    private struct TextPayload: Decodable {
        let text: String
    }

    public var sessionToken: String {
        sessionCredential.token
    }

    private let sessionTokenLock = NSLock()
    private let sessionMutationLock = NSLock()
    private var storedSessionToken: String
    private var sessionTokenGeneration: UInt64 = 0
    private let store: SharedContentStore
    private let indexHTML: Data
    private let assets: [String: StaticWebAsset]

    public init(
        store: SharedContentStore,
        sessionToken: String,
        indexHTML: Data,
        assets: [String: StaticWebAsset] = [:]
    ) {
        self.store = store
        self.storedSessionToken = sessionToken
        self.indexHTML = indexHTML
        self.assets = assets
    }

    public func updateSessionToken(_ sessionToken: String) {
        sessionMutationLock.lock()
        defer { sessionMutationLock.unlock() }
        sessionTokenLock.lock()
        defer { sessionTokenLock.unlock() }
        if storedSessionToken != sessionToken {
            storedSessionToken = sessionToken
            sessionTokenGeneration &+= 1
        }
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET", let asset = assets[request.path] {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": asset.contentType, "Cache-Control": "no-cache"],
                body: asset.data
            )
        }

        // Keep one credential snapshot for the entire request. If the owner
        // rotates the access code concurrently, a request authenticated with
        // the old code must never receive a download URL containing the new
        // code.
        let requestCredential = sessionCredential

        if request.path == "/" {
            guard request.method == "GET" else { return methodNotAllowed() }
            guard isAuthorized(request, sessionToken: requestCredential.token) else {
                return HTTPResponse.text(
                    unauthorizedHTML,
                    statusCode: 403,
                    contentType: "text/html; charset=utf-8"
                )
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
                ],
                body: indexHTML
            )
        }

        guard isAuthorized(request, sessionToken: requestCredential.token) else {
            return errorResponse("无效或已过期的共享链接", statusCode: 403)
        }

        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            return HTTPResponse.json(OperationPayload(ok: true, id: nil, name: nil, error: nil))
        case ("GET", "/api/items"):
            return listItems(sessionToken: requestCredential.token)
        case ("POST", "/api/upload"):
            return receiveUpload(request, credential: requestCredential)
        case ("POST", "/api/text"):
            return receiveText(request, credential: requestCredential)
        case ("GET", let path) where path.hasPrefix("/download/"):
            return download(path: path, request: request, credential: requestCredential)
        default:
            if ["GET", "POST"].contains(request.method) {
                return errorResponse("页面不存在", statusCode: 404)
            }
            return methodNotAllowed()
        }
    }

    private func listItems(sessionToken: String) -> HTTPResponse {
        let items = store.publicSnapshot().map { item in
            WebItem(
                id: item.id,
                kind: item.kind,
                name: item.title,
                detail: item.detail,
                size: item.byteCount,
                mimeType: item.mimeType,
                source: item.direction == .outgoing ? "teacher" : "browser",
                downloadURL: item.fileURL == nil ? nil : ShareLinkBuilder.relativeURL(
                    path: "/download/\(item.id.uuidString)",
                    accessCode: sessionToken
                ),
                createdAt: item.createdAt
            )
        }
        return HTTPResponse.json(ItemsPayload(items: items))
    }

    private func receiveUpload(
        _ request: HTTPRequest,
        credential: SessionCredential
    ) -> HTTPResponse {
        guard request.body.count <= SharedContentStore.maximumUploadBytes + 1_048_576 else {
            return errorResponse("上传文件超过 256 MB 限制", statusCode: 413)
        }
        guard let contentType = request.headers["content-type"],
              contentType.lowercased().contains("multipart/form-data"),
              let boundary = MultipartFormData.boundary(from: contentType),
              let file = MultipartFormData.firstFile(in: request.body, boundary: boundary) else {
            return errorResponse("没有找到可上传的文件", statusCode: 400)
        }

        let stagedFile: StagedIncomingFile
        do {
            stagedFile = try store.stageReceivedFile(data: file.data, filename: file.filename)
        } catch {
            return errorResponse(error.localizedDescription, statusCode: 500)
        }

        var didCommit = false
        defer {
            if !didCommit {
                store.discardStagedFile(stagedFile)
            }
        }
        let response = withCurrentSession(credential) {
            do {
                let item = try store.commitReceivedFile(
                    stagedFile,
                    remoteAddress: request.remoteAddress,
                    notifyChange: false
                )
                didCommit = true
                return HTTPResponse.json(
                    OperationPayload(ok: true, id: item.id, name: item.title, error: nil),
                    statusCode: 201
                )
            } catch {
                return errorResponse(error.localizedDescription, statusCode: 500)
            }
        }
        if didCommit {
            store.notifyObservers()
        }
        return response ?? expiredLinkResponse()
    }

    private func receiveText(
        _ request: HTTPRequest,
        credential: SessionCredential
    ) -> HTTPResponse {
        guard request.body.count <= 64 * 1024 else {
            return errorResponse("文字内容过长", statusCode: 413)
        }
        guard let payload = try? JSONDecoder().decode(TextPayload.self, from: request.body) else {
            return errorResponse("文字请求格式不正确", statusCode: 400)
        }
        var didCommit = false
        let response = withCurrentSession(credential) {
            do {
                let item = try store.receiveText(
                    payload.text,
                    remoteAddress: request.remoteAddress,
                    notifyChange: false
                )
                didCommit = true
                return HTTPResponse.json(
                    OperationPayload(ok: true, id: item.id, name: item.title, error: nil),
                    statusCode: 201
                )
            } catch {
                return errorResponse(error.localizedDescription, statusCode: 400)
            }
        }
        if didCommit {
            store.notifyObservers()
        }
        return response ?? expiredLinkResponse()
    }

    private func download(
        path: String,
        request: HTTPRequest,
        credential: SessionCredential
    ) -> HTTPResponse {
        guard isCurrent(credential) else { return expiredLinkResponse() }
        let idText = String(path.dropFirst("/download/".count))
        guard let id = UUID(uuidString: idText),
              let item = store.publicItem(id: id),
              let fileURL = item.fileURL else {
            return errorResponse("文件不存在或已经取消分享", statusCode: 404)
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard isCurrent(credential) else { return expiredLinkResponse() }
            var responseData = data
            var statusCode = 200
            var headers = [
                "Content-Type": item.mimeType,
                "Content-Disposition": contentDisposition(for: item.title),
                "Accept-Ranges": "bytes"
            ]

            if let rangeHeader = request.headers["range"],
               let range = byteRange(from: rangeHeader, totalCount: data.count) {
                responseData = Data(data[range])
                statusCode = 206
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            }
            return HTTPResponse(statusCode: statusCode, headers: headers, body: responseData)
        } catch {
            return errorResponse("无法读取共享文件", statusCode: 500)
        }
    }

    private func isAuthorized(_ request: HTTPRequest, sessionToken: String) -> Bool {
        let candidate = request.query["token"] ?? request.headers["x-crosstool-token"]
        guard let candidate else { return false }
        let candidateBytes = Array(candidate.utf8)
        let tokenBytes = Array(sessionToken.utf8)
        guard candidateBytes.count == tokenBytes.count else { return false }

        var difference: UInt8 = 0
        for index in candidateBytes.indices {
            difference |= candidateBytes[index] ^ tokenBytes[index]
        }
        return difference == 0
    }

    private var sessionCredential: SessionCredential {
        sessionTokenLock.lock()
        defer { sessionTokenLock.unlock() }
        return SessionCredential(
            token: storedSessionToken,
            generation: sessionTokenGeneration
        )
    }

    private func isCurrent(_ credential: SessionCredential) -> Bool {
        sessionTokenLock.lock()
        defer { sessionTokenLock.unlock() }
        return credential.token == storedSessionToken
            && credential.generation == sessionTokenGeneration
    }

    private func withCurrentSession<T>(
        _ credential: SessionCredential,
        perform body: () -> T
    ) -> T? {
        // Serialize only the short final commit with credential rotation. File
        // data is staged before this point, so changing the access code never
        // waits for a potentially large disk write. The token lock itself is
        // not held while callbacks run, avoiding lock re-entry through change
        // handlers that read the current token.
        sessionMutationLock.lock()
        defer { sessionMutationLock.unlock() }
        guard isCurrent(credential) else { return nil }
        return body()
    }

    private func expiredLinkResponse() -> HTTPResponse {
        errorResponse("无效或已过期的共享链接", statusCode: 403)
    }

    private func errorResponse(_ message: String, statusCode: Int) -> HTTPResponse {
        HTTPResponse.json(
            OperationPayload(ok: false, id: nil, name: nil, error: message),
            statusCode: statusCode
        )
    }

    private func methodNotAllowed() -> HTTPResponse {
        errorResponse("不支持这个请求方法", statusCode: 405)
    }

    private func contentDisposition(for filename: String) -> String {
        let asciiFallback = filename
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? asciiFallback
        return "attachment; filename=\"\(asciiFallback)\"; filename*=UTF-8''\(encoded)"
    }

    private func byteRange(from header: String, totalCount: Int) -> Range<Int>? {
        guard totalCount > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
        let value = header.dropFirst("bytes=".count)
        guard !value.contains(",") else { return nil }
        let bounds = value.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        if bounds[0].isEmpty, let suffixCount = Int(bounds[1]), suffixCount > 0 {
            let start = max(0, totalCount - suffixCount)
            return start..<totalCount
        }
        guard let start = Int(bounds[0]), start >= 0, start < totalCount else { return nil }
        let requestedEnd = bounds[1].isEmpty ? totalCount - 1 : (Int(bounds[1]) ?? totalCount - 1)
        let end = min(max(start, requestedEnd), totalCount - 1)
        return start..<(end + 1)
    }

    private var unauthorizedHTML: String {
        """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>共享链接无效</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f7f7f9;color:#202127;display:grid;place-items:center;height:100vh;margin:0}.card{background:white;border:1px solid #e5e5ea;border-radius:18px;padding:36px;max-width:420px;box-shadow:0 12px 30px rgba(0,0,0,.06)}h1{font-size:22px}p{color:#6d6e78;line-height:1.6}</style><div class="card"><h1>共享链接无效</h1><p>请向分享者获取当前完整链接，然后重新打开。</p></div></html>
        """
    }
}
