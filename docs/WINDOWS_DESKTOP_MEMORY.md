# Windows Desktop Memory

## Overview

`DesktopMemoryQueryService` answers natural-language queries about the user's current
Windows session history without calling any LLM. All answers are computed deterministically
from local data stores.

## Supported Query Patterns

| Query pattern | Data source | Example answer |
|---|---|---|
| "how long did I code today" | SessionMemoryStore (today's WorkSessions with Coding workflow) | "You coded for 2h 15m today." |
| "coding time", "programming" | SessionMemoryStore | Same |
| "what distracted me" | AppUsageTracker (Media / Gaming / Shopping entries) | "Top distractions today: vlc (12 min), steam (5 min)." |
| "distraction" | AppUsageTracker | Same |
| "what was I doing before lunch" / "this morning" | SessionMemoryStore (sessions before noon) | "Before lunch you were mainly working on Coding (Code) for 1h 45m." |
| "summarise my afternoon" / "after lunch" | SessionMemoryStore (12:00–17:00) | "This afternoon: Coding (65m), Browsing (15m), Communication (10m)." |
| "what apps did I use most" | AppUsageTracker (top 5 by dwell time) | "Top apps today: Code (95m), chrome (30m), slack (12m)." |
| "how long was I focused" | FocusSessionTracker.Current | "You've been focused for 1h 30m today." |
| "productivity score" | FocusSessionTracker.Current | "Your current productivity score is 72%." |
| anything else | — | Help text listing available queries |

## Data Sources

| Source | What it provides |
|---|---|
| `ISessionMemoryStore` | Completed work sessions from today/this week (JSONL on disk). Each has: start/end time, primary workflow, primary app, total focus duration. |
| `IAppUsageTracker` | In-memory ring of recent `AppUsageEntry` records (up to 20). Each has: process name, workflow category, dwell time, start time. |
| `IFocusSessionTracker` | Live `FocusMetrics`: current focus duration, productivity score, state, app switch count. |

## Privacy Guarantees

- No window titles, URLs, or document content are accessed.
- Only process names (privacy-safe), workflow categories, and aggregated metrics.
- Clipboard content is never queried by the memory service.
- Answers contain only aggregate statistics — never raw file paths or typed text.
- Memory data is not sent to any external service — answers are computed and returned locally.

## Bridge Protocol

### Query (Mac → Windows)
```json
{
  "type": "windows.memory.query",
  "id": "query-xyz",
  "memoryQuery": "how long did I code today?",
  "at": "2025-05-25T16:00:00Z"
}
```

### Answer (Windows → Mac)
```json
{
  "type": "windows.memory.answer",
  "id": "query-xyz",
  "memoryAnswer": "You coded for 2h 15m today.",
  "memoryData": "{\"codingMinutes\":135,\"sessionCount\":3}",
  "at": "2025-05-25T16:00:00.050Z"
}
```

`memoryData` is a JSON-encoded structured representation of the answer for programmatic use.
`memoryAnswer` is always the natural-language string.

## Example Queries and Answers

```
Query: "how long did I code today?"
Answer: "You coded for 2h 15m today."

Query: "what distracted me?"
Answer: "Top distractions today: vlc (12 min), steam (5 min)."

Query: "what was I doing before lunch?"
Answer: "Before lunch you were mainly working on Coding (Code) for 1h 45m."

Query: "summarise my afternoon"
Answer: "This afternoon: Coding (65m), Browsing (15m)."

Query: "how long was I focused?"
Answer: "You've been focused for 1h 30m today."

Query: "productivity score"
Answer: "Your current productivity score is 72%."

Query: "what apps did I use most?"
Answer: "Top apps today: Code (95m), chrome (30m), slack (12m), discord (8m), explorer (3m)."
```
