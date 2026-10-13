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
- Opening a thread in iTerm is experimental. A local attempt timed out at a macOS Automation consent prompt; successful attachment from the phone is not yet verified.
- A targeted fallback handles `list_turns is not supported yet` for already-loaded threads. Resolution of the original phone UI error remains unconfirmed.
- No complete validation of repeated network loss, app force-quit, sleep/wake, daemon failure, concurrent input, or approval races.
- No clean-machine first-install acceptance yet.

## Safe reproduction

Run the unit suites and simulator build documented in the root README. Bridge tests use temporary state and mock Keychain; Relay tests use isolated state. An earlier handshake test overwrote a real pairing identity. That isolation defect was repaired, and regression coverage now protects caller state. Never supply real pairing files to tests or reuse a paired simulator for documentation fixtures.

For live acceptance, create a disposable project and start the original TUI against the shared daemon. Record the thread, Turn, and stable message/request identifier before each phone operation. Check order and exactly-once effects through official events/history, then confirm the same TUI remains usable. A sent receipt, provider acceptance, or successful build does not establish end-to-end success.

## Source-publication checks

The bilingual README links and embedded image paths were checked against the exact Git index. Known local credentials and maintainer identifiers were absent from the public files. Signing defaults in the public project are neutral; the maintainer’s working signing files and pairing identity were preserved. The simulator build passed after updating this fork’s privacy and feedback URLs. These checks are not a clean-machine installation test or a comprehensive security audit.
