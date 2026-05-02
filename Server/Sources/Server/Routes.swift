import Vapor

func routes(_ app: Application) throws {
    // Public health probe — no auth, no secrets in the body. Used by the install
    // script and by `touch .restart-trigger` callers to verify the bounce worked.
    app.get("healthz") { req -> HealthzResponse in
        HealthzResponse(
            ok: true,
            service: "workout-challenge-server",
            vault: req.serverConfig.vaultPath,
            tokenConfigured: !(req.serverConfig.token?.isEmpty ?? true)
        )
    }

    // Everything below requires Bearer auth.
    let authed = app.grouped(BearerAuthMiddleware())

    let health = authed.grouped("health")
    health.post("workout", use: HealthRoutes.postWorkout)
    health.post("daily", use: HealthRoutes.postDaily)
    health.post("backfill", use: HealthRoutes.postBackfill)

    let wc = authed.grouped("workout-challenge")
    wc.post("snapshot", use: WorkoutChallengeRoutes.postSnapshot)
}

struct HealthzResponse: Content {
    let ok: Bool
    let service: String
    let vault: String
    let tokenConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case ok, service, vault
        case tokenConfigured = "token_configured"
    }
}
