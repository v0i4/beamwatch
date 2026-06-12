# BeamWatch — Original Implementation Plan

> The plan agreed before any application code was written. It captures the
> architecture, detection logic, decisions, and phased execution for building
> live incident triage on top of the starter shell.

## Context

This repo is the AI-generated **starter shell**. The task is to build a Phoenix
LiveView app that triages incidents from noisy Unraid-like system logs: read log
files from a local directory (`priv/logs/`), identify active incidents, show the
evidence behind each, surface source health, and let an operator acknowledge,
silence, resolve, and clear silences.

The log formats were reverse-engineered from `lib/beamwatch/log_feed/fixtures.ex`.

**Log line format:** `{ISO8601 timestamp} {payload}` across these files:
`docker.log`, `app.log`, `nginx.log`, `syslog.log`, `smb.log`, `nfs.log`,
`libvirt.log`, `qemu.log`, `unraid-dev.log`, `graphql-api.log`.

**Key signatures (from fixtures):**

| Incident | Trigger lines | Benign / resolve lines |
|----------|---------------|------------------------|
| Container restart loop | `docker.log`: `container=plex event=die exit_code=137` (4x at offsets 240/255/274/295 = 55s window). Support: `app.log service=plex healthcheck failed`, `nginx.log upstream plex unavailable` | `container=home-assistant event=die exit_code=0` (1x, ignored by threshold) |
| Disk SMART warning | `syslog.log`: `emhttpd: disk3 SMART warning: ...` | Resolve: `emhttpd: disk3 SMART check passed`. Benign: `disk1 SMART check passed`, `smartctl ... PASSED` |
| Share permission failure | `smb.log`: `Permission denied share=media`, `nfs.log`: `permission denied share=media` (dup line included) | Benign: `opened share=backups`, `mounted share=backups` |
| VM boot failure | `libvirt.log`: `vm=windows11 action=start status=failed reason="..."`. Support: `kernel: br0: port missing for vm=windows11`, `qemu ... Permission denied` | Later: `status=running`; benign: `vm=debian-dev action=start status=running` |
| Malformed | `not-a-timestamp ...`, `... emhttpd: disk=`, `... -drive file=`, `2026-06-05T15:16` | must surface, not crash |

Starter state: PubSub (`BeamWatch.PubSub`) is already in the supervision tree;
the dashboard (`dashboard_live.ex`) has placeholder panels ("0", "Not wired",
"No events") plus working dev controls. Log dir resolves via
`DevControls.target_dir/0` -> `priv/logs`.

## Finalized decisions

- **File-watcher (`file_system` dep)** for ingestion — event-driven reads.
- **Tail-new-lines-only** — on startup, existing files start at EOF (offset =
  current size); files created later start at offset 0.
- **Only Disk SMART auto-resolves** (explicit in README on `SMART check passed`);
  container/share/VM are operator-resolved. VM `status=running` is shown as
  evidence but does NOT auto-close.
- **Static severity per type with light escalation** (loop/VM = high,
  disk/share = medium; disk nudges up as repeat count grows).

### Interaction this introduces

`file_system` uses inotify, which watches a directory's inode. The existing
`DevControls.clear_log_dir/0` does `File.rm_rf!(target)` **then**
`File.mkdir_p!(target)` (`lib/beamwatch/log_feed/dev_controls.ex:30`) — deleting
and recreating the dir **breaks the watch**. To stay robust:

- Watch the log directory but **re-establish the watch** if it's removed/recreated.
- Add a lightweight **periodic reconcile tick (~2s)** as a safety net to catch
  missed events and refresh source health.

Detection uses the **embedded log timestamps**, so the 60s / grouping windows are
independent of playback `--speed`.

## Architecture

Data flow: **Watcher (file_system) -> Parser -> Engine (detectors + state) ->
PubSub -> LiveView**

```
lib/beamwatch/
  ingest/
    event.ex            # %Event{source, timestamp, raw, payload, fields, ingested_at}
    parser.ex           # raw line -> {:ok, %Event{}} | {:malformed, raw, reason}  (pure)
    watcher.ex          # GenServer: FileSystem.subscribe, tail-new offset model,
                        #   rotation (size<offset) & truncation handling, re-watch
                        #   on dir removal, periodic reconcile; updates SourceHealth
    source_health.ex    # %SourceHealth{} per file: exists?, size, offset, last_read_at,
                        #   last_event_at, parse_failures, malformed_samples, rotations
  incidents/
    incident.ex         # %Incident{id, type, resource, severity, status,
                        #   first_seen, last_seen, evidence[], silenced?}
    silence.ex          # %Silence{scope: :incident|:type, key}
    detector.ex         # shared behaviour/helpers
    detectors/
      container_restart_loop.ex
      disk_smart_warning.ex
      share_permission_failure.ex
      vm_boot_failure.ex
    engine.ex           # GenServer: holds incidents/silences/recent_activity/detector
                        #   scratch; API: snapshot/0, acknowledge/1, silence/2,
                        #   resolve/1, clear_silence/1
```

