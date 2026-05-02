# WorkoutChallenge Server

Vapor 4 service that runs on the Mac mini, accepts HealthKit + app-state pushes
from the iPhone over Tailscale, and lands them as raw files in the llm-vault for
the LLM to synthesize lazily. Mirrors the BrainSpace and QueryMessages pattern.

## Why this exists

The vault already pulls iMessages, Gmail, and Calendar. HealthKit can't be
reached from the Mac — only the phone can read HK. This server is the
phone-as-client / Mac-as-server bridge so HK data lands in
`llm-vault/raw/healthkit/`, where the existing claude tooling can read it.

See `~/code/llm-vault/CLAUDE.md` and the `HealthKit → Vault sync` memory entry
for the full design discussion.

## Endpoints

| Method | Path | Auth | Status |
|---|---|---|---|
| GET | `/healthz` | none | live |
| POST | `/health/workout` | bearer | stub (501) |
| POST | `/health/daily` | bearer | stub (501) |
| POST | `/health/backfill` | bearer | stub (501) |
| POST | `/workout-challenge/snapshot` | bearer | stub (501) |

The four write endpoints validate auth, decode the body, log the receipt, and
return 501. Real writers come next, mirroring BrainSpace's `TicketWriter`
line-oriented markdown surgery for the daily-rollup upsert.

## Run locally

```bash
cd Server
WORKOUT_CHALLENGE_TOKEN=dev-token swift run -c release
# in another shell:
curl -s http://localhost:9080/healthz | jq
curl -sf -H 'Authorization: Bearer dev-token' \
  -H 'Content-Type: application/json' \
  -d '{"hk_uuid":"test","workout_type":"running","start":"2026-04-30T07:00:00Z","end":"2026-04-30T07:30:00Z","duration_s":1800}' \
  http://localhost:9080/health/workout
```

## Run on the Mac mini (auto-start, restartable)

See `../launchd/` and `../scripts/install-launchagents.sh`.

```bash
# one-time install
./scripts/install-launchagents.sh

# bounce the server (rebuild from source, restart) from anywhere:
touch .restart-trigger
```

## Config

| Env var | Default | Purpose |
|---|---|---|
| `WORKOUT_CHALLENGE_TOKEN` | _(required)_ | Bearer token for write endpoints. Set in the launchd plist `EnvironmentVariables`. |
| `LLM_VAULT_PATH` | `/Users/kurtpessa/code/llm-vault` | Where to write raw files. |
| `HOST` | `0.0.0.0` | Bind address. |
| `PORT` | `9080` | Listen port. |

## TCC / permissions

The server reads/writes `~/code/llm-vault`. If launchd starts it before the
user grants Full Disk Access (or it tries to read a Documents-protected path),
it'll see EPERM. Grant FDA to the binary at `Server/.build/release/Server` in
System Settings → Privacy & Security → Full Disk Access if the daily writer
ever needs it.

## Architecture

- **Single executable target** — `Sources/Server/Entrypoint.swift` (`@main`).
- **Routes** wired in `Routes.swift`, grouped by `BearerAuthMiddleware`.
- **Models** in `Sources/Server/Models/Payloads.swift` — Codable types matching the iOS exporter wire format.
- **Stub responses** include the parsed payload echo so the iOS client can prove the round-trip works.
