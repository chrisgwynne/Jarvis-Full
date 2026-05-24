# JarvisMacTests

Focused XCTest target for high-confidence regression coverage of the most
fragile paths in the Jarvis macOS app.

This directory contains finished test source files **but is not yet wired
into the Xcode project** as a target.  Adding the target via the Xcode UI
is the safe, one-time path described below.  Editing `project.pbxproj`
by hand to create a test target is risky (one bad UUID and the project
will not open) and was deliberately deferred.

## One-time target setup

1. Open `JarvisMac.xcodeproj` in Xcode.
2. **File → New → Target…**
3. Choose **macOS → Unit Testing Bundle** → **Next**.
4. Settings:
   - Product Name: `JarvisMacTests`
   - Target to be Tested: `JarvisMac`
   - Language: Swift
   - Project: `JarvisMac` (the existing one)
   - Embed in: `JarvisMac`
5. Click **Finish**.  Xcode adds a `JarvisMacTests/` group at the root.
6. **Delete** the auto-generated `JarvisMacTests.swift` (we replace it with
   our focused tests).
7. **Add Files to "JarvisMac"…** — select every `.swift` file in this
   `JarvisMacTests/` directory and add them with the **JarvisMacTests**
   target ticked (NOT the `JarvisMac` app target).
8. Build (`⌘B`) — should compile.
9. Run tests (`⌘U`).

## Tests included

| File | Coverage | Status |
|------|----------|--------|
| `ProactivityDedupStoreTests.swift` | New Phase 2A persistent dedup store — hydrate, insert, cap+evict, batch | Ready |
| `ResponseRendererTests.swift` | Every `ResponseKey` resolves to non-empty text; placeholders substitute | Ready |
| `CommandPhraseMatcherTests.swift` | Default phrases resolve to expected intents; normalised variants match | Ready |
| `LLMIntentBridgeTests.swift` | Garbage JSON → unknown; blocked intents rejected; allowed intent passes confidence gate | Ready |
| `OpenAIChatClientRetryTests.swift` | `shouldRetry` classification: 429/5xx retried, 4xx not retried, cancellation not retried | Ready |
| `AndroidBridgeAuthTests.swift` | Phase 1 acceptance: unauth'd phone_event rejected; unauth'd command rejected; authenticated frames accepted | Ready — see file for the integration-mock setup |
| `ShopifyIntentHandlerTests.swift` | Return values; showShopifyOverlay opens overlay; not-configured guard | Ready — Sprint R |
| `SpotifyIntentHandlerTests.swift` | Return values; no-token guard speaks not-configured for all 8 intents | Ready — Sprint R |
| `WeatherIntentHandlerTests.swift` | Return values; location-denied guard for both weather intents | Ready — Sprint R |
| `TodoistIntentHandlerTests.swift` | Return values; not-configured guard; addTask empty-text → setPendingContext | Ready — Sprint R |
| `CalendarIntentHandlerTests.swift` | Return values; not-authorized guard; addReminder empty-text path | Ready — Sprint R |
| `GitHubIntentHandlerTests.swift` | Return values for all 23 intents; overlay on showGitHubOverlay; no-module guard; no-token guard | Ready — Sprint R |
| `HomeAssistantIntentHandlerTests.swift` | Return values for all 20 intents; homeStatus speaks summary; homeTurnOn ambiguous → setPendingContext; not-configured guard; closeCamera closes overlay | Ready — Sprint R |
| `RedditIntentHandlerTests.swift` | Return values; showReddit opens overlay; showSubreddit unknown → error state; redditRefresh; redditOpenIndex out-of-bounds; summariseText with LLM disabled | Ready — Sprint R |
| `ContextGraphTests.swift` | Node dedup (same externalID+type updates in place); edge dedup (confidence win); neighbours (out + in); empty ingestion no-crash; activeContinuityChain anchor; explainProvenance unknown→empty, known→anchor entry; ContextProvenance.summary; ContextGraphDiagnostics.oneLiner; TrustTier ordering | Ready — Sprint S |
| `JarvisAnswerComposerTests.swift` | Graph block nil when no graphIndex injected; nil for irrelevant routes (generalChat/command/memoryUpdate/ignore/clarification); non-nil for projectReflection/knowledgeQuery with data; charBudget enforcement; trust-tier label present; very tight budget → nil; compose fallback unbroken with nil graph; no duplicate build-file UUIDs in pbxproj | Ready — Sprint T |

## Tests deferred to future passes

The following were listed in the brief but require integration scaffolding
(stub controller, mocked HA client, fake STT/TTS) that's worth its own
focused session rather than rushing now:

- **ProactivityEngine** dedup/cooldown/quiet-hours/daily-cap — engine takes
  an `AppState` and depends on `ProactivityPreferences`; the integration
  surface is bigger than a single Phase-5 file.
- **Speech/listening lifecycle** — wake → listen → handle → return to
  passive; requires mocking `WakeWordDetecting`, `SpeechRecognizing`, and
  `TextToSpeaking` protocols across a sequence of state transitions.
- **IntentRouter end-to-end routing** — the router has 308 intent cases
  and ~1850 lines of substring logic; a "10 representative phrases" test
  is doable but its real value comes when paired with a CI regression suite.

## Conventions

- Every test class uses `@testable import JarvisMac`.
- Tests are `@MainActor`-marked when they touch any `@MainActor` type
  (CommandPhraseStore, ProactivityDedupStore, etc.).
- File I/O tests write to a per-test temporary directory and clean up.
- No test makes a real network call, microphone capture, camera capture,
  or Keychain write — Keychain writes in particular would pollute the
  developer's actual login keychain.

## Running a single test

From the command line:

```bash
xcodebuild test \
  -scheme JarvisMac \
  -destination 'platform=macOS' \
  -only-testing:JarvisMacTests/ProactivityDedupStoreTests/test_persistsAcrossInstances
```
