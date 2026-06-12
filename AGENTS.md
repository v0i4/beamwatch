# BeamWatch — AGENTS.md

## Project
Phoenix LiveView app for triaging incidents from Unraid-like system logs.
Take-home interview exercise — starter shell, intentionally thin.

## Quick start
```
mise install
mix setup             # deps.get + assets.setup + assets.build
mix phx.server        # http://localhost:4000
mix test
```

## Key commands
| Command | Purpose |
|---------|---------|
| `mix beamwatch.feed_logs --profile validation --target priv/logs` | Generate deterministic fixture logs |
| `mix beamwatch.feed_logs --profile validation --target priv/logs --speed 20` | Same, faster |
| `mix precommit` | Full quality gate: `compile --warnings-as-errors` → `deps.unlock --unused` → `format --check-formatted` → `credo --strict` → `ex_dna` → `sobelow --exit` → `dialyzer` |
| `mix precommit.full` | Same as `precommit` plus `coveralls` |
| `docker compose up log-environment` | Optional long-running log generator with rotation |

## Architecture
- **Single Phoenix app** (not an umbrella)
- **Router**: `GET /` → `BeamWatchWeb.DashboardLive` (`lib/beamwatch_web/router.ex:20`)
- **Entrypoint**: `BeamWatch.Application` (`lib/beamwatch/application.ex`)
- **Domain**: `lib/beamwatch/` — business logic, log ingestion
- **Incident detectors**: `lib/beamwatch/incidents/detectors/` — four detector modules implementing `BeamWatch.Incidents.Detector` behaviour, wired in `engine.ex`
- **Log feeder**: `lib/beamwatch/log_feed/` — deterministic fixture generator (Mix task + dev controls)
- **Web**: `lib/beamwatch_web/` — LiveView, components, router
- **No database / no Ecto** — state is in-memory, sourced from log files at `priv/logs/`

## Testing
- Use `mix test` to run all tests
- Log feed tests write to `System.tmp_dir!()`, clean up with `File.rm_rf/1`
- Two fixture profiles: `"sample"` (short smoke) and `"validation"` (primary deterministic stream)
- Validation profile is deterministic across runs (same sources, lines, delays)
- Tests use `ExUnit.Case` (async) and `BeamWatchWeb.ConnCase`

## Toolchain quirks
- **Server**: Bandit (not Cowboy)
- **Templates**: HEEx via `~H`; `lazy_html` is a test-only dep for LiveView DOM assertions
- **Assets**: esbuild + tailwind (dev-only deps via `mix setup`)
- Default log directory: `priv/logs/` (gitignored)
- Elixir `~> 1.20` (use `mise install` to get the pinned runtime)
- No CI workflows, no pre-commit hooks config in repo
- **First `mix dialyzer` builds a PLT (minutes, one-time)**, cached in `priv/plts/`
- **Coverage threshold is strict: 80%** — run `mix precommit.full` (or `mix coveralls`) separately; `precommit.full` requires OTP 27.1+ due to an Erlang `cover` tool regression in OTP 27.0.
- **Sobelow** flags CSP absence in `router.ex` and directory traversal in `lib/beamwatch/log_feed/` — these are expected on a starter shell; triage or configure `.sobelow-conf` to suppress
