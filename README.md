# Herdr HUD

Keep your agents working while you game. A draggable H button opens your Herdr
agents, recent output, and prompt composer above your desktop or fullscreen Space.

## Why Herdr?

[Herdr](https://herdr.dev/) keeps your coding agents in persistent terminal
sessions and brings their status together across computers. Herdr HUD puts that
setup behind a floating H, so you can read progress and send follow-ups while
you game. Run agents on your gaming machine or connect to a Mac/Linux computer
that hosts them.

Bring your own coding agent and its existing login. The HUD has no separate
account or model subscription; your agent's normal provider costs still apply.

**New to Herdr? [Start with the step-by-step setup guide](docs/getting-started.md).**
It covers installing Herdr, starting your first agent, connecting the HUD,
setting up SSH or Tailscale, adding computers, and troubleshooting.

## See it in game

Read agent replies and send prompts with the panel open over World of Warcraft Classic.

![Herdr HUD agent panel open over World of Warcraft Classic on Windows](assets/wow-panel.webp)

Close the panel to keep just H and its attention badge on screen.

![World of Warcraft Classic with the compact Herdr H button and attention badge](assets/wow-button.webp)

## Download and install

For a first-time setup, follow the [beginner guide](docs/getting-started.md).
Already have agents running in Herdr? Install the HUD below.

Get the latest [alpha downloads](https://github.com/finna/herdr-hud/releases/tag/v0.1.0-alpha.1):

- **Apple Silicon Mac:** [Download Herdr HUD.dmg](https://github.com/finna/herdr-hud/releases/download/v0.1.0-alpha.1/Herdr-HUD-macOS-arm64.dmg).
  Open the DMG, drag **Herdr HUD.app** onto the **Applications** folder inside,
  then eject the DMG and open Herdr HUD from Applications. Requires macOS 13+;
  Intel Macs are not included in this build.
  The Mac downloads are **Developer ID signed and notarized by Apple**.
  macOS may ask you to confirm opening an app downloaded from the internet.
  If you downloaded an earlier unsigned copy, download again and replace it.
- **Windows 11 x64:** [Herdr-HUD-Windows-x64.zip](https://github.com/finna/herdr-hud/releases/download/v0.1.0-alpha.1/Herdr-HUD-Windows-x64.zip).
  Extract the whole ZIP into a folder, double-click **Install.cmd**, then open
  **Herdr HUD** from Start. The installer runs as your normal user. Keep all files
  together if running HerdrHUD.exe directly instead.
- **Omarchy Quattro:** use the existing [Omarchy plugin](https://github.com/finna/omarchy-herdr-hud).
  `omarchy plugin add https://github.com/finna/omarchy-herdr-hud.git --enable`.

Download from this repository and compare the release's SHA256SUMS.
The Mac app and DMG have stapled Apple notarization tickets and pass Gatekeeper
assessment. The **Windows package remains unsigned** and may show an
unknown-publisher/SmartScreen prompt; only proceed if you trust and have verified
this download.

Close the HUD and preserve drafts before installing an update. No agent servers
need to be restarted. To uninstall, quit the HUD, turn off its optional login
startup, and remove the app; on Windows also remove its Start menu shortcut.
Settings locations are documented below.

## Run on macOS

Requires macOS 13+, hc 0.1.21 (or legacy Herdr 0.9+) installed with an existing running default session,
and existing SSH authentication for any saved remote machines. No account,
model API key, Python runtime, Node runtime, or hosted service is required to
run the packaged app. Xcode command-line tools are needed to build from source.

- Click **H** to open or close the agents. Drag H to reposition it.
- **Command–Option–H:** toggle the agent panel.
- **Command–Option–Shift–H:** hide or restore the whole HUD.
- **Escape:** close the panel while keeping H visible.
- The open panel takes application focus for typing, paste and dictation. Closing
  it returns focus to the previous app when the HUD still has focus. H and alerts
  remain passive overlays.
- **Enter:** send a prompt to the selected ready agent.
- **Control–Enter or Shift–Enter:** insert a new line (Command/Option–Enter also insert a new line).
- The **H menu-bar item** has visibility, alternative shortcuts, launch-at-login,
  refresh, and quit controls. Login startup is off by default and remains unverified.
- Drag the roster divider to resize it. Visibility, position, view, and divider
  width are remembered. On macOS, prompt drafts and staged images are saved locally
  per exact agent session and restored after restart. **Saved drafts** recovers drafts
  from replaced sessions without silently sending them to a different agent.
- Agents needing attention sort first, then working agents, then read idle agents.
- Silent alerts appear above H (below it near the top edge) after an agent finishes or needs input. Hover to
  retain one, click to open its agent, or dismiss it. The attention badge remains.

## HUD workflow additions (macOS source build)

- **Draft recovery:** text, image thumbnails and uncertain-delivery blocks survive
  restart. Drafts are private local files, not cloud sync. Storage errors stop sending
  and normal quit so you can copy your work first.
- **Unread replies:** a New badge marks agents that finish or need input. While
  you read older output, **Jump to latest** reveals the queued update.
- **Waiting states:** Ready, Working, Finished, Needs approval, Has a question,
  Needs sign-in and Offline make the next action clearer.
- **Files in replies:** local file buttons open supported images/PDFs in Preview,
  text/code in TextEdit and office documents in Quick Look. Remote files and
  executable attachments are not offered.
- **Chat settings:** The gear in each chat header lets you show prompt shortcuts and handoff independently. Both start hidden. The HUD remembers your choices for each session.
- **Quick prompts:** **Edit shortcuts** saves up to six named prompt buttons.
  Clicking one adds text to your draft; you still choose Send.
- **Guarded number keys:** recognized menus can show literal **Send 1–4** buttons
  only with the companion patched hc core and newly created compatible terminal
  holders. They send one digit after checking the observed screen; terminal
  keybindings determine the effect. These are not semantic approval API buttons.
  Stock hc and existing holders retain manual arrow/Enter/Escape controls.

### Agent handoff on macOS

Enable **Show handoff** in the chat gear, then click **Handoff…** above the composer to prepare a briefing for another local
Claude, Codex or managed OpenCode session. Choose the destination, edit the brief,
and use **Add to target draft**. The HUD packages a bounded snapshot of recent
output, source project details and available file references; it does not claim
to transfer the full conversation history. You can opt in to including the
source's unsent draft and copying its staged attachments.

The handoff appends to the destination's existing draft and preserves the source.
Review the destination draft and choose Send when ready. Creating a handoff does
not send, queue, approve anything, stop either agent or change its project folder.
Existing queues stay separate; queued delivery pauses while the review is open. Changed sessions, unavailable destinations,
uncertain delivery and storage/capacity errors block staging instead of replacing
work. Both sessions must be local; file references are not uploaded to a remote
machine. Windows does not yet advertise handoff support.

### Multiple prompts while an agent works

On macOS, **Queue prompt** saves follow-ups for Claude Code and existing Codex
terminal sessions while they work. Claude Code launched through a model router
uses the same queue. Prompts and images remain with their exact session, survive
HUD restart, and appear in a removable FIFO list. The HUD delivers one at a time
when the agent reports idle; it can keep delivering while its panel is closed.
The HUD must remain running. Permission/sign-in screens stop delivery.

After a restart, queues pause until you inspect Herdr and click **Continue queue**.
A missed Working → Ready transition also requires that explicit action, rather
than risking duplicate submissions. Changed sessions keep their old queue in
**Saved drafts** for explicit recovery. Unknown delivery outcomes stop the queue;
there are no automatic retries. Limits are 16 prompts per session, 128 total,
sharing the existing draft text and image storage limits.

A Codex chat created with **New Codex…** can instead show **Send update** while
its native connection knows the active turn. This sends a structured update to
that exact turn and waits for its acknowledgement. It never falls back to
terminal keys or a different turn. **Queue instead** saves it for the next task.
If that mode is unavailable, **Queue prompt**
remains available. Queued terminal prompts start after the current task finishes;
they do not steer it mid-task.

### MP4 attachments on macOS

Drop MP4 files into the HUD, copy an MP4 in Finder and paste with Command-V,
or use **Attach files**. Up to three images/videos can be attached together;
New MP4 imports may be up to 50 MiB each. Existing valid saved videos up to the previous 100 MiB limit remain readable. A thumbnail with a play badge appears in the
composer. Click it to open the private copy in the HUD’s video player.

Videos stay with their exact draft or queued prompt, including after restart.
The HUD keeps a private local copy; moving the original does not break the draft.
On Send, the HUD prepares six timestamped frames as a contact sheet and transcribes
spoken audio locally with whisper.cpp. Local Claude, Codex and managed OpenCode
receive the images, automatic transcript and original MP4 reference. This samples
the video; brief events between samples and non-speech sounds are not captured.
Agents can use the original file for closer inspection. Analysis supports clips up
to ten minutes; preparation failures retain the draft without sending it.

Speech needs an installed Homebrew `whisper-cpp` and a local tiny/base/small ggml
model under `~/Library/Application Support/Herdr HUD/Transcription` (the existing
HyperFrames model cache is also recognized). No engine or model is downloaded at
runtime. English-only models are labeled in the transcript. Automatic transcripts
can contain errors. Preparation runs separately from roster polling.

OpenCode requires a model marked **Vision** in the Orca picker. Open a new chat
from the updated picker to apply its image capability configuration; older chats
are preserved and refuse image/video sends if that capability is missing. Text-only
models cannot inspect the video frames. Remote video attachments are unsupported.
No video is sent to an external service merely by attaching or previewing it.

Video cache storage is capped at 512 MB/128 clips. Completed copies are retained
because sent or uncertain prompts may still need them. Incomplete imports expire.
Snapshots containing videos use version 3; older HUD builds refuse these rather
than silently dropping attachments. Image-only snapshots remain version 2.

### PDF analysis on macOS

Attach a PDF up to 100 MiB/200 pages. On Send, the HUD renders every page locally
at up to 2000 pixels on its longest edge and runs Apple Vision OCR, including on
pages that already have embedded text. Local Claude, Codex and managed OpenCode
receive one labeled contact sheet per PDF (at most six evenly sampled pages),
embedded text and OCR excerpt, and paths to the original private PDF and the full
page-marked text artifact. OpenCode requires a Vision model. The sheet is sampled
visual coverage; diagrams, small details and unsampled pages need closer inspection
of the original PDF with local tools. Automatic OCR can miss or misread content.

Analysis runs in the background before sending. A checked 180-second analysis
deadline, 20-second OCR cancellation deadline per page, 2 MB full-text limit, and
cache capacity failures retain the draft without sending. Native page rendering
is synchronous, so these checks are not a guaranteed wall-clock timeout. The full
text is kept privately alongside the PDF within its 512 MiB cache budget;
the prompt includes a 12 KB excerpt and explicitly marks truncation. No OCR engine,
model download or cloud OCR service is needed. Remote PDF attachments are unsupported.

### Word attachments on macOS

Drag a `.docx` into the HUD, copy it in Finder and press **Command-V** in the
composer, or choose it with **Attach files**. Click its DOCX chip to preview the
original document in a native read-only Quick Look window; Command-W closes it.
Word files share the three-attachment limit and can be up to 100 MiB each.
Private local copies survive moving the original, draft recovery and queued
prompts. Drafts containing Word documents use snapshot version 6; earlier
snapshot formats remain readable.

On Send, local Claude, Codex and managed OpenCode receive the document's body,
table row/cell boundaries and available headers, footers, notes and comments.
The HUD includes a quoted excerpt plus the full structured-text artifact and
original DOCX paths. Up to six supported embedded raster images appear in one
labeled overview; OpenCode needs a Vision model when that overview is present.
Text-only documents do not require Vision. The overview is not a page rendering:
exact layout, image placement, merged cells, charts and SmartArt need closer
inspection of the original. Revisions and field instructions are labeled rather
than evaluated. External hyperlinks are not fetched.

Encrypted, macro-enabled and externally linked media/template packages are
unsupported. Archives are checked before preview or sending, with 512 entries,
8 MiB per entry and 32 MiB expanded limits. These analysis bounds still apply
to a large original DOCX, so a package containing an individual image over 8 MiB
or more than 32 MiB of expanded content must be exported in a smaller form. Full extracted text is limited to
2 MB; the prompt excerpt to 12 KB. The private Word cache is capped at
512 MiB/128 documents. Errors retain drafts without sending a partial result.
No Word installation or document-conversion service is required. `.doc`, `.docm`
and remote Word attachments are not supported.

### Change the model in an existing chat

On macOS, select a local Codex or Claude chat and click **Model**. The HUD
opens that chat's native model picker when the terminal reports idle and its
composer is empty. Click a listed model or use **Up** and **Down** to highlight
it. In Codex, highlight **GPT-6.2-Astra**, click **Continue**, then choose an
effort and click **Use selected**. In Claude, highlight an Anthropic model and
click **Use selected**.
The provider's session-only action applies the choice to the open chat.

The HUD shows the current picker and checks the exact session and complete
terminal screen before each key. Keep the Herdr terminal untouched while using
these controls. Stock hc can delay a key while it waits for quiet and the screen
can change during delivery. If the HUD cannot verify the picker, clear or close
it in Herdr and click **I checked Herdr — continue**. The HUD holds prompts for that chat while
the picker is active. The picker uses the model options the provider offers in
the terminal, so model availability depends on the session and account.

### OrcaRouter models through OpenCode

On macOS, **Orca models** appears inside a managed OrcaRouter OpenCode conversation and opens a searchable, collapsible model picker. It stays hidden for Claude, Codex and other OpenCode agents. Herdr’s OrcaRouter launcher can still open the picker to create the first chat. Select a
model, click **Open new OpenCode chat…**, then choose its project folder. Changing
the dropdown alone does not launch anything or change an existing chat.

The picker intersects OrcaRouter’s live catalog with verified release dates and
OpenAI-compatible chat support. It excludes Anthropic/Claude, OpenAI/GPT/Codex,
automatic routers, models older than four calendar months, future releases and
models without a verified release date. Refresh updates availability and the
rolling cutoff; the bundled release registry must be updated to admit newly
dated models.

Managed sessions use OpenCode 2.1.4 with a dedicated authenticated loopback server
and one eligible model per session. Credentials come from the existing macOS
Keychain item `ORCAROUTER_AUTH_TOKEN`; they are not stored in launch arguments or
session files. The feature requires a local OpenCode installation, Python 3 and
that existing account credential. It does not change Claude’s provider or default.

The HUD supports text, image attachments and durable follow-up queues for these
managed sessions through OpenCode’s native API. Existing unmanaged OpenCode
terminals are read-only. A changed session, model or server stops sending;
uncertain delivery requires inspection and explicit reconciliation. Permission
and question prompts remain in the OpenCode terminal. This feature is not yet
implemented in the Windows host.

### True Codex tool approvals

**New Codex…** opens a fresh Astra/medium chat in Herdr with native approval
integration. Choose a project folder and complete any Codex startup prompts in
the new terminal. Existing chats keep running. After the new chat's first prompt,
the HUD connects to that exact chat and shows supported Computer Use/MCP tool
permission requests as **Allow**, **Allow for this session**, **Always allow**
(only when offered), and **Cancel** buttons.

These send structured decisions to the original Codex request ID, not keys.
The terminal can still answer; resolved requests disappear from the HUD. Pending
responses are not retried. A disconnected or changed session invalidates its
buttons. The card identifies the linked chat UUID; changing chats with /new does
not silently rebind the HUD. Other forms, sign-in and verification prompts, and
shell/file permission menus remain in the terminal.

The new mode uses stock Codex 0.169.0, a dedicated local app-server and the stock
remote TUI. The connection is a private Unix socket, with no network listener or
copied credentials. Session descriptors are private files under Application
Support/Herdr HUD/CodexSessions. The service and TUI are separate hc terminals;
Herdr tool-parent context refers to the service terminal. Do not treat that
service as a second user-facing agent.

A fresh chat initially has no resumable history; the HUD waits for the first
prompt to materialize it. If Codex reports its transient history-not-ready error,
wait for the first prompt to start and click **Reconnect**. Existing embedded
Codex sessions cannot be attached in place through this API. This feature does
not restart them or migrate their chats.

The optional guarded-number backend is separate, tested source work and remains
uninstalled. True native tool approvals do not depend on that core patch.

## Run on Windows

Requires Windows 11 x64 for the currently tested build, Microsoft Edge WebView2
Runtime, and either local Herdr 0.9+ or SSH access to an existing Mac/Linux Herdr setup.
The build includes its .NET runtime. Node and a .NET SDK are not needed to run it.
Windows 10 and ARM64 are untested.

Open **Herdr HUD** from Start. Right-click the tray H and choose **Herdr connection**.
Leave the SSH target blank to use this PC's Herdr installation, or enter your
existing Mac/Linux SSH target and session. In SSH-source mode, the HUD reads that
host's saved Herdr machines and accesses them through the source host, using its
existing SSH aliases and credentials. It does not copy private keys or enroll
machines. Root and saved-host authentication must already work without prompts.

- **Ctrl+Alt+H:** open/close the agent panel.
- **Ctrl+Alt+Shift+H:** show/hide the entire HUD.
- Alternative Ctrl+Win shortcuts and shortcuts-off are available in the tray menu.
- H is draggable. Escape closes the panel; Enter sends; Ctrl/Shift+Enter adds a line.
- Launch at login is optional and off by default. Quit from the tray menu.
- The panel can be resized from its right and bottom edges.
- Notifications appear above H (below it near the top edge) and follow it when moved.

The Windows package is currently unsigned. It runs as your normal user and uses
WinForms, WebView2 and native topmost windows. It does not inject into games or
install a driver. **Exclusive fullscreen is not yet verified.** A visible overlay
and focus return over a test window do not prove compatibility with your game.

Settings and private diagnostic snapshots live in `%LOCALAPPDATA%\Herdr HUD`.
The installed app lives in `%LOCALAPPDATA%\Programs\Herdr HUD`.
The executable supports the same basic `--open`, `--close`, `--show`, `--hide`,
`--toggle`, `--roster`, `--inspect`, `--snapshot`, and `--verify-ui` controls.
Results are written under its private support directory. `--fixture` briefly
creates a test window, clicks only that window and H, checks focus/order, captures
that display, and then restores the prior window and pointer. It is a development
test, not an exclusive-fullscreen game test. Do not run it during active gameplay.

## Herdr connection

For commands and examples, see [connecting the HUD](docs/getting-started.md#install-and-connect-the-hud)
and [adding more computers](docs/getting-started.md#add-more-computers).

On macOS the HUD prefers `hc` in its standard user or Homebrew install. It uses
`hc connect` with JSON-RPC over stdin/stdout to read existing Claude and Codex
terminals in the default core session. `herdr.space`, `herdr.tab` and `where`
labels supply their workspace/tab context. Other foreground programs are omitted.
The core routes saved machines itself, including named sessions and `--via`
profiles; disconnected machines retain cached cards marked offline. This hc path
is currently macOS only. Windows continues to use legacy Herdr.

The hc path binds each card to its core, permanent terminal address, creation
time, foreground process and reported provider. It checks those facts and machine
routing again before reading or sending. Only a matching provider's explicit
`idle` status enables sending; unknown, busy, blocked and `done` statuses remain
read only. Sends use the core's atomic `if: idle` condition without `force`.
The transport waits up to 75 seconds for delivery, then treats a missing or invalid
acknowledgement as uncertain and retains the draft. Inspect the terminal before
using the composer's explicit reconciliation control. Nothing is automatically retried.
The core cannot atomically bind a send to the expected foreground process, so a
process replacement between the final check and submission remains a narrow race.

When hc is absent, the app reads `herdr machine list --json` from your existing installation. It
lists the local default session and enabled saved SSH machines, respecting each
remote profile's named session. It does not enroll machines, create teams,
restart Herdr, or install/update anything on remote computers. Machine discovery
is one level deep, matching the host's configured Herdr machines.

Local Herdr is located in its standard user or Homebrew install, then on PATH.
Remote reads and sends use installed SSH with existing configuration, batch
mode, and strict host-key checking. Herdr must be available in its standard
remote user install, Homebrew path, or login PATH. Remote Mac/Linux hosts need Python 3 for a small, standard-library-only prompt
helper. It runs over SSH without installing files and forwards text from stdin
to the host’s Herdr socket. Local Mac/Windows prompts use native socket/pipe
clients and do not require Python. Complete authentication and
host-key setup in Herdr first; the HUD does not open hidden SSH questions.

Agent identities include machine, target, session, pane, terminal, and available
conversation identity. Each read/send rechecks the identity; sends also recheck
readiness and the saved machine configuration. Busy/blocked/unknown/offline
agents cannot receive prompts. Missing machines keep cached cards marked offline.

Herdr 0.9 does not atomically bind a prompt to an expected terminal ID. A fresh
identity check reduces risk, but another client can still replace a pane between
check and submission. Sends are serialized and never automatically retried.
An ambiguous result retains the draft and blocks another send until the user
inspects Herdr and explicitly reconciles it.

Chat is a conservative formatting of recent captured Codex terminal output,
not full structured conversation history. Other agents retain Terminal view.
On macOS hc, explicitly reported blocked permission/question screens have manual
**Up**, **Down**, **Enter**, and **Cancel (Esc)** terminal controls above the
composer. Review the exact current screen there before every click. These forward
one named key each; Enter submits whatever the terminal has selected. hc waits
for terminal output to become quiet, so delivery may be delayed. Identity and the
complete current screen are checked before forwarding, but hc has no atomic
question/screen condition: the screen can change during delivery. These are manual
terminal controls, not buttons bound to a particular permission choice.

A changed, incomplete, expired, or unsupported preview is refused and refreshed.
A key has no automatic retry; uncertain delivery blocks further keys until you
inspect that agent in Herdr and explicitly enable another key. Agent statuses
without an explicit permission/question kind, legacy Herdr, and Windows remain
read only for native questions. Regular prompt sending still requires idle.

Codex's recognized Computer Use approval menu is formatted with the full question,
aligned option labels, descriptions, and current terminal selection. Unrecognized
menus retain their plain terminal text. Clearly listed ordinary next-step choices
may appear as suggested replies: clicking one appends its text to your draft for
review and editing; Send remains a separate action.

## Shepherdr mode (Mac)

If you run [Shepherdr](https://github.com/eliasstravik/shepherdr) on this Mac, the
**Herdr | Shepherdr** switch above the roster shows your Shepherdr spaces instead
of raw Herdr agents. Each space appears as its coordinator, with its tasks under
it: task id, title and status (needs you, ready to merge, working, queued, merged
and so on). Needs-you tasks, and coordinators that ask you something, count
toward the H badge. Open a coordinator or task to read its recent output and send
a follow-up with the same composer. The choice is remembered with your other
preferences; Herdr mode is unchanged.

Spaces and tasks, across all machines, come from the local Shepherdr server's
read-only snapshot (`127.0.0.1`, the port in `~/.shepherdr/server.json`). Each
coordinator or task is linked to the herdr agent Shepherdr started for it by the
herdr agent name in Shepherdr's own agent records (`~/.shepherdr/agents.json`,
and `~/.shepherdr/machines/*/` for other machines). Nothing is guessed from pane
names. A coordinator or task without exactly one matching running agent (a
merged task, for example) opens read only, showing its latest Shepherdr chat
messages; for spaces on other machines this needs a running agent. A selected
task stays selected, with its draft, when its agent starts, finishes or is replaced. Reads and prompts then use the same checked Herdr path as Herdr mode, so
stale, busy, blocked and unknown agents are refused and sends are never retried.
A prompt goes straight into the agent's terminal, as if typed there.
`HerdrHUD --roster --shepherdr` prints the live read-only roster. The Windows
app does not have this mode yet; its switch stays hidden.

## Prompt privacy and output limits

Prompt text never appears in process arguments or SSH command strings. It travels
over stdin across each SSH hop, then through Herdr's local socket API. The native
hosts and remote helper recheck the expected agent and validate acknowledgements.
Unknown delivery is never retried automatically.

Native command output is streamed with a 1 MiB stdout and 64 KiB stderr limit,
with 12-second Mac / 15-second Windows deadlines (75 seconds for macOS hc prompt delivery). Mac commands start in their own
process group; Windows commands are created suspended, assigned to a kill-on-close
Job Object, then resumed. Timeout or overflow terminates the owned group/job,
including descendants. The remote helper caps socket replies at 1 MiB and status
output at 64 KiB, and has a 12-second deadline. Prompts are limited to 60 KB.

## Architecture

- `Sources/HerdrHUD/App.swift`: AppKit composer and passive overlay panels, fullscreen Spaces,
  menu-bar controls, Carbon shortcuts, monitor positioning, and WebKit bridge.
- `Sources/HerdrHUD/Transport.swift`: bounded process groups and native socket prompts.
- `Sources/HerdrHUD/HC.swift`: macOS hc JSON-RPC discovery, checked reads and prompts.
- `Sources/HerdrHUD/Herdr.swift`: saved machine
  discovery, cached roster, fresh identity/readiness checks, literal SSH quoting.
- `Sources/HerdrHUD/Resources/`: reusable UI and transcript/attention logic.
- `Windows/`: native Windows shell, WebView2 bridge, and local/SSH-source transport.
- No HTTP listener, browser credentials, third-party model connection, telemetry,
  Squad integration, or tablet interface is included.

Only bundled files are loaded in the WebView. Its content security policy blocks
network requests. Terminal output is rendered as text, never executable HTML.
UI requests use a narrow native operation allowlist and main-frame checks.

Preferences use the `org.herdr.community.hud` defaults domain. Diagnostics and
explicitly requested panel snapshots live in `~/Library/Application Support/Herdr HUD/`.
Snapshots contain private agent output; do not include them in public releases.
The app itself requires neither Accessibility nor Screen Recording permission.
Those permissions may be needed by external tools to verify gameplay interactions.

## Build from source

These steps are for developers. Downloaded apps do not require the build tools.
Run commands from a clone of this repository.

### macOS build

Install Xcode command-line tools, then:

```sh
scripts/build-app.sh
mkdir -p ~/Applications
cp -R 'dist/Herdr HUD.app' ~/Applications/
open "$HOME/Applications/Herdr HUD.app"
```

Local builds default to ad-hoc signing. Published Mac downloads use Developer ID
signing and Apple notarization. Broader hardware/game verification remains future
release work.

To build a drag-to-Applications disk image locally, run
`scripts/package-macos-dmg.sh`. It creates a DMG in `dist/` with the app and an
Applications shortcut. By default this development package is also ad-hoc signed;
changing the download format does not remove Gatekeeper warnings. Maintainers can
prepare a signed and notarized DMG using the [macOS release guide](docs/macos-release.md).

### Windows build

To build with the .NET 10 SDK installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/build-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/install-windows.ps1
```

## Checks

```sh
swift test
node --test Tests/*.test.cjs
node --check Sources/HerdrHUD/Resources/app.js
python3 Tests/test_prompt_helper.py
```

Shepherdr tests use a fixture snapshot and temporary agent records, never the
live Shepherdr server. Node is needed only for JavaScript development tests; Python 3 is used by socket
fixtures and remote-helper tests during development. Swift tests exercise
identity changes, readiness, argument quoting, ambiguous delivery, large output,
saved-machine removal, offline caching, and reconnects with controlled transports.
They do not prompt active user agents. An optional real-hc integration test runs
only when `HUD_HC_INTEGRATION_BINARY` points to an installed hc. It creates a
separate scratch core/session and a dummy program, checks that its core identity
differs from the user's core before creating any terminal, and tests delivery only
to that dummy. It requires permission to create a local Unix socket.

With the app running:

```sh
"$HOME/Applications/Herdr HUD.app/Contents/MacOS/HerdrHUD" --open
```

The executable also supports `--close`, `--show`, `--hide`, `--toggle`,
`--roster` (read-only live JSON), `--inspect`, and `--snapshot` (own panel only).
`--verify-ui` checks live local/remote reads, draft retention, view switching,
search, text safety, and layout without sending prompts. It requires both hosts.

`scripts/fullscreen-probe.swift` creates an isolated temporary fullscreen window,
opens the HUD, records the window order and foreground application, closes the
fixture, and restores the prior app. Its evidence is stored under `.evidence/`.
This verifies macOS fullscreen window behavior, not actual gameplay or mouse input.

## Release boundary

Mac and Windows alpha. Verify real games, pointer/keyboard focus return, drag across
monitors, alert interactions, physical shortcuts, login startup, and restart
behavior before broad release. Intel Macs and older macOS releases are untested.
Windows exclusive fullscreen and other Linux compositors require further work
and game tests; ordinary always-on-top flags alone are not the release criterion.

MIT licensed. Derived from Alex Finn's MIT-licensed Herdr HUD for Omarchy.
Community project; not affiliated with Herdr or Basecamp.

Implementation references: [Apple fullscreen overlay behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications) and [Herdr CLI host/session scope](https://herdr.dev/docs/cli-reference/).

On macOS, **Previews** beside Chat/Terminal shows up to 24 recent local images
from the agent's folder and `outputs`. Use **Choose folder…** if its project
folder differs. Click a thumbnail to open a read-only copy in Preview; edits to
that copy do not change the original. Remote image previews are not supported.

### Attach local images on macOS

For local Claude, Codex or managed OpenCode chats, drop PNG, JPEG, WebP or GIF
files, copy them in Finder and press **Command-V**, or choose **Attach files**.
Up to three files share a prompt. Original images can be up to **100 MiB** and
250 million pixels. Thumbnails stay with the exact draft, queue or handoff and
survive restart. Click a thumbnail for a native read-only preview of the original.

The HUD keeps a private checked original and prepares a JPEG overview of its
first frame, at most 2000 pixels on the longest edge and 4 MiB, for the agent's
image tools. The prompt also supplies the original local path for full detail.
Animation, transparency and tiny details may differ in the overview; local tools
can read the original. Unsupported or failed decoding refuses the attachment.
The image/Markdown cache is capped at 512 MiB/128 originals; existing files are
retained because sent or uncertain prompts can still need them.

Browser files stream to the native host in 1 MiB chunks; WebKit never decodes a
large original image. No agent receives anything until **Send prompt**. Delivery
uses the existing guarded transport and never retries an uncertain send.
Remote, legacy Herdr, and Windows attachments are unavailable. Text prompting and
dictation continue to work normally.

### Markdown attachments on macOS

Drop `.md` or `.markdown` files into the HUD, copy them in Finder and press
**Command-V**, or choose them with **Attach files**.
UTF-8 files up to **10 MiB** each share the three-file limit. The HUD stores the
entire original in a private immutable cache and opens a native read-only preview.
Local Claude, Codex and managed OpenCode receive its full local path plus a bounded
quoted preview. They can read the entire original with local tools, in chunks as
needed; no content is removed from the saved file. The prompt explicitly asks for
that full read and labels the excerpt's coverage. A vision model is not needed.

Large Markdown and new image references use snapshot version 7; older builds
refuse those snapshots rather than dropping files. Legacy inline Markdown and
image drafts still load unchanged. Queue and handoff copies preserve the same
opaque original reference. Invalid UTF-8, NUL characters, unsupported processing
or cache limits fail explicitly and preserve the draft. Finite limits protect
local memory and provider payload sizes; files are not unlimited.

### PDF attachments on macOS

Drop a `.pdf`, copy it in Finder and press **Command-V**, or use **Attach files**.
PDFs up to 100 MiB/200 pages share the three-file limit. Click the filename chip for
a native full-document preview with scrolling and zoom; Command-W closes it.
Unlock password-protected files before attaching. Private copies survive moving
the original, draft recovery and queued prompts (snapshot version5).

On Send, the HUD performs [local all-page OCR and sampled visual analysis](#pdf-analysis-on-macos),
including scanned and mixed pages, and provides the original PDF plus full text
artifact for closer inspection. Local Claude, Codex and managed OpenCode are
supported; OpenCode requires a Vision model. Attaching or previewing sends nothing
to the agent.
