# Validation summary

Baseline: 2026-10-13, Codex CLI and shared daemon **0.162.1**, Node **24.5.0**, Xcode **26.5**. Physical-device checks used an iPhone 16 Pro running iOS 18.7.8; simulator checks used iOS 26.5.

This public summary reports the maintainer's local results. Raw device records, thread identifiers, private paths, logs, and historical screenshots are deliberately not distributed. They remain local; the summary is not independently reproducible evidence of every physical-device result.

## Physical-device checks

| Scenario | Observed result | Boundary |
| --- | --- | --- |
| Observe Mac CLI | Original running TUI output visible on iPhone | Same shared daemon and socket required |
| Steer | Phone input observed in the original Turn; expected final response | No fallback to a new task |
| Queue | Idle cellular Queue and busy Queue both completed | Busy Queue started one subsequent Turn after the original finished; repeated-delivery phone test pending |
| Approve | One-time approval matched the original request and executed once | Deny/cancel, concurrent approval, and pending-approval reconnect pending |
| Stop | Original Turn became interrupted without an extra Turn | Already-backgrounded tools may survive; Stop is not a process-tree kill |
| Continue on Mac | Original TUI could submit another task after phone controls | Verified in the same retained terminal |
| Network change | One Wi-Fi-to-cellular transition recovered | Repeated outages and force-quit recovery need more testing |
| Bridge crash | launchd recovered; phone reconnected in about six seconds without a new QR code | One observed recovery; not a daemon crash or Mac sleep/wake test |
| Bark | User confirmed a test notification on the locked phone | A separate automatic task-completion notification was accepted by Bark; its physical display was not separately confirmed |

## Automated checks and builds

Results below are from separate runs and **must not be added together as distinct tests**. The latest changes were tested selectively; earlier complete-suite counts are historical.

| Check | Recorded result |
| --- | --- |
| Earlier full Bridge suite | 207 passed, 0 failed |
| Earlier full Relay suite | 30 passed, 0 failed |
| Focused iOS tests | 22 passed; not the complete upstream suite |
| Reconnect iOS tests | 7 passed, including 3 new registration-gap tests |
| Shared controls and busy-Queue observer assertions | 31 passed |
| Stop / approval observer fixtures | 6 / 7 passed; fixtures alone are not physical acceptance |
| Private push integration | 22 Bridge / 23 Relay focused tests passed with fake providers |
| Open-on-Mac | 9 focused tests passed |
| Bark session labels plus Bridge regression | 13 Bark + 14 Bridge passed |
| Latest Bark body layout | 13 Bark tests passed; event status in title, session label in body |
| Builds | Simulator, unsigned iOS, and signed local-device builds succeeded |
| Documentation preview | Actual SwiftUI rendered three fictional offline scenes; not functional acceptance |

Bark labels use the formal thread name, then project basename, then an unnamed-session fallback, plus a hash-derived short identifier. Tests cover same-name concurrent sessions, grouping, renaming, timeout/error fallback, character cleanup, opt-out, durable deduplication, and redacted payloads. Synthetic labeled notifications were accepted by the real provider. The latest body layout still needs physical display confirmation.

## Known gaps

- This app's own APNs delivery is not validated. The local Personal Team build lacks the required push entitlement. Bark is a separate receiving app.
- Opening a thread in iTerm is experimental. Local isolated opening/attachment has passed; phone-to-launchd opening and macOS Automation permission handling still need physical acceptance.
- A targeted fallback handles `list_turns is not supported yet` for already-loaded threads. Resolution of the original phone UI error remains unconfirmed.
- No complete validation of repeated network loss, app force-quit, sleep/wake, daemon failure, concurrent input, or approval races.
- No clean-machine first-install acceptance yet.

## Safe reproduction

Run the unit suites and simulator build documented in the root README. Bridge tests use temporary state and mock Keychain; Relay tests use isolated state. An earlier handshake test overwrote a real pairing identity. That isolation defect was repaired, and regression coverage now protects caller state. Never supply real pairing files to tests or reuse a paired simulator for documentation fixtures.

