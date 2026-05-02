import Vapor

/// WorkoutChallenge app-state ingest. Snapshots are intentionally low-frequency
/// (weekly, or on meaningful change). The phone is the source of truth for
/// challenge state; the vault is just an archive the LLM can read.
enum WorkoutChallengeRoutes {
    static func postSnapshot(req: Request) async throws -> Response {
        let payload = try req.content.decode(SnapshotPayload.self)
        req.logger.info("snapshot received: as_of=\(payload.asOf) day=\(payload.dayOf90)/90")
        // TODO: write raw/workout-challenge/snapshots/YYYY-MM-DD.json
        // TODO: optionally render a markdown summary alongside the JSON
        return try stubResponse(
            req,
            route: "/workout-challenge/snapshot",
            echo: ["day_of_90": "\(payload.dayOf90)"]
        )
    }
}
