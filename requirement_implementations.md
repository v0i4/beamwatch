# Required Incident Types — Implementation Mapping

> Generated from `lib/beamwatch/incidents/detectors/` — four detector modules implementing the `BeamWatch.Incidents.Detector` behaviour (`lib/beamwatch/incidents/detector.ex:9`).
>
> Each detector receives engine state + parsed event and returns updated state via `Enum.reduce` at `lib/beamwatch/incidents/engine.ex:248-251`.

---

## Container Restart Loop

**Requirement** (README:58-60)
> Open or update an incident when the same container has at least four `die` events within 60 seconds.

**Requirement** (README:61)
> Supporting evidence can include healthcheck failures, upstream unavailable messages, or related container start events near the same time.

### Implementation

**File:** `lib/beamwatch/incidents/detectors/container_restart_loop.ex`

- **`detect/2`** (line 9): Dispatches to `handle_die_event/2` or `handle_supporting_event/2` based on the event's `event` field.
- **`@die_re`** (line 8): `~r/^container_die$/` — matches `event` field exactly.
- **`handle_die_event/2`** (lines 34–52): Buffers die events in a sliding window (`detector_scratch`). Calls `threshold_reached?/1`; if reached (4+ dies within 60s), opens or upserts the incident.
- **`handle_supporting_event/2`** (lines 54–75): Matches events with field values `"health_status", "unhealthy"`, `"health_status", "unhealthy_status"`, `"upstream", "unavailable"`, or `"container", "start"`. Appends to the incident's `:evidence` list.
- **`threshold_reached?/1`** (lines 106–118): Sorts the buffered die timestamps, takes the 4th-from-last, checks if it's within 60s of the latest. Returns `true` if 4+ events fit in a 60s window.
- **`open_incident/2`** (lines 121–137): Creates a new incident with `severity: :high`, attaches all evidence (dies + supporting).
- **`upsert_incident/2`** (lines 140–153): Updates an existing incident's `last_seen`, appends new evidence.
- **`update_incident/4`** (lines 156–175): Shared helper used by open/upsert; merges incident fields, deduplicates evidence by event `ref`.

### Test Coverage

**File:** `test/beamwatch/incidents/detectors/container_restart_loop_test.exs` (174 lines)

| Test | Line | What it verifies |
|------|------|------------------|
| `creates incident on die threshold` | 19 | 4 die events → incident created with `status: :active`, `severity: :high` |
| `reuses incident on repeated dies` | 40 | 5+ die events → same incident id, `last_seen` updated |
| `does not open incident below threshold` | 59 | 3 die events → no incident |
| `adds supporting healthcheck failure` | 76 | die + unhealthy → incident has 2 evidence items |
| `adds supporting upstream unavailable` | 97 | die + upstream unavailable → 2 evidence items |
| `adds supporting container start` | 116 | die + container start → 2 evidence items |
| `does not create incident with only supporting events` | 138 | No die events → no incident |
| `ignores unrelated events` | 158 | Unmatched event type → no incident |

### Fixture Data

**File:** `lib/beamwatch/log_feed/fixtures.ex` (lines 43–67)

Three fixture streams for `container_restart_loop`: one for the container name "webapp" (die events), one for "cron" (supporting only), and one for empty container (below threshold).

---

## Disk SMART Warning

**Requirement** (README:64–66)
> Open or update an incident when SMART warnings or errors appear for a disk.
>
> Group repeated warnings for the same disk on the same day.
>
> Resolve the incident if a later log line clearly indicates the SMART check passed for that disk.

### Implementation

**File:** `lib/beamwatch/incidents/detectors/disk_smart_warning.ex`

- **`detect/2`** (line 12): Dispatches to `handle_warning/2` or `handle_pass/2` based on regex match.
- **`@warning_re`** (line 8): `~r/smart.*(warning|error|failed)/i` — matches the event's `payload` field.
- **`@pass_re`** (line 9): `~r/smart.*pass/i` — matches the event's `payload` field.
- **`handle_warning/2`** (lines 37–59): Groups warnings per-disk, deduplicating same-day warnings (by comparing `:calendar_date`). Calls `escalate_severity/2` to promote `:medium` → `:high` after 3+ warnings.
- **`handle_pass/2`** (lines 62–67): Finds the active incident for the disk and transitions it to `status: :resolved`.
- **`escalate_severity/2`** (lines 84–94): Counts unique days in the scratch buffer for the disk; if 3+ days, sets `severity: :high`.

### Test Coverage

**File:** `test/beamwatch/incidents/detectors/disk_smart_warning_test.exs` (125 lines)

| Test | Line | What it verifies |
|------|------|------------------|
| `creates incident on smart warning` | 15 | First warning → incident created, `severity: :medium` |
| `groups repeated warnings for same disk on same day` | 35 | Two warnings same day → same incident, deduplicated evidence |
| `does not deduplicate across days` | 55 | Different day → `severity` remains `:medium`, evidence appended |
| `escalates severity after multiple warnings` | 75 | 3rd+ warning on new day → `severity: :high` |
| `resolves incident on smart pass` | 97 | SMART pass event → incident `status` set to `:resolved` |
| `ignores unrelated events` | 113 | Unmatched payload → no incident |

### Fixture Data

**File:** `lib/beamwatch/log_feed/fixtures.ex` (lines 70–87)

Two fixture streams for `disk_smart_warning`: "sda" (SMART error warnings) and "3" (SMART warning → pass, triggering auto-resolve).

---

## Share Permission Failure

**Requirement** (README:70–72)
> Open or update an incident when SMB, NFS, or application logs report permission-denied failures for the same share.
>
> Group repeated failures for the same share within a sensible time window. This incident may not have an obvious same-share success line in the fixture stream; operators should still be able to acknowledge, silence, or resolve it.

