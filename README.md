# CodexLink

**English** | [简体中文](README.zh-CN.md)

View and control the **same running Codex CLI session on your Mac** from a native SwiftUI iPhone app. Your Mac runs the model and tools; your phone provides live output, Steer, a persistent Queue, Stop, and remote approvals.

**Status: Alpha / developer preview.** Intended for users comfortable building from source and troubleshooting. This is a fork of [RealDyllon/codex-remote](https://github.com/RealDyllon/codex-remote/tree/9a737fb), distributed under the ISC license. It is not an official OpenAI client.

## UI preview

These screenshots use the actual SwiftUI views, rendered in a **separate simulator with fictional to-do app data**. The Chinese label above each image means “Demo data · Offline preview.” No real conversations, pairing data, or push keys appear. These are UI examples, not end-to-end test evidence.

<p align="center">
  <img src="docs/images/session-queue.png" width="280" alt="Running demo session with Queue, Steer, Mac queue status and receipts" />
  <img src="docs/images/session-approval.png" width="280" alt="Demo approval request with command details and approval controls" />
  <img src="docs/images/session-completed.png" width="280" alt="Completed demo task and composer for continuing the same session" />
</p>

Left to right: **running session and queue → approval request → completed response**. Steer updates the current task; Queue schedules input after it. Approvals require an explicit user decision. See [screenshot generation](docs/images/README.md) (Chinese).

## What works today

| Capability | Validation scope |
| --- | --- |
| Live Mac CLI output | Verified on a physical iPhone, including cellular access through Tailscale |
| Steer during execution | Verified on the original Turn, without starting another task |
| Persistent Queue | Idle and busy Queue verified on iPhone; the Mac daemon owns the queue |
| Remote approvals | One-time approval verified; denial, races, and reconnect with pending approval need further validation |
| Stop | Original Turn interruption verified; **already-backgrounded tool processes may keep running** |
| Continue on Mac | The original Mac TUI remains usable after phone controls |
| Reconnect | One Wi-Fi-to-cellular handoff and one Bridge crash recovery verified |
| Bark lock-screen notifications | Physical test delivery verified; automatic completion accepted by provider; approval lock-screen delivery pending |
| Open this session on Mac (iTerm) | Implemented, experimental; full physical-device flow and macOS Automation permissions still need validation |

See the [validation summary](docs/validation.md) and [release readiness](docs/release-readiness.md). These are scoped results, not a claim of production reliability.

## How it works

```text
Native Mac Codex TUI ──┐
                      ├── Same Codex daemon / same Unix socket
Mac Bridge ───────────┘
    │
    └── Private Relay ⇄ Tailscale ⇄ iPhone SwiftUI app
                      (end-to-end encrypted after pairing)

Mac Bridge ── Optional event / session label → Bark → iPhone lock screen
```

A **Turn** is one task execution, ending in completion, failure, or interruption. Queue normally creates a later Turn; Steer adds input to the current Turn.

The CLI and Bridge must connect to the **same shared daemon**. Loading history or starting a separate App Server does not share a running task. Sessions started with `--no-daemon` are unsupported; some CLI `-c` overrides may also select an embedded runtime.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac | Able to run Xcode, Codex CLI, and Tailscale; background service uses macOS launchd |
| Codex | Installed and signed in on Mac; verified baseline: **CLI and daemon 0.162.1** |
| Node.js | **Node 24 recommended**; minimum 22.13 for the Bridge's `node:sqlite` usage |
| Xcode | Verified with **Xcode 26.5**; other versions are not yet guaranteed |
| iPhone | Minimum iOS 18.6; physical validation used iPhone 16 Pro / iOS 18.7.8 |
| Apple account | A free Personal Team can sign a local build; renewal is typically needed after about 7 days |
| Network | Tailscale installed on both devices, in the same tailnet with access between them |
| Optional | Bark for lock-screen notifications; iTerm for “Open this session on Mac” |

This fork has no App Store or TestFlight build. The upstream app and npm package are not this fork. Build both the app and Bridge from this repository. Codex uses your own account and usage allowance.

## Installation

### 1. Clone and install dependencies

```sh
git clone https://github.com/sky-story/CodexLink.git
cd CodexLink
npm --prefix codex-remote-bridge ci --ignore-scripts
npm --prefix relay ci --ignore-scripts
```

Xcode resolves the declared Swift Package dependencies when you open the project.

### 2. Check the shared Codex daemon

Start `codex` normally on your Mac and complete your own sign-in. From this repository, run:

```sh
node scripts/doctor.cjs
```

Check CLI/daemon versions, `daemonRunning`, and `controlSocketPresent`. A different version is outside the verified baseline. Do not kill a running daemon just to install this project.

To explicitly use the shared connection, run this from your working project:

```sh
codex --remote unix://
```

The default socket is `~/.codex/app-server-control/app-server-control.sock`. The Bridge does not start a replacement runtime when attachment fails. Keep your existing approval and sandbox settings; Full Access is not required.

### 3. Build and install the iPhone app

```sh
open CodexMobile/CodexMobile.xcodeproj
```

1. Add your Apple account in Xcode settings.
2. Select **CodexMobile target → Signing & Capabilities**, enable automatic signing, and select your Team.
3. Set a unique Bundle Identifier you can register, such as `com.example.mycodexlink`.
4. Connect and unlock your iPhone, trust the Mac, and enable Developer Mode when prompted.
5. Select the **CodexMobile scheme**, choose your iPhone, and click Run.
6. If iOS reports an untrusted developer, trust your own development profile under **Settings → General → VPN & Device Management**.

A paid developer account is not required for local installation. When renewing a build, keep the same Bundle ID and install over the existing app to preserve local state. Simulator builds are available, but do not prove lock-screen notification delivery.

### 4. Start the background service and pair

Connect both devices to Tailscale, then run from the repository root:

```sh
node scripts/private-service.cjs start
node scripts/private-service.cjs status
```

On first setup, a pairing QR code normally opens in your Mac browser. Scan it **inside the Codex Remote iPhone app**. Do not use an online QR decoder.

To display a new pairing code when needed:

```sh
node scripts/private-service.cjs pair
```

Select a safe test conversation and send a simple Queue message. Then try Steer during a longer harmless Mac task.

The service runs Bridge and Relay together, listening on the Mac's Tailscale address at port 9100. You can close the terminal. Do not start another Bridge/Relay on that port. No public port forwarding is needed. Ordinary network loss or Bridge restarts should not require repeated pairing.

### 5. Optional: Bark lock-screen notifications

1. Install [Bark](https://github.com/Finb/Bark) on iPhone and allow notifications on the lock screen.
2. Copy your full push URL from Bark to the **Mac clipboard**, without a surrounding `curl` command.
3. Run the following. The URL is read from stdin rather than stored in shell command history:

```sh
pbpaste | node scripts/bark-notifications.cjs --configure-stdin
node scripts/bark-notifications.cjs --status
node scripts/private-service.cjs restart
```

The tool will not overwrite an existing receiver configuration. The URL is stored outside the repository in `~/.codex-remote/bark-config.json`, with mode 600. Never commit it or share its device key.

Lock your phone and send an explicit test:

```sh
node scripts/bark-notifications.cjs --send-test
```

`accepted` means the provider accepted the request; check the actual lock screen. Notifications arrive through **Bark**. Open Codex Remote to handle approvals. This works with free Apple signing; this app's own APNs delivery remains unverified.

Generic notifications are the default. To distinguish concurrent sessions:

```sh
node scripts/bark-notifications.cjs --session-labels on
node scripts/private-service.cjs restart
```

A short event status appears in the title; the **session name and an eight-character identifier appear in the body**. Missing names fall back to the project directory name. Notifications are grouped per session. To disable labels, use `off` and restart.

Bark receives the device key and notification content. With labels enabled, that includes the session name or project basename and short identifier. Chat previews, commands, code, full paths, and raw thread IDs are not sent. Avoid sensitive session names. Focus modes, notification summaries, and network conditions may delay or suppress delivery.

## Daily use and updates

```sh
node scripts/private-service.cjs status     # Inspect background service
node scripts/private-service.cjs restart    # Install updated snapshot; restart Bridge/Relay
node scripts/private-service.cjs stop       # Stop service; keep login registration
node scripts/private-service.cjs uninstall  # Remove service registration; preserve pairing/history
```

The service runs an installed snapshot. After changing Bridge/Relay source, run `restart`. Swift changes require rebuilding and installing the app. These commands preserve pairing and do not restart the Mac or kill the Codex daemon.

Your Mac must be awake and online for remote control. A launchd service does not prevent Mac sleep.

## Troubleshooting

- **Offline:** check Tailscale, Mac sleep, service status, and daemon availability before changing pairing.
- **Port in use:** inspect for a duplicate service and stop only the duplicate you recognize.
- **History works, Steer does not:** the target must be active on the same daemon with a running Turn. Failed Steer is not converted into a new task.
- **A command remains after Stop:** already-backgrounded tools may continue. Inspect them on Mac; separate phone-side background terminal management is not available yet.
- **Delivery uncertain:** inspect the conversation before retrying. Uncertain commands are not automatically resubmitted.
- **`list_turns is not supported yet`:** a narrow fallback exists for loaded threads. The original physical-device error has not yet been confirmed resolved.
- **Open on Mac fails:** iTerm and macOS Automation permission are required. This flow is experimental.
- **No Bark alert:** check notification permissions, Focus, and Mac connectivity; run the explicit test. Never post your key in an issue.

Additional network, signing, and APNs details: [setup guide](docs/setup.md) (Chinese).

## Development and validation

```sh
npm --prefix codex-remote-bridge test
npm --prefix relay test
xcodebuild -jobs 2 -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

Bridge tests isolate device state and mock Keychain. Never point tests at a real pairing directory. Raw physical-device records, local experiments, and old screenshots stay outside the published source. Real model experiments should use an isolated workspace and consume normal Codex usage.

Repeated outages, app force-quit, sleep/wake, daemon crashes, approval races, and long-running use need broader validation. Retained upstream UI for images, voice, Git, or MCP does not imply full support in shared mode. Source directories, the installed app name, and some upstream help screens still use “Codex Remote”; this README defines the fork's supported workflow.

## License, privacy, and support

See [LICENSE](LICENSE), [third-party notices](THIRD_PARTY_NOTICES.md), and [technical research](docs/research.md) (Chinese). Original ISC copyright and dependency notices are retained.

Codex login credentials stay on your Mac. Never publish pairing QR codes, device private keys, Bark keys, APNs keys, or unredacted logs. See [Privacy](docs/privacy.md) and [Terms](docs/terms.md). Report problems in [GitHub Issues](https://github.com/sky-story/CodexLink/issues), with conversations, credentials, personal paths, and device identifiers removed. This fork does not automatically upload diagnostics.
