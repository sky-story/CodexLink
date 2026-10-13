# Release readiness

CodexLink is suitable for **Alpha / developer-preview source distribution**, not a stable consumer release. The shared-session core has physical iPhone validation; see [validation](validation.md).

## Public source preparation

- English default README and Chinese README include installation, fictional UI screenshots, and explicit capability boundaries.
- Personal pairing state, notification credentials, handoff notes, raw device evidence, development experiments, and old screenshots are excluded from Git.
- The public Xcode project uses neutral signing defaults. Local maintainer signing settings are preserved separately from the published Git content.
- Original licenses and third-party notices remain included.
- Privacy, terms, and support links point to this fork. Some inherited help screens still describe upstream functionality; use the README for the supported shared-daemon workflow.

Targeted checks for known local credentials and personal identifiers do not constitute a comprehensive security audit.

## Before a stable release

1. Complete a first install on a clean Mac/account with a new signing identity and first pairing.
2. Expand repeated-network-loss, lock/unlock, force-quit, sleep/wake, and pending-approval recovery testing.
3. Verify denial/cancellation and concurrent decisions from phone and Mac.
4. Add visibility and deliberate control for tools that remain backgrounded after Turn interruption.
5. Complete the iTerm physical-device flow and notification scenario coverage.
6. Publish a reproducible version compatibility matrix and upgrade/rollback instructions.

This source publication does not add an App Store/TestFlight build or an independent APNs entitlement. Codex 0.162.1 remains the verified baseline. Other versions must be checked before compatibility is claimed.
