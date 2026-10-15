# CodexLink

**English** | [简体中文](README.zh-CN.md)

View and control the **same running Codex CLI session on your Mac** from a native SwiftUI iPhone app. Your Mac runs the model and tools; your phone provides live output, Steer, a persistent Queue, Stop, and remote approvals.

The **optional Claude Code extension** adds text history, messages to the same Mac Claude session, and Bark lock-screen notifications in the same app. It uses your existing official Claude account on Mac. Physical phone messaging and automatic response notifications are verified; phone tool approvals still need acceptance.

**Status: Alpha / developer preview.** Intended for users comfortable building from source and troubleshooting. This is a fork of [RealDyllon/codex-remote](https://github.com/RealDyllon/codex-remote/tree/9a737fb), distributed under the ISC license. It is not an official OpenAI or Anthropic client.

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
| Codex session model and reasoning effort | Isolated live-daemon check passed; user confirmed the phone model menu opens, applying a phone change to a task still needs acceptance |
| Remote approvals | One-time approval verified; denial, races, and reconnect with pending approval need further validation |
| Stop | Original Turn interruption verified; **already-backgrounded tool processes may keep running** |
| Continue on Mac | The original Mac TUI remains usable after phone controls |
| Reconnect | One Wi-Fi-to-cellular handoff and one Bridge crash recovery verified |
| Bark lock-screen notifications | Physical test delivery verified; automatic completion accepted by provider; approval lock-screen delivery pending |
| Claude Code notifications | User confirmed automatic response notification on the locked iPhone; simultaneous Codex/Claude completion and approval delivery pending |
| Claude sessions and tool approvals | Preview via official Channels; physical iPhone message/reply verified in the same Mac session; approval relay verified on Mac, physical phone approval pending |
| Open this session on Mac (iTerm) | Implemented, experimental; full physical-device flow and macOS Automation permissions still need validation |

See the [validation summary](docs/validation.md) and [release readiness](docs/release-readiness.md). These are scoped results, not a claim of production reliability.

## How it works

```text
Native Mac Codex TUI ──┐
                      ├── Same Codex daemon / same Unix socket
Mac Bridge ───────────┘
    │
    ├── Local Channel / Hooks ⇄ Claude Code (optional)
    └── Private Relay ⇄ Tailscale ⇄ iPhone SwiftUI app
                      (end-to-end encrypted after pairing)

Codex events / Claude Hooks ── Optional event / session label → Bark → iPhone lock screen
```

A **Turn** is one task execution, ending in completion, failure, or interruption. Queue normally creates a later Turn; Steer adds input to the current Turn.

The Codex composer shows the session's model and reasoning effort, with choices supplied by your Mac's model catalog. Changes apply to subsequent tasks and waiting Queue entries; they do not change the running Turn. Settings are confirmed by the same daemon, with existing approval and sandbox policies preserved. Reconnecting refreshes the configuration; uncertain changes are not automatically resent. Update both the iPhone app and the Bridge to use the selectors.

Codex features require the CLI and Bridge to connect to the **same shared daemon**. Loading history or starting a separate App Server does not share a running task. Sessions started with `--no-daemon` are unsupported; some CLI `-c` overrides may also select an embedded runtime. The optional Claude integration uses the official Channels preview protocol and must be enabled when launching Claude.

The phone and Mac can use different Wi-Fi or cellular networks; a Tailscale exit node is not required. Model requests use the Mac's account and network. The phone does not need the Claude app or a separate model-account login.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac | Able to run Xcode, Codex CLI, and Tailscale; background service uses macOS launchd |
| Codex | Installed and signed in on Mac; verified baseline: **CLI and daemon 0.162.1** |
| Claude Code (optional) | Installed and signed in on Mac; tested with **2.1.300 and an official Pro account**; Channels availability depends on account and organization policy |
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

On first setup, a pairing QR code normally opens in your Mac browser. Scan it **inside the CodexLink iPhone app**. Do not use an online QR decoder.

To display a new pairing code when needed:

```sh
node scripts/private-service.cjs pair
```

Select a safe test conversation and send a simple Queue message. Then try Steer during a longer harmless Mac task.

After **New Chat**, choose whether to open the same session in a new **iTerm** window on your Mac. Choose “暂不” to stay on the phone. An empty session opens a waiting window: send its first message from the phone, then the terminal attaches automatically. It waits up to 30 minutes; Ctrl+C cancels waiting. You can also open a session later from its conversation menu. macOS Automation permission may be required.

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

`accepted` means the provider accepted the request; check the actual lock screen. Notifications arrive through **Bark**. Open CodexLink to handle approvals. This works with free Apple signing; this app's own APNs delivery remains unverified.

Generic notifications are the default. To distinguish concurrent sessions:

```sh
node scripts/bark-notifications.cjs --session-labels on
node scripts/private-service.cjs restart
```

A short event status appears in the title; the **session name and an eight-character identifier appear in the body**. Missing names fall back to the project directory name. Notifications are grouped per session. To disable labels, use `off` and restart.

Bark receives the device key and notification content. With labels enabled, that includes the session name or project basename and short identifier. Chat previews, commands, code, full paths, and raw thread IDs are not sent. Avoid sensitive session names. Focus modes, notification summaries, and network conditions may delay or suppress delivery.

Optional source icons: run `node scripts/bark-notifications.cjs --icon codex default` for the CodexLink icon and `--icon claude default` for the official Claude logo. Restart the Bridge and update installed Claude Hooks; already-running Claude sessions may keep the old sender until reopened. See [icon setup and previews](docs/setup.md#分别显示-codexlink-和-claude-图标), including iPhone image-download requirements.

### 6. Optional: Claude Code notifications

With Bark configured, add notifications for Claude Code running on the same Mac:

```sh
node scripts/claude-notifications.cjs install
node scripts/claude-notifications.cjs status
node scripts/private-service.cjs restart
```

Open a new Claude session to load the hooks. Codex and Claude can notify independently, including when CodexLink is closed. Claude's sender does not require the Codex Bridge to be running. Existing Claude settings and permission hooks are preserved and backed up before installation.

A Claude response notification does not mean all background work has finished. See the [Claude notification guide](docs/claude-notifications.md) (Chinese) for semantics, limitations, verification, and uninstall instructions.

### 7. Optional: Claude sessions in the same app

Complete app, Bridge, and pairing setup above. For lock-screen notifications, also complete step 6. Claude uses its existing official account login on Mac; no additional API key is needed.

Set up the short command once from this repository's root:

```sh
chmod +x scripts/claude-session.cjs
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/scripts/claude-session.cjs" "$HOME/.local/bin/clink"
```

Ensure `~/.local/bin` is on your shell's `PATH`. Use another name if `clink` already exists, and update the link if you move this repository. See [short-command setup](docs/claude-sessions.md#可选使用短命令-clink) (Chinese).

Then run this in the project you want Claude to work on:

```sh
cd /path/to/your/project
clink                           # New session, named after the current folder
```

Confirm **I am using this for local development** when Claude prompts, complete project/MCP consent on Mac, and keep the terminal open. Choose **Claude 会话** in the iPhone sidebar to send messages and read replies. Use separate terminals for separate projects.

Other common commands:

```sh
clink --name "My project"        # New session with a custom name
clink --resume "FULL_SESSION_UUID" # Resume in the original project after its task ends and the original CLI exits
clink --help
```

Without the short command, use `node /path/to/CodexLink/scripts/claude-session.cjs`.

Claude extension scope:

- **Messages and notifications:** phone input reaches the same Mac session; Bark can notify when Claude finishes a response. Physical messaging and automatic lock-screen response notifications are verified. A response notification does not establish that all background work is complete.
- **Quiet background progress:** Claude responses that report in-flight background tasks or scheduled wakeups do not send progress alerts. A later response without those activities can notify; approvals, input requests, and API errors still notify independently.
- **Existing terminals:** ordinary `claude` sessions do not automatically appear in the phone list. Automatic discovery and attaching the channel to an already-running session are not implemented. Ordinary sessions that loaded the notification Hooks can still notify independently.
- **Close and resume:** leaving the phone view does not stop Mac work. Exiting the Mac CLI makes the session offline while retaining history. Find its Session ID with `/status` before exiting, then use `--resume` to continue it; omitting `--resume` creates a new session. Reading history still requires the Mac Bridge connection. Phone-side session launch and a complete offline history cache are not available.
- **Models and controls:** change Claude's model with `/model` on Mac. The phone has no Claude model picker, Stop, or interactive-question responses. One-time tool approvals are implemented and the Mac relay was verified; phone approval, races, and outage recovery still need acceptance.
- **Context and configuration:** channel instructions and reply-tool calls add token usage; local synchronization itself does not call a model. Only text and final responses recorded after integration are shared, without importing old transcripts or streaming full tool logs. The launcher accepts only `--name` and `--resume`; review any model, permission-mode, or prompt flags used in the previous launch separately.

Channels is an official research preview. See the [Claude session guide](docs/claude-sessions.md) (Chinese) for setup, local storage, and limitations.

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
- **`list_turns is not supported yet`:** new chats now explicitly use the supported history format. Previously created paginated chats may still be affected; they are preserved. Phone UI retesting is pending.
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

Bridge tests isolate device state and mock Keychain. Never point tests at a real pairing directory. Raw physical-device records, local experiments, and old screenshots stay outside the published source. Real model experiments should use an isolated workspace and consume the respective account's usage allowance.

Repeated outages, app force-quit, sleep/wake, daemon crashes, approval races, and long-running use need broader validation. Retained upstream UI for images, voice, Git, or MCP does not imply full support in shared mode. The installed app is named CodexLink. Source directories and technical identifiers retain their existing names for compatibility; this README defines the fork's supported workflow.

## License, privacy, and support

See [LICENSE](LICENSE), [third-party notices](THIRD_PARTY_NOTICES.md), and [technical research](docs/research.md) (Chinese). Original ISC copyright and dependency notices are retained.

Codex and Claude login credentials stay on your Mac. Never publish pairing QR codes, device private keys, Bark keys, APNs keys, or unredacted logs. See [Privacy](docs/privacy.md) and [Terms](docs/terms.md). Report problems in [GitHub Issues](https://github.com/sky-story/CodexLink/issues), with conversations, credentials, personal paths, and device identifiers removed. This fork does not automatically upload diagnostics.
