# BeamWatch — Architecture

## Overview

BeamWatch is a Phoenix LiveView application that triages incidents from
Unraid-like system logs. It reads log files from a local directory
(`priv/logs/`), identifies active incidents from log events, surfaces
evidence and source health, and lets operators acknowledge, silence, and
resolve incidents — all in memory, no database.

The design is a single-process-in-memory pattern: one GenServer (the
Engine) holds all incident state, detectors are pure functions that
transform state on each event, and the LiveView subscribes to PubSub
for real-time updates.

## Data flow

```
            Watcher (file_system)
                │
                ▼  file change events
            Parser (raw line → Event)
                │
                ▼  {:beamwatch, :event, event}
            PubSub("beamwatch:events")
                │
                ▼
            Engine (detectors + state)
                │
                ▼  {:beamwatch, :updated}
            PubSub("beamwatch:state")
                │
                ▼
            Dashboard LiveView
```

1. **Watcher** (`lib/beamwatch/ingest/watcher.ex`) — a GenServer that
   uses the `file_system` library (inotify) to watch the log directory.
   It tracks byte offsets per file (tail-only), detects rotation and
   truncation, and emits parsed events over PubSub.

2. **Parser** (`lib/beamwatch/ingest/parser.ex`) — a pure function that
   converts a raw log line into an `%Event{}` struct. It extracts the
   ISO8601 timestamp, key=value fields (with quoted-value support), and
   classifies malformed lines (`:no_timestamp`, `:truncated`,
   `:empty_payload`, `:blank`).

3. **Engine** (`lib/beamwatch/incidents/engine.ex`) — the central
   GenServer. It subscribes to `"beamwatch:events"`, runs each event
   through all four detectors, updates incident state, and broadcasts
   `{:beamwatch, :updated}` on `"beamwatch:state"`. It also holds
   silences and a bounded recent-activity buffer.

4. **Dashboard** (`lib/beamwatch_web/live/dashboard_live.ex`) — a
   LiveView that subscribes to `"beamwatch:state"` and
   `"beamwatch:health"`. On mount it calls `Engine.snapshot/0` for
   initial state, then re-renders on every PubSub update.

## Supervision tree

```
BeamWatch.Supervisor (one_for_one)
├── BeamWatchWeb.Telemetry
├── DNSCluster (disabled)
├── Phoenix.PubSub (BeamWatch.PubSub)
├── BeamWatch.Incidents.Engine (permanent GenServer)
├── BeamWatch.Ingest.Watcher (permanent GenServer)
└── BeamWatchWeb.Endpoint (Bandit)
```

The Engine and Watcher are started after PubSub so they can subscribe
immediately. Both are `:permanent` — if they crash, the supervisor
restarts them.

## Incident detection

Four detector modules implement the `BeamWatch.Incidents.Detector`
behaviour (single callback: `detect(state, event) -> state`):

| Detector | Trigger | Auto-resolve | Severity |
|----------|---------|-------------|----------|
| ContainerRestartLoop | ≥4 die events in 60s for same container | No | high |
| DiskSmartWarning | `disk<N> SMART warning` | Yes (`SMART check passed`) | medium→high |
| SharePermissionFailure | `Permission denied share=X` (smb/nfs) | No | medium |
| VMBootFailure | `status=failed` for VM | No | high |

Each detector is stateless — scratch data (e.g., die-event timestamps)
is stored in the Engine's `detector_scratch` map, keyed by detector
module.

## State model

Incidents follow this lifecycle:

```
active ──acknowledge──→ acknowledged
active ──silence──────→ silenced
acknowledged ──silence─→ silenced
active/acknowledged/silenced ──resolve──→ resolved
silenced ──clear silence──→ active
```

Silences have two scopes:
- `:incident` — silences one specific incident (by id `{type, resource}`)
- `:type` — silences all incidents of a given type

Type-scope silences mark all matching incidents (existing + updates)
as silenced. Clearing a type silence restores all matched incidents to
active.

## Log ingestion

- **Existing files at startup**: The watcher starts at the current EOF
  and does not re-read old lines.
- **New files** (created after watcher start): Read from offset 0.
- **Rotation / truncation**: Detected when file size is smaller than
  the tracked offset; offset resets to 0 and the new content is read.
- **Incomplete lines**: Lines without a trailing newline are held back
  until the newline arrives.
- **Reconcile tick**: A periodic ~2s tick catches missed inotify events
  and refreshes source health.
- **Source health**: Per-file metrics (exists?, size, offset,
  last_event_at, parse_failures, malformed_samples, rotations,
  truncated?) broadcast on `"beamwatch:health"`.

## Log feed

The `lib/beamwatch/log_feed/` module generates deterministic fixture
logs. Two profiles:

- **sample**: Short smoke test (a few events per incident type)
- **validation**: Full deterministic stream covering all four incident
  types, benign non-triggers, malformed variants, and duplicates

The Mix task `beamwatch.feed_logs` writes entries to `priv/logs/` with
configurable playback speed. In development, DevControls on the
dashboard provide "Add validation logs" and "Clear log dir" buttons.

## Testing approach

- 19 test files, 102 tests, all passing
- Parser tests use pure function calls (no setup)
- Detector tests build engine state maps directly
- Engine tests use real PubSub instances for integration
- Watcher tests write to `System.tmp_dir!()` and use reconcile ticks
- Dashboard tests use `Phoenix.LiveViewTest` with real Engine snapshots
- No mocks — all tests exercise real modules (test PubSub names avoid
  global state conflicts)