### Implementation

**File:** `lib/beamwatch/incidents/detectors/share_permission_failure.ex`

- **`detect/2`** (lines 9–36): Single path — checks `permission_denied?/1`, extracts share name via `share_field`, opens or upserts the incident. Groups within a 60-second window (evidence dedup by timestamp).
- **`permission_denied?/1`** (line 37): Returns true when event's `share` field is non-nil AND the `payload` contains `"permission denied"` (case-insensitive).
- Heuristics: share name extracted from the `share` field of the event (lines 39–48). Incident severity: `:medium`. No auto-resolve — operators must actively acknowledge, silence, or resolve.

### Test Coverage

**File:** `test/beamwatch/incidents/detectors/share_permission_failure_test.exs` (124 lines)

| Test | Line | What it verifies |
|------|------|------------------|
| `creates incident on permission denied` | 15 | SMB permission denied → incident created |
| `reuses incident for same share` | 33 | Same share, second event → same id, evidence grows |
| `creates separate incidents for different shares` | 53 | Two shares → two separate incidents |
| `ignores non-permission-denied events` | 75 | payload without "permission denied" → no incident |
| `ignores events without share field` | 101 | No `share` field → no incident |

### Fixture Data

**File:** `lib/beamwatch/log_feed/fixtures.ex` (lines 89–98)

One fixture stream for `share_permission_failure`: share name "backups" with SMB permission-denied payload.

---

## VM Boot Failure

**Requirement** (README:76–78)
> Open or update an incident when libvirt/QEMU logs report a VM startup failure.
>
> Supporting evidence can include missing image, missing bridge, permission, or device errors near the same time.

### Implementation

**File:** `lib/beamwatch/incidents/detectors/vm_boot_failure.ex`

- **`detect/2`** (lines 9–13): Dispatches to boot failure handler or supporting event handler.
- **`boot_failure?/1`** (lines 17–21): Returns true when `event == "libvirt"` AND `status == "failed"` AND the `vm` field is present.
- **`@boot_failure_re`** (line 8): `~r/libvirt/i` — matches the `event` field.
- **`supporting_event?/1`** (lines 23–35): Matches on `payload` matching syslog port missing or qemu permission denied (regex patterns at lines 27, 31). For qemu events, `extract_vm_from_qemu/1` parses the VM name from the file path in the message.
- **`extract_vm_from_qemu/1`** (lines 79–90): Regex `~r|/qemu/([^/]+)/|` to extract VM name from paths like `/var/log/libvirt/qemu/myvm/...`.
- No auto-resolve — VM boot failure requires operator action.

### Test Coverage

**File:** `test/beamwatch/incidents/detectors/vm_boot_failure_test.exs` (131 lines)

| Test | Line | What it verifies |
|------|------|------------------|
| `detects direct boot failure` | 16 | libvirt event with `status: "failed"` + VM name → incident |
| `detects boot failure with capital V` | 30 | Case variance handled |
| `does not flag non-failure libvirt events` | 44 | libvirt without `status: "failed"` → no incident |
| `flags syslog port missing as supporting` | 58 | port-missing payload → evidence attached to incident |
| `flags qemu permission denied as supporting` | 75 | qemu permission-denied → evidence, VM extracted from path |
| `ignores qemu when no incident exists` | 97 | qemu supporting event without prior boot failure → ignored |
| `ignores unrelated events` | 117 | Matched event type but irrelevant payload → no incident |

### Fixture Data

**File:** `lib/beamwatch/log_feed/fixtures.ex` (lines 101–120)

Two fixture streams for `vm_boot_failure`: "win10" (direct libvirt boot failure + syslog supporting event) and "ubuntu-vm" (libvirt boot failure + qemu permission denied supporting event).

---

## Wiring & Integration

**File:** `lib/beamwatch/incidents/engine.ex`

| Aspect | Details |
|--------|---------|
| Detector list | `@detectors [ContainerRestartLoop, DiskSmartWarning, SharePermissionFailure, VMBootFailure]` (line 38) |
| Event dispatch | `handle_info({:beamwatch, :event, event}, state)` (line 127) calls `apply_detectors/2` |
| Detector execution | `Enum.reduce(@detectors, state, fn d, acc -> d.detect(acc, event) end)` (lines 248–251) |
| PubSub events | Events arrive on `"beamwatch:events"`; state updates broadcast on `"beamwatch:state"` |
| Operator actions | `acknowledge/2` (line 64), `resolve/2` (line 83), `silence/3` (line 75), `clear_silence/3` |

**Integration test:** `test/beamwatch/incidents/engine_test.exs:34` — processing all validation fixture events creates exactly 4 incidents with the correct types. Line 200 specifically verifies disk SMART warning auto-resolves.

## Data Model

**`lib/beamwatch/incidents/incident.ex`**

| Field | Type | Description |
|-------|------|-------------|
| `id` | `{atom(), String.t()}` | Composite key: `{type, resource}` |
| `type` | atom | One of `:container_restart_loop`, `:disk_smart_warning`, `:share_permission_failure`, `:vm_boot_failure` |
| `resource` | string | Container name, disk name, share name, VM name |
| `severity` | `:medium \| :high` | Escalated by some detectors |
| `status` | `:active \| :acknowledged \| :silenced \| :resolved` | Lifecycle state |
| `evidence` | list of events | Supporting log entries, deduplicated |
| `first_seen` / `last_seen` | DateTime | Time range of the incident |
| `silenced?` | boolean | Whether the incident is currently silenced |

**Detector behaviour** (`lib/beamwatch/incidents/detector.ex:9`):
```elixir
@callback detect(map(), BeamWatch.Ingest.Event.t()) :: map()
```
