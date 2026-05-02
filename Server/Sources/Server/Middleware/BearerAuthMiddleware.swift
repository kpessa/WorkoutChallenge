import Vapor

/// Validates `Authorization: Bearer <token>` against the value baked into the
/// launchd plist's `EnvironmentVariables` (`WORKOUT_CHALLENGE_TOKEN`).
///
/// Constant-time comparison so an attacker who can time the response can't
/// recover the token byte-by-byte. Fails closed when the server has no token
/// configured (503, not 401) — that's a deployment bug, not an auth failure,
/// and the distinction matters when the iPhone is logging.
struct BearerAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let configured = request.serverConfig.token, !configured.isEmpty else {
            request.logger.warning("auth rejected: server has no WORKOUT_CHALLENGE_TOKEN configured")
            throw Abort(.serviceUnavailable, reason: "Server token not configured")
        }
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }
        guard constantTimeEquals(bearer.token, configured) else {
            throw Abort(.unauthorized, reason: "Invalid Bearer token")
        }
        return try await next.respond(to: request)
    }
}

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8)
    let bb = Array(b.utf8)
    if ab.count != bb.count { return false }
    var diff: UInt8 = 0
    for i in 0..<ab.count {
        diff |= ab[i] ^ bb[i]
    }
    return diff == 0
}
