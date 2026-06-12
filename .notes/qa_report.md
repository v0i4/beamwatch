# BeamWatch — QA Report

## Summary

**Date:** 2026-06-11
**Branch:** phase-7
**Test count:** 131 tests, 0 failures
**Quality gate:** compile (no warnings), format, credo (0 issues), ex_dna (0 dupes), sobelow (clean), dialyzer (passes)

---

## Test coverage by domain

| Domain | Tests | Key files |
|--------|-------|-----------|
| Parser & Event | 19 | `parser_test.exs`, `event_test.exs` |
| Detectors | 35 | 4 detector test files |
| Engine | 18 | `engine_test.exs` |
| Watcher | 10 | `watcher_test.exs` |
| Log feed | 18 | `log_feed_test.exs`, `cli_test.exs`, `runner_test.exs` |
| Dashboard LiveView | 14 | `dashboard_live_test.exs` |
| Controllers | 4 | `page_controller_test.exs`, `error_*_test.exs` |
| Other | 3 | `application_test.exs`, `telemetry_test.exs`, `beamwatch_web_test.exs` |
| **Incident struct** | **9** | `incident_test.exs` (new) |
| **Silence struct** | **3** | `silence_test.exs` (new) |
| **SourceHealth** | **5** | `source_health_test.exs` (new) |
| **Event struct** | **4** | `event_test.exs` (new) |

---

## Requirements traceability

### Incident detection

| Requirement | Status | Tests |
|-------------|--------|-------|
| Container restart loop (≥4 die events in 60s) | ✅ | Threshold, window, supporting evidence, dedup |
| Disk SMART warning (warning → auto-resolve on pass) | ✅ | Detection, auto-resolve, severity escalation, benign non-triggers |
| Share permission failure (SMB/NFS) | ✅ | Detection from smb.log + nfs.log, cross-source merge, benign |
| VM boot failure (status=failed, supporting evidence) | ✅ | Detection, supporting evidence, no auto-resolve, benign |
| Malformed lines surfaced (not silently dropped) | ✅ | Parser returns `:malformed`, watcher tracks failures in health |
| Evidence deduplication | ✅ | All 4 detectors tested for duplicate raw line rejection |

### Operator actions

| Requirement | Status | Tests |
|-------------|--------|-------|
| Acknowledge an incident | ✅ | Engine + Dashboard: status → `:acknowledged` |
| Silence an incident (by id) | ✅ | Engine + Dashboard: creates silence, sets `:silenced` status |
| Silence an incident type | ✅ | Engine + Dashboard: type-scope silences all matching incidents |
| Resolve an incident | ✅ | Engine + Dashboard: manual resolve, SMART auto-resolve |
| Clear a silence (incident scope) | ✅ | Engine + Dashboard: removes silence, restores status |
| Clear a silence (type scope) | ✅ | Engine + Dashboard: removes type silence from all incidents |
| Non-existent incident actions | ✅ | Engine: acknowledge/resolve/silence on missing IDs handled gracefully |

### Edge cases

| Edge case | Status | Tests |
|-----------|--------|-------|
| Engine starts with empty state | ✅ | `starts with empty state` |
| Engine.clear/1 resets all state | ✅ | `clear/1 resets all state` |
| Acknowledge non-existent incident | ✅ | Silently ignored (warning logged) |
| Resolve non-existent incident | ✅ | Silently ignored (warning logged) |
| Silence non-existent incident | ✅ | Creates silence entry without crashing |
| Clear non-existent silence | ✅ | Silently ignored |
| Event.at/1 with both nils | ✅ | Returns nil |
| SourceHealth.summary/1 with nil fields | ✅ | Shows `?` for nil size/offset |
| Incident.new/3 with all options | ✅ | Severity, timestamps, evidence, silenced? |
| Silence.new/2 both scopes | ✅ | `:incident` and `:type` scopes |
| Dashboard evidence toggle | ✅ | Show/Hide evidence |
| Dashboard empty state panels | ✅ | Recent activity, source health empty states |

### Log ingestion

| Requirement | Status | Tests |
|-------------|--------|-------|
| Tail-new-lines (start at EOF) | ✅ | Existing files at startup |
| New files read from offset 0 | ✅ | New files after startup |
| Rotation detection (file shrinks) | ✅ | Rotation and truncation |
| Incomplete lines held back | ✅ | Holds until newline |
| Malformed lines in source health | ✅ | Parse failures tracked |
| Multiple files tracked independently | ✅ | Separate offsets |
| Source health broadcasts | ✅ | Health on reconcile |
| Deterministic fixture profiles | ✅ | Validation + sample profiles verified |

### UI rendering

| Component | Status | Tests |
|-----------|--------|-------|
| Incident list with severity/status badges | ✅ | Severity: HIGH/MEDIUM, Status: Active/Acknowledged/Resolved/Silenced |
| Evidence pane (expandable) | ✅ | Show/Hide evidence |
| Action buttons per incident | ✅ | Acknowledge, Silence, Resolve per status |
| Silences panel with Clear buttons | ✅ | Incident + type scope |
| Source health panel | ✅ | Empty state tested |
| Recent activity feed | ✅ | Empty state tested |
| Dev controls panel | ✅ | Add validation logs + Clear log dir |
| Starter shell panel | ✅ | Render verified |

---

## Gaps not covered (low priority)

| Gap | Reason |
|-----|--------|
| Dashboard LiveView PubSub updates via `handle_info` | LiveView subscribes to real Engine; hard to test without race conditions |
| Dashboard helper functions (encode_id, decode_id, format_dt, sort) | Tested indirectly through all button clicks and rendering assertions |
| Activity entry formatting (truncate, format) | Indirectly exercised by recent activity rendering |
| Performance / stress testing | Out of scope for 4-hour exercise |
| Concurrent file writes | Watcher uses inotify + reconcile tick; test would need timing guarantees |
| Cross-page navigation | Single-page app, no navigation |

---

## Commands

```bash
# Run all tests
mix test

# Run specific suites
mix test test/beamwatch/incidents/
mix test test/beamwatch/ingest/
mix test test/beamwatch_web/live/

# Quality gate
mix precommit
```
