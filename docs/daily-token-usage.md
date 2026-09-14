# Daily token usage

The quota ring still displays provider limits. Settings → Token usage displays
locally recorded consumption for Claude Code and Codex, independent of login
and quota availability. This is an implementation in Swift, informed by
[Tokei's documented field mappings and replay cases](https://github.com/cclank/tokei/blob/main/CALCULATION.md).
No Tokei collector is executed or bundled.

## Accounting

- Claude: `message.usage.input_tokens`, `output_tokens`,
  `cache_read_input_tokens` and `cache_creation_input_tokens` are disjoint.
  Use message ID plus request ID for streaming deduplication, keeping the largest
  snapshot. UUID is the fallback. A parent message supersedes its sidechain
  replay; genuinely distinct subagent messages count.
- Codex: cumulative `total_token_usage` counters become increments at each event's
  timestamp. `cached_input_tokens` and `cache_write_input_tokens` are removed from
  inclusive input before presenting separate buckets. Reasoning remains in output.
  Repeated cumulative snapshots add nothing. A truncated session or counter reset
  uses `last_token_usage` and flags partial history; lifetime counters are not
  assigned to one day when the first response is missing.
- `session_meta.id` identifies a Codex session. Active/archive copies use the
  longest version. Leading snapshots matching an explicitly identified parent's
  counters and last response are discarded, including replays with new timestamps.
  Ancestry uses `forked_from_id` or `source.subagent.thread_spawn.parent_thread_id`.
  No timing heuristic discards independent requests with similar token counts.
- Each event is grouped with the same local calendar used for queries. A refresh
  after a time-zone change rebuilds day boundaries from event timestamps.

## Reading and privacy

`DailyTokenReader` scans on an actor outside the main UI thread. Unchanged files
reuse an in-memory metadata cache; changed files are streamed in 64 KiB chunks.
The parser retains counts, timestamps, model/project identifiers and deduplication
keys, never conversation text or credentials. Nothing is uploaded or written to
a usage database. The next launch rebuilds history from available logs.

Malformed records, unreadable files, missing ancestry and lines over 16 MiB result
in a visible partial-history notice. A trailing incomplete line is retried when
the file changes. File deletion or truncation removes obsolete contributions.
Logs without enough information to identify replayed ancestry cannot be fully
deduplicated. Missing devices and deleted records cannot be inferred from quota.

## Validation

`Tests/DailyTokenUsageTests.swift` uses Swift Testing and synthetic JSONL fixtures.
Run `python3 Scripts/build-local.py --tokens-only` with Command Line Tools, or
`make test` with full Xcode to include the existing XCTest suite as well.
The standalone build stages a temporary Swift package under `build/`, preserving
the repository's XcodeGen workflow and dependency lockfile.
