//
//  ReclaimAPI.swift
//  WorkoutChallenge
//
//  Thin async HTTP client for reclaim.ai. No external dependencies — pure
//  URLSession + Codable. Endpoints and shape are taken from the unofficial
//  Python SDK (labiso-gmbh/reclaim-sdk), which mirrors the Swagger spec
//  a Reclaim engineer published.
//
//  This client is intentionally minimal: just enough for the Workout
//  Challenge integration (Phase C.1 = verify token + create workout tasks).
//  `completeTask` and `deleteTask` are included so Phase C.2 (completion
//  sync, challenge abandon) can layer in without a rewrite.
//

import Foundation

// MARK: - Public types

enum ReclaimAPIError: Error, LocalizedError {
    case noToken
    case invalidResponse
    case http(status: Int, message: String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No Reclaim API token. Paste one in Settings → Reclaim."
        case .invalidResponse:
            return "Reclaim returned an unexpected response."
        case .http(let status, let message):
            return "Reclaim error \(status): \(message)"
        case .decoding(let err):
            return "Could not decode Reclaim response: \(err.localizedDescription)"
        case .transport(let err):
            return "Network problem reaching Reclaim: \(err.localizedDescription)"
        }
    }
}

enum ReclaimPriority: String, Codable {
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"
    case p4 = "P4"
}

/// Minimal current-user shape — used only to verify the token is valid.
/// `id` is a UUID-style string from Reclaim, not an Int.
struct ReclaimUser: Decodable {
    let id: String?
    let email: String?
    let name: String?
}

/// Shape for creating a task. Only fields the app actually sets are encoded;
/// Reclaim fills the rest from its defaults.
struct ReclaimTaskCreate: Encodable {
    let title: String
    let notes: String?
    let eventCategory: String       // "WORK" (enum string) — keeps WorkChallenge tasks categorized
    let timeChunksRequired: Int     // 1 chunk = 15 min
    let minChunkSize: Int
    let maxChunkSize: Int
    let priority: ReclaimPriority
    let due: String?                // ISO8601 UTC — end of scheduled day
    let snoozeUntil: String?        // ISO8601 UTC — start of scheduled day; pins the task's window to one day so Reclaim can't front-load far-future workouts into this week
    let alwaysPrivate: Bool
    let type: String                // "TASK"
    let prioritizableType: String   // "TASK"
}

/// Shape returned after creating a task. We only need id + title to log a
/// useful confirmation; everything else is ignored.
struct ReclaimTaskCreated: Decodable {
    let id: Int
    let title: String?
}

/// Minimal shape for GET /api/tasks — used by the sync service's adoption
/// step to reconcile Reclaim's existing tasks back into local mappings.
/// Reclaim returns many more fields; JSONDecoder silently drops the extras.
struct ReclaimTaskListed: Decodable {
    let id: Int
    let title: String?
    let timeChunksRequired: Int?
}

// MARK: - Client

/// `ReclaimAPI` is stateless per call — each method reads the current token
/// from `ReclaimKeychain` at request time. Safe to use from any actor.
struct ReclaimAPI {
    static let baseURL = URL(string: "https://api.app.reclaim.ai")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Endpoints

    /// GET /api/users/current — fast, cheap, and confirms the token works.
    static func currentUser() async throws -> ReclaimUser {
        try await request(method: "GET", path: "/api/users/current", body: Optional<String>.none)
    }

    /// POST /api/tasks — creates one task.
    static func createTask(_ payload: ReclaimTaskCreate) async throws -> ReclaimTaskCreated {
        try await request(method: "POST", path: "/api/tasks", body: payload)
    }

    /// GET /api/tasks — returns every task the account owns. Used only by
    /// the adoption step on first C.2 sync; skip on normal runs.
    static func listTasks() async throws -> [ReclaimTaskListed] {
        try await request(method: "GET", path: "/api/tasks", body: Optional<String>.none)
    }

    /// POST /api/tasks/{id}/done — marks a task complete. Phase C.2.
    static func completeTask(id: Int) async throws {
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/api/planner/done/task/\(id)",
            body: Optional<String>.none
        )
    }

    /// DELETE /api/tasks/{id} — Phase C.2 (abandon challenge).
    static func deleteTask(id: Int) async throws {
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "/api/tasks/\(id)",
            body: Optional<String>.none
        )
    }

    // MARK: - Core request helper

    private struct EmptyResponse: Decodable {}

    private static func request<B: Encodable, R: Decodable>(
        method: String,
        path: String,
        body: B?
    ) async throws -> R {
        guard let token = ReclaimKeychain.token(), !token.isEmpty else {
            throw ReclaimAPIError.noToken
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ReclaimAPIError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try encoder.encode(body)
            } catch {
                throw ReclaimAPIError.decoding(error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ReclaimAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ReclaimAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "<no body>"
            throw ReclaimAPIError.http(status: http.statusCode, message: message)
        }

        // Empty-body endpoints (DELETE, 204) deserialize to EmptyResponse.
        if R.self == EmptyResponse.self {
            // swiftlint:disable:next force_cast
            return EmptyResponse() as! R
        }

        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw ReclaimAPIError.decoding(error)
        }
    }
}
