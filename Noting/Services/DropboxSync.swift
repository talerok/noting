import Foundation

struct RemoteNoteFile {
    let remoteId: String
    let noteId: String
    let updatedAt: Date
}

final class DropboxSync: @unchecked Sendable {
    private let auth: DropboxAuth

    private let basePath = "/Noting/notes"
    private let manifestPath = "/Noting/manifest.json"
    private let contentURL = "https://content.dropboxapi.com/2/files"
    private let apiURL = "https://api.dropboxapi.com/2/files"
    private let timeout: TimeInterval = 30

    init(auth: DropboxAuth) {
        self.auth = auth
    }

    // MARK: - Notes

    func listRemoteNotes() async throws -> [RemoteNoteFile] {
        try await ensureFolder()

        let body: [String: Any] = [
            "path": basePath,
            "recursive": false,
        ]

        let response = try await authenticatedPost(
            url: "\(apiURL)/list_folder",
            jsonBody: body
        )

        if response.statusCode == 409 { return [] }
        try checkResponse(response)

        var data = try parseJSON(response.data)
        var allEntries = (data["entries"] as? [[String: Any]]) ?? []

        while data["has_more"] as? Bool == true {
            guard let cursor = data["cursor"] as? String else { break }
            let contResponse = try await authenticatedPost(
                url: "\(apiURL)/list_folder/continue",
                jsonBody: ["cursor": cursor]
            )
            try checkResponse(contResponse)
            data = try parseJSON(contResponse.data)
            allEntries.append(contentsOf: (data["entries"] as? [[String: Any]]) ?? [])
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return allEntries
            .filter { ($0["name"] as? String)?.hasSuffix(".json") == true }
            .compactMap { entry in
                guard let name = entry["name"] as? String,
                      let id = entry["id"] as? String else { return nil }
                let noteId = String(name.dropLast(5)) // remove .json
                let modified = (entry["server_modified"] as? String).flatMap { formatter.date(from: $0) } ?? .now
                return RemoteNoteFile(remoteId: id, noteId: noteId, updatedAt: modified)
            }
    }

    func downloadNote(_ remoteId: String) async throws -> NoteDTO {
        let apiArg = try JSONSerialization.data(withJSONObject: ["path": remoteId])
        guard let apiArgString = String(data: apiArg, encoding: .utf8) else {
            throw DropboxSyncError(statusCode: 0, body: "Failed to encode API arg")
        }

        let response = try await authenticatedPost(
            url: "\(contentURL)/download",
            extraHeaders: ["Dropbox-API-Arg": apiArgString]
        )
        try checkResponse(response)

        guard let json = String(data: response.data, encoding: .utf8) else {
            throw DropboxSyncError(statusCode: 0, body: "Invalid UTF-8 in response")
        }
        return try NoteDTO.fromJsonString(json)
    }

    func uploadNote(_ dto: NoteDTO) async throws {
        let path = "\(basePath)/\(dto.id).json"
        let jsonStr = dto.toJsonString()

        let apiArg: [String: Any] = [
            "path": path,
            "mode": "overwrite",
            "autorename": false,
        ]
        let apiArgData = try JSONSerialization.data(withJSONObject: apiArg)
        guard let apiArgString = String(data: apiArgData, encoding: .utf8),
              let bodyData = jsonStr.data(using: .utf8) else {
            throw DropboxSyncError(statusCode: 0, body: "Failed to encode upload data")
        }

        let response = try await authenticatedPost(
            url: "\(contentURL)/upload",
            extraHeaders: [
                "Content-Type": "application/octet-stream",
                "Dropbox-API-Arg": apiArgString,
            ],
            rawBody: bodyData
        )
        try checkResponse(response)
    }

    func deleteRemoteNote(_ remoteId: String) async throws {
        let response = try await authenticatedPost(
            url: "\(apiURL)/delete_v2",
            jsonBody: ["path": remoteId]
        )
        // 409 = already deleted
        if response.statusCode != 409 {
            try checkResponse(response)
        }
    }

    // MARK: - Manifest

    func downloadManifest() async throws -> (json: String?, rev: String?) {
        let apiArg = try JSONSerialization.data(withJSONObject: ["path": manifestPath])
        guard let apiArgString = String(data: apiArg, encoding: .utf8) else {
            throw DropboxSyncError(statusCode: 0, body: "Failed to encode API arg")
        }

        let response = try await authenticatedPost(
            url: "\(contentURL)/download",
            extraHeaders: ["Dropbox-API-Arg": apiArgString]
        )

        if response.statusCode == 409 {
            return (nil, nil)
        }
        try checkResponse(response)

        var rev: String?
        if let apiResult = response.headers["dropbox-api-result"] ?? response.headers["Dropbox-Api-Result"],
           let resultData = apiResult.data(using: .utf8),
           let meta = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        {
            rev = meta["rev"] as? String
        }

        let json = String(data: response.data, encoding: .utf8)
        return (json, rev)
    }

    func uploadManifest(_ json: String, rev: String?) async throws -> String {
        let mode: Any = rev != nil
            ? [".tag": "update", "update": rev!] as [String: String]
            : "overwrite"

        let apiArg: [String: Any] = [
            "path": manifestPath,
            "mode": mode,
            "autorename": false,
        ]
        let apiArgData = try JSONSerialization.data(withJSONObject: apiArg)
        guard let apiArgString = String(data: apiArgData, encoding: .utf8),
              let bodyData = json.data(using: .utf8) else {
            throw DropboxSyncError(statusCode: 0, body: "Failed to encode manifest data")
        }

        let response = try await authenticatedPost(
            url: "\(contentURL)/upload",
            extraHeaders: [
                "Content-Type": "application/octet-stream",
                "Dropbox-API-Arg": apiArgString,
            ],
            rawBody: bodyData
        )
        try checkResponse(response)

        let data = try parseJSON(response.data)
        guard let newRev = data["rev"] as? String else {
            throw DropboxSyncError(statusCode: 0, body: "Missing rev in upload response")
        }
        return newRev
    }

    // MARK: - Helpers

    private func ensureFolder() async throws {
        let _ = try? await authenticatedPost(
            url: "\(apiURL)/create_folder_v2",
            jsonBody: ["path": basePath, "autorename": false] as [String: Any]
        )
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DropboxSyncError(statusCode: 0, body: "Invalid JSON structure")
        }
        return json
    }

