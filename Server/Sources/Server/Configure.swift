import Vapor

func configure(_ app: Application) async throws {
    // Bind. 0.0.0.0 lets Tailscale, LAN, and localhost all reach us — Tailscale ACLs
    // and the bearer token are the actual gates.
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "9080") ?? 9080

    // Backfill payloads can be chunky (months of HK data in one POST).
    app.routes.defaultMaxBodySize = "32mb"

    // Pull config from env once and stash on the Application so handlers don't
    // re-read os.environ on every request.
    let token = Environment.get("WORKOUT_CHALLENGE_TOKEN")
    let vaultPath = Environment.get("LLM_VAULT_PATH") ?? "/Users/kurtpessa/code/llm-vault"

    if token?.isEmpty ?? true {
        app.logger.warning("""
            WORKOUT_CHALLENGE_TOKEN is not set or empty. All authed endpoints will reject \
            every request with 503. Set it in the launchd plist's EnvironmentVariables \
            (or `export WORKOUT_CHALLENGE_TOKEN=...` for local dev) before serving traffic.
            """)
    }

    app.storage[ServerConfigKey.self] = ServerConfig(token: token, vaultPath: vaultPath)
    app.logger.info("workout-challenge server up on \(app.http.server.configuration.hostname):\(app.http.server.configuration.port) — vault=\(vaultPath)")

    try routes(app)
}

struct ServerConfig {
    let token: String?
    let vaultPath: String
}

struct ServerConfigKey: StorageKey {
    typealias Value = ServerConfig
}

extension Application {
    var serverConfig: ServerConfig {
        guard let cfg = storage[ServerConfigKey.self] else {
            fatalError("ServerConfig not set — configure(_:) must run before any request")
        }
        return cfg
    }
}

extension Request {
    var serverConfig: ServerConfig { application.serverConfig }
}
