import Foundation
import Darwin

/// Renews the CLI's file-backed login, preserving its account and unrelated auth fields.
/// Coalesces renewals in this process and reloads before committing to avoid overwriting a CLI login.
actor CodexOAuth {
    static let shared = CodexOAuth()
    private var renewals: [String: Task<DirectSources.Credential, Error>] = [:]

    enum Failure: String, Error {
        case loginRequired = "expired — log in Codex"
        case changed = "Codex login changed — refresh again"
        case response = "Unreadable token renewal response"
        case save = "Cannot save Codex credentials"
    }

    func credential(path: String, rejected: DirectSources.Credential? = nil, now: Date,
                    transport: @escaping DirectSources.Transport) async throws -> DirectSources.Credential {
        if let pending = renewals[path] {
            let credential = try await pending.value
            if let rejected, rejected.accountId != credential.accountId { throw Failure.changed }
            return credential
        }
        let original = try DirectSources.readFile(path).get()
        let credential = try DirectSources.codexCredential(authJSON: original, now: now, allowExpired: true).get()
        if let rejected, rejected.accountId != credential.accountId { throw Failure.changed }
        // A CLI renewal since the failed usage request already gives us a new token.
        if let rejected, rejected.access != credential.access,
           credential.expires.map({ $0 > now }) ?? true { return credential }
        let refused = rejected?.access == credential.access
        let expiring = credential.expires.map { $0 <= now.addingTimeInterval(300) } ?? false
        guard refused || expiring else { return credential }
        guard let refresh = credential.refresh, !refresh.isEmpty else {
            if refused || credential.expires.map({ $0 <= now }) == true { throw Failure.loginRequired }
            return credential
        }

        let task = Task {
            try await Self.renew(path: path, original: original, credential: credential,
                                 refresh: refresh, now: now, transport: transport)
        }
        renewals[path] = task
        defer { renewals[path] = nil }
        return try await task.value
    }

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
    }

    private static func renew(path: String, original: Data, credential: DirectSources.Credential,
                              refresh: String, now: Date,
                              transport: DirectSources.Transport) async throws -> DirectSources.Credential {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!,
                                 timeoutInterval: DirectSources.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Same OAuth client and JSON grant used by the Codex CLI.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "refresh_token": refresh,
        ])
        let data: Data, status: Int
        do { (data, status) = try await transport(request) }
        catch {
            if let current = try replacement(path: path, original: original, credential: credential, now: now) {
                return current
            }
            throw error
        }
        if let current = try replacement(path: path, original: original, credential: credential, now: now) {
            return current
        }
        if status == 400 || status == 401 { throw Failure.loginRequired }
        guard status == 200 else { throw URLError(.badServerResponse) }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.access_token.isEmpty,
              response.refresh_token.map({ !$0.isEmpty }) ?? true,
              response.id_token.map({ !$0.isEmpty }) ?? true,
              var auth = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var tokens = auth["tokens"] as? [String: Any] else { throw Failure.response }
        tokens["access_token"] = response.access_token
        if let refresh = response.refresh_token { tokens["refresh_token"] = refresh }
        if let id = response.id_token { tokens["id_token"] = id }
        auth["tokens"] = tokens
        auth["last_refresh"] = ISO8601DateFormatter().string(from: now)
        let updated = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
        guard case .success(let renewed) = DirectSources.codexCredential(authJSON: updated, now: now) else {
            throw Failure.response
        }
        return try persist(updated, path: path, original: original, credential: credential, renewed: renewed, now: now)
    }

    /// Another process renewed or replaced the login while the network request was in flight.
    private static func replacement(path: String, original: Data, credential: DirectSources.Credential,
                                    now: Date) throws -> DirectSources.Credential? {
        let current = try DirectSources.readFile(path).get()
        guard current != original else { return nil }
        guard case .success(let loaded) = DirectSources.codexCredential(authJSON: current, now: now),
              loaded.accountId == credential.accountId else { throw Failure.changed }
        return loaded
    }

    private static func persist(_ data: Data, path: String, original: Data,
                                credential: DirectSources.Credential, renewed: DirectSources.Credential,
                                now: Date) throws -> DirectSources.Credential {
        // Create the sibling with mode 0600 before writing any secret, then atomically replace auth.json.
        let temporary = path + "." + UUID().uuidString + ".tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.save }
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close()
            throw Failure.save
        }
        if let current = try replacement(path: path, original: original, credential: credential, now: now) {
            return current
        }
        guard rename(temporary, path) == 0 else { throw Failure.save }
        return renewed
    }
}
