# BeamWatch — Tradeoffs, Limitations, and What's Next

## Tradeoffs

### In-memory state (no database)

All incident state lives in a single GenServer's process dictionary. This
is simple and fast — no Ecto setup, no migrations — but means all data
is lost on restart, and the app cannot be clustered without additional
machinery. For the exercise scope (single operator, demo session) this
is appropriate; a production version would need a persistent store.

### Detectors as pure functions on Engine state

Each detector receives the full Engine state and returns updated state.
This is simple to test (no mocks) and easy to reason about, but means
every detector traverses the entire incidents map on every event. With
four detectors and a small event volume this is negligible; at scale
you'd want an index by type or a staged pipeline.

### PubSub as the only coupling between Watcher and Engine

The Watcher emits events on PubSub; the Engine subscribes. This
decouples ingestion from detection nicely, but it also means the Engine
processes events one at a time in `handle_info`. If the Watcher
produces events faster than the Engine can process them, the mailbox
grows. A bounded mailbox or a GenStage pipeline would help at scale.

### file_system (inotify) for log watching

The `file_system` library wraps inotify, which watches a directory's
inode. When DevControls clears the log directory (`File.rm_rf!`
followed by `File.mkdir_p!`), the watch is invalidated. The watcher
handles this by re-establishing the watch, but there is a brief window
between deletion and re-watch where events can be missed. The periodic
reconcile tick (~2s) catches these, so no data is permanently lost, but
the timeliness of detection may lag by up to 2s after a clear.

## Known limitations

### OTP 27 cover tool regression

`mix test --cover` and `mix coveralls` crash with a `MatchError` in
`:cover.do_compile_beam2/6` on OTP 27.0 (Erlang `tools` v4.0). This
is a pre-existing incompatibility between excoveralls 0.18.5 and the
OTP 27 `cover` implementation. The workaround is to skip `coveralls`
and use `mix test` directly. Coverage must be run on OTP 27.1+.

### No authentication or multi-user support

Every operator is anonymous; there is no concept of who acknowledged or
resolved an incident. The UI assumes a single operator.

### Silences have no expiration

Silences persist until explicitly cleared. The plan specifically scopes
this out, but a real system would want automatic expiration or at least
a created-at timestamp visible in the UI.

### Type-scope silence doesn't auto-silence future incidents

When a type is silenced, existing incidents of that type are marked
silenced, but new incidents created after the silence will not inherit
the silenced status. The incident will appear as active until the next
event updates it and the detector re-processes it against the silenced
state. A follow-up pass in `apply_detectors` could check each new
incident against type silences.

### No log retention or rotation management

The app tails logs indefinitely. If a log file grows unbounded, the
byte-offset tracking continues to work, but memory for recent activity
is bounded at 200 entries. There is no archival or log-rotation
handling beyond detecting truncation.

### Evidence deduplication is by raw string

Duplicate raw log lines are not added to incident evidence twice. This
is efficient but means two genuinely different events that happen to
produce the same raw text (unlikely but possible with truncated lines)
would be collapsed.

### Severity escalation is linear

Only the Disk SMART detector escalates severity (medium → high after 3
warnings). Other incident types have static severity. A more nuanced
model could escalate based on frequency, duration, or cross-incident
correlation.

## What I'd do next

### Persistence layer

Add SQLite (via `ecto_sqlite` or `sqlitex`) for crash recovery and
longer-running incident history. The Engine would still be the
in-memory cache, but would flush state changes to the database.

### Notifications / alerting

Add webhook or Slack integration when an incident is created or
escalates. A simple GenServer that watches PubSub and calls an HTTP
endpoint.

### Incident grouping and correlation

Related incidents (e.g., a container restart loop that causes a share
permission failure) could be grouped. The plan alludes to this with
cross-file evidence but the current detectors work independently.

### Silenced-type auto-apply

Future incidents of a silenced type should be born silenced. A
post-detection hook in the Engine could check each new incident against
the silences map and apply the status.

### Operator audit log

Track who did what (acknowledge, silence, resolve) with timestamps.
This would be straightforward with the existing recent-activity buffer.

### Timezone-aware timestamps

The UI currently renders UTC. Log timestamps are also UTC. A production
system would need timezone conversion for operators.

### Performance at scale

The detector pipeline is O(n*m) where n=events and m=detectors. For
high-throughput environments, consider:
- Staged event processing with back-pressure (GenStage)
- Parallel detector evaluation for independent detectors
- Index incidents by type for faster lookups

### Incomplete-line buffer per file

The watcher already holds back lines without a trailing newline. This
is correct but the buffer is not bounded — a file with a very long
incomplete line (or a truncated write) would hold it indefinitely.
Adding a timeout for incomplete lines would make it more robust.