**Supervision** (`application.ex`): add `BeamWatch.Incidents.Engine` then
`BeamWatch.Ingest.Watcher` after PubSub.

**Engine** is the single in-memory source of truth (no DB). It applies each
detector to incoming events (sorted by timestamp within a batch), updates
incidents keyed by `{type, resource}`, records recent activity (bounded ring
buffer), then broadcasts `{:beamwatch, :updated}` on PubSub. LiveView pulls
`Engine.snapshot/0`.

## Detection logic

- **Container restart loop:** track die-event timestamps per container; open/update
  `{:container_restart_loop, container}` when >= 4 within any 60s window
  (order-independent). Attach nearby healthcheck-failed / upstream-unavailable /
  start lines as supporting evidence. Severity: high.
- **Disk SMART warning:** open/update `{:disk_smart_warning, disk, date}` on
  `diskN SMART warning`; **auto-resolve** on `diskN SMART check passed`. Match
  `SMART warning` specifically so `smartctl ... PASSED` / `disk1 SMART check
  passed` don't trigger. Severity: medium (escalate with count).
- **Share permission failure:** open/update `{:share_permission_failure, share}`
  on `permission denied ... share=X` (smb/nfs/app), grouping within a time window;
  dedupe duplicate evidence but bump last_seen. No success line -> **manual resolve
  only**. Severity: medium.
- **VM boot failure:** open `{:vm_boot_failure, vm}` on `status=failed`; attach
  `br0: port missing`, qemu permission errors. Severity: high.

## Status model & operator actions

`:active -> :acknowledged`, `:silenced` (via silence), `:resolved` (operator or
auto for SMART). Silence scope = single incident or incident type; clearing a
silence restores visibility. Silenced incidents still update last_seen/evidence
but don't "interrupt" (sorted/greyed in UI).

Actions: acknowledge, silence (incident or type), resolve, clear silence.

## Source health & recent activity

Per watched file: exists?, size, last_read_at, last_event_at, byte offset,
parse failures (count + recent malformed samples), rotation/truncation detected.
Recent activity: bounded list of last N events + malformed lines + incident
state changes.

## LiveView UI (`dashboard_live.ex`)

- **Active incidents** list: type, severity badge, status, affected resource,
  first/last seen, expandable evidence pane (raw lines).
- Per-incident action buttons: Acknowledge, Silence this / Silence type, Resolve;
  a Silences section with Clear buttons.
- **Source health** panel.
- **Recent activity** feed.
- Subscribe to PubSub on mount; re-render on `{:beamwatch, :updated}`. Keep the
  existing dev controls working.

## Testing

- `parser_test.exs` — valid lines, field extraction, each malformed variant,
  timestamp fallback.
- One test per detector — threshold boundaries (3 vs 4 die events), grouping,
  auto-resolve, benign non-triggers.
- `engine_test.exs` — feed full validation event set -> exactly the 4 incidents,
  benign ones excluded, malformed surfaced; operator actions transition state.
- `watcher_test.exs` — write to `System.tmp_dir!`, assert offset advance,
  rotation/truncation handling, source health.
- `dashboard_live_test.exs` — render incidents; acknowledge/silence/resolve/clear
  update UI; keep dev-controls test.
- Keep a pure functional core for offset/parse so the watcher GenServer stays thin
  and testable.

## Deliverables

- `.notes/` directory: architecture write-up, AI usage, tradeoffs, known
  limitations, "what I'd do next".
- Update `AGENTS.md` / README run notes if anything changes.

## Phased execution

1. Parser + Event (+tests) — pure, fast feedback.
2. Watcher functional core + GenServer + SourceHealth (+tests).
3. Engine skeleton + PubSub + supervision wiring.
4. Four detectors (+tests).
5. LiveView dashboard (incidents, evidence, actions, source health, activity).
6. Operator actions end-to-end (+LiveView tests).
7. `.notes/`, polish, quality gate green.

## Status

- **Phase 1 complete:** `BeamWatch.Ingest.Event`, `BeamWatch.Ingest.Parser`, and
  `parser_test.exs` (committed on branch `phase-1`).
