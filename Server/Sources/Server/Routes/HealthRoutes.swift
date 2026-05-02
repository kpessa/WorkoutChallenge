import Vapor

/// HealthKit ingest endpoints — single workout, daily aggregates, and bulk
/// backfill. All three persist to the LLM Vault via the writers in
/// `Sources/Server/Writers/`. Idempotent on `hk_uuid` for workouts and on
/// `(kind, sample.start)` for daily samples — re-pushes are safe no-ops.
///
/// Response shapes echo enough that the iOS client can reconcile what landed
/// vs. what was new vs. what failed, without needing a separate `GET /status`.
enum HealthRoutes {
    static func postWorkout(req: Request) async throws -> Response {
        let payload = try req.content.decode(WorkoutPayload.self)
        let vaultPath = req.serverConfig.vaultPath

        req.logger.info("workout received: uuid=\(payload.hkUUID) type=\(payload.workoutType) start=\(payload.start) duration=\(payload.durationSeconds)s")

        do {
            let outcome = try WorkoutWriter.writeWorkout(payload, vaultPath: vaultPath)
            let (status, url): (String, URL) = {
                switch outcome {
                case .wrote(let u):   return ("wrote", u)
                case .skipped(let u): return ("skipped", u)
                }
            }()
            req.logger.info("workout \(status): \(url.lastPathComponent)")
            return try makeResponse(req, body: WorkoutIngestResponse(
                ok: true,
                hkUUID: payload.hkUUID,
                status: status,
                path: vaultRelativePath(url, vaultPath: vaultPath)
            ))
        } catch let e as WorkoutWriterError {
            req.logger.error("workout writer failed: \(e)")
            return try makeErrorResponse(req, status: .internalServerError,
                                         message: "writer failed: \(e)")
        }
    }

    static func postDaily(req: Request) async throws -> Response {
        let payload = try req.content.decode(DailySamplesPayload.self)
        let vaultPath = req.serverConfig.vaultPath

        req.logger.info("daily samples received: date=\(payload.date) count=\(payload.samples.count) types=\(payload.samples.map(\.kind).joined(separator: ","))")

        do {
            let mdURL = try DailyHealthWriter.mergeDaily(payload, vaultPath: vaultPath)
            req.logger.info("daily merged: \(mdURL.lastPathComponent)")
            return try makeResponse(req, body: DailyIngestResponse(
                ok: true,
                date: payload.date,
                samplesIngested: payload.samples.count,
                path: vaultRelativePath(mdURL, vaultPath: vaultPath)
            ))
        } catch let e as DailyHealthWriterError {
            req.logger.error("daily writer failed: \(e)")
            return try makeErrorResponse(req, status: .internalServerError,
                                         message: "writer failed: \(e)")
        }
    }

    static func postBackfill(req: Request) async throws -> Response {
        let payload = try req.content.decode(BackfillPayload.self)
        let vaultPath = req.serverConfig.vaultPath

        req.logger.info("backfill received: workouts=\(payload.workouts.count) days=\(payload.days.count)")

        var workoutsAdded = 0
        var workoutsSkipped = 0
        var workoutsFailed = 0
        var daysMerged = 0
        var daysFailed = 0
        var errors: [String] = []

        for workout in payload.workouts {
            do {
                let outcome = try WorkoutWriter.writeWorkout(workout, vaultPath: vaultPath,
                                                             ingestedBy: "WorkoutChallenge backfill")
                switch outcome {
                case .wrote:   workoutsAdded += 1
                case .skipped: workoutsSkipped += 1
                }
            } catch {
                workoutsFailed += 1
                errors.append("workout \(workout.hkUUID): \(error)")
                req.logger.error("backfill workout \(workout.hkUUID) failed: \(error)")
            }
        }

        for day in payload.days {
            do {
                _ = try DailyHealthWriter.mergeDaily(day, vaultPath: vaultPath)
                daysMerged += 1
            } catch {
                daysFailed += 1
                errors.append("day \(day.date): \(error)")
                req.logger.error("backfill day \(day.date) failed: \(error)")
            }
        }

        req.logger.info("backfill done: workouts=\(workoutsAdded)/\(workoutsSkipped)/\(workoutsFailed) days=\(daysMerged)/\(daysFailed)")

        return try makeResponse(req, body: BackfillResponse(
            ok: errors.isEmpty,
            workoutsAdded: workoutsAdded,
            workoutsSkipped: workoutsSkipped,
            workoutsFailed: workoutsFailed,
            daysMerged: daysMerged,
            daysFailed: daysFailed,
            // Cap the surfaced errors to keep responses bounded — full list is
            // in the server log. iOS just needs to know "did anything fail."
            errorsSample: Array(errors.prefix(10))
        ))
    }
}

// MARK: - Response shapes

struct WorkoutIngestResponse: Content {
    let ok: Bool
    let hkUUID: String
    /// "wrote" or "skipped"
    let status: String
    /// Vault-relative path of the .md (e.g. "raw/healthkit/workouts/2026-05-02/F4A8...md")
    let path: String

    enum CodingKeys: String, CodingKey {
        case ok, status, path
        case hkUUID = "hk_uuid"
    }
}

struct DailyIngestResponse: Content {
    let ok: Bool
    let date: String
    let samplesIngested: Int
    let path: String

    enum CodingKeys: String, CodingKey {
        case ok, date, path
        case samplesIngested = "samples_ingested"
    }
}

struct BackfillResponse: Content {
    let ok: Bool
    let workoutsAdded: Int
    let workoutsSkipped: Int
    let workoutsFailed: Int
    let daysMerged: Int
    let daysFailed: Int
    let errorsSample: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case workoutsAdded = "workouts_added"
        case workoutsSkipped = "workouts_skipped"
        case workoutsFailed = "workouts_failed"
        case daysMerged = "days_merged"
        case daysFailed = "days_failed"
        case errorsSample = "errors_sample"
    }
}

// MARK: - Helpers

/// Shared 501 response for stubbed endpoints. Used by routes that have wire +
/// auth + body decoding wired but writers not yet implemented (e.g.
/// `WorkoutChallengeRoutes.postSnapshot`). Returns enough context that the
/// iOS client can prove the request reached us, body parsed, and auth passed.
func stubResponse(_ req: Request, route: String, echo: [String: String]) throws -> Response {
    struct Stub: Content {
        let ok: Bool
        let todo: String
        let route: String
        let echo: [String: String]
    }
    let body = Stub(ok: false, todo: "writer pending", route: route, echo: echo)
    let response = Response(status: .notImplemented)
    try response.content.encode(body)
    return response
}

/// Wrap `Content` in a 200 OK response.
private func makeResponse<C: Content>(_ req: Request, body: C) throws -> Response {
    let response = Response(status: .ok)
    try response.content.encode(body)
    return response
}

/// Structured error response.
private struct ErrorResponse: Content {
    let ok: Bool
    let error: String
}

private func makeErrorResponse(_ req: Request,
                               status: HTTPResponseStatus,
                               message: String) throws -> Response {
    let response = Response(status: status)
    try response.content.encode(ErrorResponse(ok: false, error: message))
    return response
}

/// Compute the vault-relative path string for a fully-qualified URL.
/// Example: "/Users/.../llm-vault/raw/healthkit/workouts/2026-05-02/X.md"
///       → "raw/healthkit/workouts/2026-05-02/X.md"
private func vaultRelativePath(_ url: URL, vaultPath: String) -> String {
    let abs = url.path
    let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
    if abs.hasPrefix(prefix) {
        return String(abs.dropFirst(prefix.count))
    }
    return abs
}