For live acceptance, create a disposable project and start the original TUI against the shared daemon. Record the thread, Turn, and stable message/request identifier before each phone operation. Check order and exactly-once effects through official events/history, then confirm the same TUI remains usable. A sent receipt, provider acceptance, or successful build does not establish end-to-end success.

## Source-publication checks

The bilingual README links and embedded image paths were checked against the exact Git index. Known local credentials and maintainer identifiers were absent from the public files. Signing defaults in the public project are neutral; the maintainer’s working signing files and pairing identity were preserved. The simulator build passed after updating this fork’s privacy and feedback URLs. These checks are not a clean-machine installation test or a comprehensive security audit.

## Phone-created chat history compatibility

A real isolated new-chat probe reproduced `-32601: list_turns is not supported yet`: Codex 0.162.1 selected `historyMode: paginated` by default, while the local store rejected the required history operation. Both `thread/read(includeTurns:true)` and `thread/resume` failed for that thread; the older live-resume fallback could not repair it.

The Bridge now explicitly requests the supported `legacy` history format when creating a new thread. It retains the subscription established by `thread/start`, and discovery continues past unreadable threads so one unsupported session cannot block other live subscriptions. Existing threads are not migrated, replaced, or deleted, and sandbox/approval settings remain unchanged.

21 focused shared-runtime, history-fallback, and controller tests passed. Both new regressions failed before their fixes. A real same-daemon probe with an in-memory control store created a new thread in an isolated workspace, queued one no-tool task, observed exactly one completed Turn with the matching input ID and response, and successfully read/resumed that same thread. Before the first message, legacy history returned the expected not-materialized response already handled by the iPhone app. This validates the Bridge path; phone UI retesting remains pending. Previously created paginated chats are preserved and may still report the original error.

New Chat now asks whether to open the same session in iTerm. Declining sends no open request. A confirmed empty chat opens a waiting window until its first phone message materializes the rollout, then runs the existing same-daemon resume command. Waiting is bounded to 30 minutes and can be canceled with Ctrl+C. Nine focused Bridge tests passed, covering the original open behavior, durable deduplication, and waiting for a nonempty rollout with safely quoted arguments. Physical phone prompt and full iTerm attachment acceptance remain pending.

## Shared model and reasoning settings

The composer now reads the daemon's session metadata and model catalog, displays the configured model/effort, and submits constrained, durable settings commands through the existing Bridge. Only model and effort are changed. Official settings events update the display; reconnect refreshes metadata without loading history. A replayed receipt cannot replace newer Mac settings. Changes target subsequent tasks, including waiting Queue entries, not an already-running Turn.

20 focused Bridge tests and 5 isolated simulator tests passed. Coverage includes supported combinations, catalog pagination at the Bridge, permission-field rejection, duplicate requests, uncertain readback, and a newer settings event winning over a stale metadata response. A real isolated same-daemon thread changed model/effort, received the official settings event, returned the same receipt for a duplicate command, and completed exactly one queued no-tool task. Its execution context matched the requested model/effort; approval and sandbox settings were unchanged. This is daemon-level acceptance, not physical iPhone picker acceptance. Concurrent Mac/phone setting changes and changes while a real task is running still need end-to-end checks.

A subsequent physical screenshot exposed a gap in those tests: the outer Bridge handles phone initialization itself and omitted `sessionSettings`, even though the internal shared runtime advertised it. The app consequently disabled both selectors and incorrectly asked for a Bridge update. The phone-facing response now includes the capability. A regression runs the real Bridge router with mocked network, daemon, notifications, and identity state; it failed before the fix and passes for initial connection and reconnect. 16 focused router/Bridge tests passed. Only the Bridge needs updating for this fix; physical picker retesting remains pending.

One isolated iOS test passed for preserving the request ID after an uncertain open and accurately reporting a waiting window. The new-chat confirmation was visually reviewed in the unpaired simulator. A local live experiment opened a real iTerm window for an empty legacy thread, queued one no-tool message, and observed the assistant reply in that exact terminal session after automatic attachment. The thread had exactly one Turn and unchanged approval/sandbox settings. This local launch does not establish phone-to-launchd Automation authorization or physical prompt acceptance.