    private struct HTTPResponse {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
    }

    private func authenticatedPost(
        url: String,
        extraHeaders: [String: String] = [:],
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil
    ) async throws -> HTTPResponse {
        let maxRetries = 3

        for attempt in 0..<maxRetries {
            do {
                var token = try await auth.getValidAccessToken()
                var response = try await doPost(url: url, token: token, extraHeaders: extraHeaders, jsonBody: jsonBody, rawBody: rawBody)

                if response.statusCode == 401 {
                    token = try await auth.getValidAccessToken()
                    response = try await doPost(url: url, token: token, extraHeaders: extraHeaders, jsonBody: jsonBody, rawBody: rawBody)
                }

                return response
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                if attempt == maxRetries - 1 { throw error }
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }

        throw URLError(.cannotConnectToHost)
    }

    private func doPost(
        url: String,
        token: String,
        extraHeaders: [String: String],
        jsonBody: [String: Any]?,
        rawBody: Data?
    ) async throws -> HTTPResponse {
        guard let requestURL = URL(string: url) else {
            throw DropboxSyncError(statusCode: 0, body: "Invalid URL: \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let jsonBody {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        } else if let rawBody {
            request.httpBody = rawBody
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DropboxSyncError(statusCode: 0, body: "Invalid HTTP response")
        }

        let headers = Dictionary(
            httpResponse.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0, value as? String ?? "") }
            },
            uniquingKeysWith: { _, last in last }
        )

        return HTTPResponse(statusCode: httpResponse.statusCode, data: data, headers: headers)
    }

    private func checkResponse(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw DropboxSyncError(statusCode: response.statusCode, body: body)
        }
    }
}

struct DropboxSyncError: LocalizedError {
    let statusCode: Int
    let body: String

    var errorDescription: String? {
        "Dropbox error (\(statusCode)): \(body)"
    }
}
