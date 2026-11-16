# Mac preview handoff — September 14, 2026

The source lives directly on the Mac Studio at `~/Projects/herdr-hud-desktop`.
The installed app is `~/Applications/Herdr HUD.app`. This is a native AppKit app
with a bundled reusable WebKit interface and a Swift Herdr/SSH transport.

## Current functionality

Floating draggable H button, agent roster from the local default Herdr session
and enabled saved machines, per-host status, recent output, Codex Chat and plain
Terminal views, expandable tool activity, model metadata, working timer, prompt
composer, per-agent drafts, unread badges, silent hoverable alerts, roster resizing,
saved visibility/position/view preferences, menu-bar controls, two shortcut presets,
and optional macOS login registration. There is no Squad or tablet component.

The first live roster resolved 13 Mac agents and 7 remote agents. Live UI checks
read both hosts and passed draft retention, view switching, search, safe text
rendering, and layout checks. The installed app's diagnostics confirm resources
come from the app bundle rather than the build checkout.

13 Swift tests and 5 JavaScript tests pass. Tests cover machine and session scope,
stale/replaced agent refusal, busy/blocked/unknown refusal, literal arguments,
uncertain sends without retries, large output, machine removal, offline cached
cards, and reconnection. Prompt delivery tests use controlled transports; there
has been no test prompt sent into active user conversations.

## Runtime evidence

Private evidence files, excluded from Git:

- `.evidence/fullscreen-probe.json`: exact fullscreen fixture window ID, on-screen
  ordering, overlap, HUD frames, and foreground app. The probe closes itself.
- `.evidence/visibility.json`: show/hide/open/close checks.
- `~/Library/Application Support/Herdr HUD/ui-verification.json`: live WebKit
  integration checks. No Send click occurs during this verification.
- Same directory: `diagnostics.json`, `ui-check.json`, `panel-preview.png`.
  The panel screenshot contains real private agent output. Do not publish it.

External screen capture and accessibility were denied to the SSH test process.
Own-WebView snapshot rendering worked and was visually inspected. Window ordering
can be queried without screen capture. These checks do not establish physical
mouse/keyboard behavior over an actual game. That remains the next Mac test.

## Resume

Read README.md and AGENTS.md. Check the existing app and diagnostics before
restarting anything. The user can already click the gold H or press Command–Option–H.
Command–Option–Shift–H toggles visibility; the menu-bar H is always available.

Use `scripts/build-app.sh` to build the local preview. To replace it, quit only
this app, copy the built bundle into `~/Applications`, and reopen it. Once the
user starts using the app, preserve their draft or coordinate the reload first.
Herdr servers and agent sessions are independent and must remain running.

Remaining release work: actual game and physical-input validation; monitor
hot-plug/drag and alert interaction checks; login startup test; installer icon,
public signing/notarization, and broader macOS/Intel coverage. The interface is
prepared for reuse, but Windows and new Linux shells have not been implemented.
The user has a Windows gaming PC for later testing and requested Mac-first work.

## Composer shortcut update

Enter sends; Control/Shift/Command/Option–Enter insert a newline at the cursor
and preserve the per-agent draft. IME composition Enter is left to the input
method, and held Enter does not submit repeatedly. The visible hint is updated.


## Windows alpha — September 14, 2026

The same repository now includes `Windows/` and `Windows.Tests/`. The canonical
Git checkout remains on the Mac; Windows has a source copy under
`~/Projects/herdr-hud-desktop`. Do not treat the Windows copy as a second repo.
The source has no GitHub remote and has not been published.

Windows uses .NET 10 WinForms and WebView2, sharing the exact Mac HTML/CSS/JS files.
Its host provides a draggable H, resizable panel, tray menu, visibility toggles,
Ctrl+Alt+H / Ctrl+Alt+Shift+H (alternative Ctrl+Win), optional startup, silent alerts,
DPI-aware initial sizing, a narrow WebView bridge, and user-only named-pipe controls.
Foreground changes reassert topmost positioning without activating the HUD.
The app runs as the normal desktop user, not an elevated task or service.

The user's PC has no local Herdr install. Its private connection preferences point
to the existing Mac setup; saved remote profiles are executed from that source
host so its aliases and credentials continue to work. The Windows key was created
on Windows and its public key authorized on the Mac. No private key was copied.
A Mac host key obtained through the existing trusted connection was pinned on
Windows. Source credentials and addresses are absent from repository files.

Installed Windows app: `%LOCALAPPDATA%/Programs/Herdr HUD/HerdrHUD.exe`.
Start menu shortcut: Herdr HUD. Preferences, diagnostics, UI checks and screenshots
are under `%LOCALAPPDATA%/Herdr HUD`. Screenshots contain private output and can
include other desktop windows; never publish them. The development SDK was
installed per-user under `%LOCALAPPDATA%/Herdr HUD BuildTools/dotnet`.
The temporary interactive launch task is removed after launch; no background
service or login startup was enabled.

Verification: 12 Windows transport tests, 12 shared JavaScript tests, 13 Swift
transport tests. Both native packages build; Mac ad-hoc signature verifies. The
Windows build script restores its dependency lock and creates a self-contained
x64 package. GitHub checks are authored but have not run on GitHub.

Live Windows WebView checks read 13 source-host and 7 saved-remote agents, preserve
drafts, switch Chat/Terminal, filter the roster, render terminal text safely, and
fit the panel. Visibility controls pass. The 4K desktop uses 150 percent scaling;
the initial panel is now 1410 by 975 physical pixels (940 by 650 design units).
The fullscreen test fixture checks z-order, overlap, synthetic clicks confined to
its own windows, panel focus, return to the fixture, and nonactivating overlays.
It restores the prior app and cursor. This is a borderless test window; actual
fullscreen games and exclusive fullscreen remain untested.

Enter/newline and IME behavior is covered by shared handler tests with controlled
bridges. Prompt transports are tested with fakes; no test prompts went into user
agents. Physical keyboard entry in games, alerts, multi-monitor hot-plug/drag,
login startup, Windows local-Herdr mode, Windows 10/ARM64, public signing/installer
polish and actual games are still release checks. Never claim universal fullscreen
support from the fixture. Keep any user draft before relaunching the installed app.

## Compact reading layout

Removed the footer and its redundant status update, removed the header tagline,
and reduced brand, header, machine-strip and conversation-header spacing. Shared
UI is installed on both Mac and Windows. All 12 JavaScript tests and both live
WebView read/draft/layout checks pass. No native transport changes were made.

## Windows badge and notification placement

The bubble region now unions the circular button with its visible badge, using
winding fill to avoid clipping or holes. Badge geometry and text scale with the
button. Notifications use manual initial positioning and appear above the current
H, below it near the top edge, clamped to that monitor's work area. Visible toasts
follow H when dragged and are raised without activation on foreground changes.
Notification size/padding now respect display DPI.

Verified the installed bubble's native window region with a controlled badge at
64, 96 and 128 pixel sizes; the full badge interior fits at all three scales and
clearing it restores the circular button. The installed `--preview-alert` check
showed the toast 15 physical pixels above H at 150 percent DPI on the same screen,
fully on-screen, with foreground focus unchanged. An actual screenshot over WoW
Classic confirmed the placement. Test tools and screenshots are private support
files, not committed source. The user has also sent messages through the game HUD;
WoW and the panel were observed focused separately while both remained visible.
This does not establish exclusive-fullscreen or other-game compatibility.

## macOS notification placement

Notifications now anchor above H, falling below it near the top edge and trying
either side if needed. Placement is clamped to the button's screen without
overlapping H wherever space permits. Visible alerts follow button movement and
display changes. Their native window level is above H and they are raised when
switching Spaces.

All 15 Swift tests pass, including placement at corners, edges and the middle of
two displays with different origins. The rebuilt installed app's ad-hoc signature
verifies. Its own notification preview reported a 10-point gap above H, fully
on-screen, no overlap, higher window order than H, and unchanged foreground focus.
The private ToastView snapshot also rendered correctly. No test prompts were sent
to user agents. The active composer was empty before the HUD-only relaunch.

The macOS --preview-alert command writes private notification-preview.json and
notification-preview.png under the app support directory. It uses a temporary
preview without activating another app. --inspect now reports draftLength.

## Public alpha preparation

The transport now sends prompts through native local sockets/pipes or a static
Python helper over SSH stdin, including nested SSH from a Windows source host.
Remote Mac/Linux hosts require Python 3; no helper files are installed there.
Native output capture is bounded before decoding. Mac uses posix_spawn process
groups; Windows creates processes suspended and assigns a kill-on-close Job Object
before resuming. Timeout/overflow tears down descendants. Local native socket,
remote helper, stdin privacy, overflow and child-cleanup tests cover the change.

Packaging scripts create Mac arm64 and Windows x64 ZIPs. The first public alpha is
v0.1.0-alpha.1, unsigned/ad-hoc signed, with checksums and explicit installation
instructions. No developer signing identity was available on the build Mac.

Release verification: 19 Swift tests, 16 Windows tests, 12 shared JavaScript tests,
and 5 remote-helper tests pass. Both packaged builds were installed locally after
checking for active drafts. Live UI verification passed local/remote reads, draft
retention, view switching, search, safe text rendering and layout on each platform.
The source privacy pattern scan returned no findings. Package signing remains
ad-hoc/unsigned; alpha release notes distinguish tested behavior from unverified
exclusive-fullscreen, Intel Mac, Windows ARM64 and broader game compatibility.


## macOS drag-to-Applications packaging

A user reported Gatekeeper's cannot-check-for-malware warning with the public
ZIP. The app remains ad-hoc signed and unnotarized. The build Mac still has zero
valid code-signing identities. `scripts/package-macos-dmg.sh` creates a verified
compressed disk image with the app, an Applications symlink, and installation
instructions. It derives the filename architecture from the executable, stages
in a temporary directory, and cleans that directory on exit. This only improves
the copy-to-Applications step; it cannot remove the Gatekeeper warning. Do not
present this DMG as a signed release. Developer ID signing, hardened runtime,
notarization, stapling and a fresh downloaded-copy Gatekeeper check remain
necessary before publishing a release that claims a normal verified launch.

## Prepared Developer ID release workflow

The user renewed their Apple Developer membership. Xcode account setup and a
usable local Developer ID Application identity are still required. Build scripts
now accept HERDR_SIGNING_IDENTITY, use hardened runtime and timestamping for a
Developer ID build, and retain ad-hoc signing by default. The DMG --notarize mode
uses HERDR_NOTARY_PROFILE to submit and staple the app and then the image, checks
Accepted and Gatekeeper assessment, and creates a final checksum. Credentials
stay in Keychain. See docs/macos-release.md for setup and interrupted submission
recovery. Actual signing/notarization remains unverified until credentials are
configured; no notarized release has been published by this preparation.

Preparation checks: all 19 Swift tests pass, development DMG builds and mounts,
bundled UI and app signature verify, and missing credentials/ad-hoc notarization
are rejected before submission. No signed build or notarization service request
was made, and the running HUD was not replaced or restarted.

## Ad-hoc DMG publication

The user explicitly chose to ship the drag-to-Applications DMG while Apple
account/certificate setup remains unresolved. The DMG is an additional asset for
v0.1.0-alpha.1; existing ZIP downloads remain available. README and release notes
make the DMG the primary Mac download and put Apple's Open Anyway steps beside
the installation instructions. Do not claim notarization or warning-free launch.
The DMG contains the app, Applications shortcut, installation instructions and
license. No live HUD replacement or agent restarts are needed for this release.

The mounted DMG and copied-out app passed signature and bundled-resource checks.
The app executable SHA256 exactly matches the original published Mac ZIP, so
this is a packaging-only addition. The existing Mac and Windows ZIP checksums
are preserved; SHA256SUMS gains the DMG entry.

## Signed and notarized Mac downloads — September 15, 2026 UTC

Developer ID Application signing is configured on the release Mac. A missing
Apple Developer ID G2 intermediate caused zero valid identities after the initial
key/certificate import; installing the official intermediate restored validation
without changing trust overrides. Keychain access from SSH can be unavailable
even when local Terminal can use the saved credentials. Run release signing and
notarytool in that local session when needed; the user approves Keychain prompts
and enters passwords directly. No credentials are committed or packaged.

Both app and DMG submissions returned Accepted. Both tickets were stapled and
validated, and both Gatekeeper assessments report Notarized Developer ID. The
DMG's copied-out app and the ZIP's extracted app also pass signature, ticket and
Gatekeeper checks. Mac DMG and ZIP assets at the existing v0.1.0-alpha.1 URLs were
updated together with SHA256SUMS and release notes. Windows ZIP bytes are unchanged.

The signed app with hardened runtime was installed after a fresh empty-draft
check, preserving the prior app in private backup storage. It found 20 agents.
Live UI verification passed chat, terminal, local/remote output, draft retention,
search, safe text and layout; the panel was restored closed with H visible. Wait
for the WebView and roster to load before invoking --verify-ui on a new process.
No test prompts were sent to active agents and no Herdr services were restarted.

Fresh anonymous public Mac downloads matched published checksums. Gatekeeper
accepted the public DMG and its copied-out app after quarantine attributes were
added for assessment; tickets validate. This is a quarantined-file assessment plus
a separately verified live signed-app run, not a fresh-user browser-click test.
The normal confirmation for an internet download may still appear. Users with
older unsigned files need to download again and replace the old app.

## Beginner setup documentation

README now introduces why Herdr is useful and links docs/getting-started.md. The
guide covers agent installation prerequisites, official stable Herdr installers,
starting an agent inside a default session, Mac/Windows HUD installation, local
versus SSH-source mode, Tailscale reachability, public-key setup, a batch SSH
check, saved remote profiles, named sessions, controls, and troubleshooting.
Multi-machine instructions use a Mac/Linux source and distinguish the Windows
HUD's SSH-source mode from Herdr's unsupported Windows saved-machine workflow.
Native Windows servers are not presented as remote SSH targets.

Build commands moved into a developer section without changing them. Commands
were checked against Herdr 0.9.0 CLI help, official docs, and current HUD source.
Both documents passed relative-link/anchor and code-fence checks; all 17 external
links in the beginner guide returned HTTP 200, including both download assets.
This is a documentation-only change; no applications or agent servers were
restarted, no setup commands mutated live Herdr state, and release binaries were
not rebuilt. A fresh-user installation walkthrough was not performed.

## Shepherdr mode — October 29, 2026

The Mac roster has a Herdr | Shepherdr switch (defaults key `rosterMode`). In
Shepherdr mode `Sources/HerdrHUD/Shepherdr.swift` reads `GET /api/snapshot` from
the local Shepherdr server (the CLI's `space list` and `task list` cover only
this machine and omit each task's space) and links coordinators and tasks to
herdr agents through Shepherdr's agent records (chat key → herdr agent name).
Only spaces, tasks, asks and attention requests are kept from the snapshot.
Sending reuses `HerdrClient.prompt` unchanged. A row with no running agent opens
read only through `GET /api/chat`, only for chat keys the last roster listed. Shepherdr's own `task tell`
speaks as a coordinator, so it is not used for the human's prompts.

Live check on the Mac Studio: `--roster --shepherdr` read 5 spaces (one on an
offline laptop) and 11 tasks, every running agent linked; the real UI rendered
that data in a browser harness whose bridge never sends. The installed app was
not replaced. Windows shares the UI files; its host does not advertise
Shepherdr support, so the switch stays hidden there.



## macOS hc compatibility — November 15, 2026

The macOS host now prefers hc and retains the legacy Herdr backend when hc is
absent. HC.swift maps existing live Claude/Codex terminals and their app labels
to roster cards. The default core owns remote machine routing; no SSH targets or
--via command strings are executed by the HUD. Terminal argv stays out of cards
and diagnostics. Provider detection checks executable identity, not task text.

The transport writes JSON-RPC only through stdin, bounds output, and completes
once all matching replies arrive instead of waiting for the long-lived connect
bridge to close. Sends are separate from discovery/identity requests, require
fresh identity and idle status, and use if=idle, force=false. Prompt delivery
has a 75-second bound; uncertain delivery retains the UI draft and requires its
existing explicit reconciliation action. No retry is automatic. hc done status
is conservatively read only until idle. Core/address/creation/process/provider
and saved routing changes invalidate the selected card. Windows remains legacy.

Tests must use controlled transports or an explicitly isolated hc core, never
the user's Claude/Codex terminals. Local packaging/install and live read-only UI
acceptance are separate from source verification.

## macOS composer focus and paste — November 16, 2026

The agents panel now activates the accessory app when opened and has a standard
responder-chain Edit menu for WebKit paste and editing shortcuts. Previously the
composer was a nonactivating panel and the app had no main menu, so external
dictation/paste tools could target the prior app or fail to dispatch Paste.
Only H and alerts remain nonactivating. Closing returns focus to the app that was
frontmost before opening, provided the HUD still owns application focus.

EditorTests checks the composer window style and standard editing selectors.
Diagnostics add appActive and panelNonactivating without recording prompt text.
Installed macOS build passed live paste and select-all/delete checks without
sending a prompt. The user confirmed Wispr Flow dictation works in the HUD.
Swift tests passed (38 tests, one opt-in integration skipped, zero failures),
along with 19 JavaScript tests and five Python tests. Fullscreen game focus
remains unverified; window configuration tests do not establish that behavior.

## macOS local image previews — November 16, 2026

Previews beside Chat/Terminal shows up to 24 recent raster images in the local
agent's current directory and its shallow `outputs` folder. hc uses foreground
cwd rather than stale terminal metadata. Choose folder uses a native picker and
stores a private per-agent override in the `previewFolders` defaults dictionary.
No personal folders are embedded in source. Remote agents remain read only for
this feature; the Windows host does not advertise the tab.

Clicking opens a validated, read-only private copy with its original basename in
Preview. Editing this copy does not change the project original. Browser messages
carry opaque agent-scoped tokens, never file paths. Native discovery is limited
to 600 entries, 48 decode attempts, 24 thumbnails, 24 MB per file and 100 million
pixels; it runs off the prompt transport queue. Network volumes, symlinks,
non-raster types, changed files and stale/foreign tokens are rejected. The copy
cache is bounded to 96 files/192 MB per HUD run and removed on normal shutdown.
Request IDs discard delayed gallery results. Folder picker and gallery changes
preserve composer drafts and reuse existing focus behavior.

The shared Codex parser also removes the idle “Ask Codex to do anything” composer
and its wrapped GPT/cwd/shortcut footer from Chat instead of inventing a large
YOU card. Submitted messages and fenced examples remain visible. Native prompt
and hc identity/readiness/uncertain-delivery logic is unchanged.

Local macOS acceptance: installed bundle signature verified; Previews rendered 24 recent images after choosing the project outputs folder, and clicking a thumbnail opened its matching read-only copy in Preview. Draft text survived switching to Previews; test text was cleared without sending. Chat no longer shows the idle Codex placeholder card. Initial automatic folder discovery stayed loading for this session; the saved native folder selection worked.

## macOS image attachment implementation — November 16, 2026

The composer stages FileReader raster bytes as removable thumbnail chips, with an
accessible Attach images picker. Browser and native ImageIO limits independently
check 3 files/4 MB each and 40 million pixels; all browser drafts total 24 MB.
Staged drafts remain bound to the exact agent identity; Shepherdr automatic follow
pauses while that identity has images or reads in flight. No upload happens until
Send. Local hc Claude/Codex only: each terminal.put and final single terminal.send
is preceded by fresh identity/idle resolution. hc still applies if=idle on send.
The put-only process stdin allowance is 6 MB; other operations retain 512 KB.
Payloads stay on stdin. Unknown upload/send outcomes retain drafts and block
retry pending the existing reconciliation action. No live agent sends are tests.

Delivery is explicit local-file references plus an instruction to invoke an image
view/read tool, not native CLI multimodal injection. A send acknowledgement proves
text acceptance, not that an agent viewed the image. hc owns uploaded-file lifetime.
The composer never contains generated backend paths; terminal/chat history may.
Installing/restarting the running app is separate from source/build verification.

Installed macOS attachment acceptance: signature verified; Attach images opened the native file picker; selected PNG appeared as a thumbnail/name with no path inserted into the composer. It survived Chat/Previews switching, and removal disabled Send again. Test image was removed without sending. Physical external drag was covered by the UI drop callback tests rather than an end-to-end Finder drag; real-agent image consumption was not tested.

## Manual terminal controls and question formatting — November 16, 2026

macOS hc capability `terminalControlsSupported` enables one-key manual controls
only for provider-reported blocked permission/question status. HC output carries
`terminalControl` with an opaque consumable preview token and exact complete
`terminal.read(lines:0, how:screen)` text. Before keys, HC rechecks bound identity,
blocked kind and exact screen; it consumes the token before preflight, forwards
one allowlisted up/down/enter/esc, validates acknowledgement, and latches uncertain
delivery until explicit per-agent reconciliation. The native serial work queue
and UI pending-request lock prevent concurrent manual clicks. No semantic approval
selection or automatic retry exists. hc queues keys until output quiet and has no
atomic screen predicate; UI explicitly discloses that the screen can change during
delivery. Unknown/missing blocked kind offers no controls. Normal prompt guards
are unchanged. Windows/legacy hosts don't advertise this capability.

Known complete Codex Computer Use menu envelopes become display-only question
cards with exact scope labels/descriptions; same-line descriptions and wrapped
continuations remain visible. Other layouts stay ordinary terminal text.
Suggested ordinary next steps append to the existing draft, never submit it.
The existing silent toast appears only while the HUD panel is closed; an already
open panel receives roster/output updates and attention state without a toast.

Verification uses fake HC transports and a synthetic UI fixture only; never use
a real user's approval as a test. Build/install and rendered acceptance are owned
by the lead for this change.

## Six-feature workflow work — November 16, 2026

The macOS host advertises draftsSupported and quickPromptsSupported. DraftStore
writes a bounded private atomic snapshot (text, validated raster data, session
identity and uncertain delivery markers), refusing symlink/corrupt storage.
The JS controller waits for native disk acknowledgement before a send/key action
and saves pending actions as uncertain across crashes. Normal app quit awaits
flush. Draft recovery copies explicitly and leaves the saved original intact.
Quick prompts persist in UserDefaults and only fill the composer.

Unread status transitions and queued output preserve the current reading position.
Files are discovered natively from bound local output and represented by opaque
agent-scoped tokens; opening revalidates local regular non-symlink files and uses
explicit Preview/TextEdit or Quick Look handlers.

The optional guarded-key path requires hello feature guarded_keys_v1 plus a valid
terminal.input_snapshot from the exact core/terminal identity. Only recognized
single-field numbered menus expose literal Send N buttons. A click consumes its
token and calls terminal.keys_checked once; rejected results never fall back to
terminal.keys, and uncertain outcomes latch until explicit reconciliation (with
an additional two-second hold). No default-keymap or semantic-approval claim is
made: custom keybindings are unknowable from an already-running terminal.

The companion sibling herdr-core work is separate and not yet activated for user
sessions. Old holders persist across core restart and cannot provide guarded
writes. True semantic approval buttons require an agent approval API rather than
terminal key synthesis. Never use a user's real approval as a test.

Installed macOS acceptance for the first five additions: release build and ad-hoc
signature verified; bundled resources match source. Native menu quit/relaunch
restored both unsent shortcut text and an image thumbnail. Reply file button
opened the expected PNG in Preview. Test draft/image were cleared without sending,
and the persisted snapshot is empty. Custom shortcut save/fill/reload also passed
in an isolated browser fixture. JS52 passed; Swift58 executed/1skipped/0failures.
No live agent/core/holder restarted; guarded core remains source-only.

## Native Codex tool approvals — November 16, 2026

This supersedes the earlier semantic-approval limitation for newly launched,
explicitly linked Codex sessions; existing embedded sessions remain unchanged.
CodexSessionLauncher starts a dedicated stock app-server, confirms no loaded
threads, opens a stock TUI with --remote, then binds its sole loaded UUID to exact
core/terminal incarnation/foreground identity and the private socket instance.
It never starts a turn or cold-resumes an existing user's chat. The new terminal
is made visible via herdr-app terminal.keep so startup trust/login can be answered.

Codex's Unix endpoint is a symlink to a hashed physical socket. The launcher
verifies its official deterministic target, private ownership and both identities.
CodexSocket implements bounded WebSocket-over-UDS (the CLI proxy is a raw tunnel,
not a JSONL converter). It verifies handshake, same-account peer, masking,
fragment/control rules and UTF-8. No local TCP listener or secret copying.

CodexApprovals joins only its sole mapped loaded thread. An empty new chat has
no rollout: wait2s, recheck loaded identity, and retry read-only attachment after
the first user prompt. Each RPC has a deadline; approval responses never retry.
A known history-projection error fails closed with explicit Reconnect guidance.
Only exact message-only mcp_tool_call forms are supported; scopes must be offered.
Resolved IDs are tombstoned, lifecycle/connection changes invalidate cards, and
the native host rechecks descriptor fingerprint and callback epoch before action.
The UI labels the original linked UUID and never remaps by cwd or session title.

Actual installed Codex runtime verified in isolated, credential-free temporary
configuration: two-client attach succeeds after first-turn projection, and stock
remote TUI creates one new loaded chat without a prompt. The transport test's
synthetic turn used only a disabled loopback provider; no external model call.
These tests did not grant a real permission or touch user sessions.

Installed acceptance: JS54passed, Swift75executed/1skip/0fail, release and signature
passed. Installed native New Codex dialog + project picker/cancel verified; no
user session launched. Native/bundled resources match current build, and the
persisted draft snapshot is unchanged. Exact semantic response/resolution was
tested through a synthetic WebSocket and rendered UI, not a real user permission.
Full evidence is outputs/herdr-hud-native-approvals.md in the parent chat directory.

## Multiple follow-ups — November 16, 2026

The shared composer can accept durable FIFO items while Claude/Codex work. OrcaRouter's
Claude launcher still executes Claude Code, so it uses the same route without
provider credential changes. Queue data lives in the existing private draft snapshot;
pending items persist as uncertain. Snapshot version 2 reads/migrates version 1;
older HUD builds refuse the newer format instead of silently discarding queues.
Restart pauses all restored queues. Changed
identities never inherit a queue; recovery copies explicitly. Queue removal and
unknown delivery are explicit; no automatic retry is added.

The native queuedPrompt operation allows closed-panel delivery only after validating
its exact persisted head token, text and ordered image payload. It consumes the
agent/token pair before mutation. HC prompt transport still requires idle and
force=false; working-state terminal input remains unsupported because hc checks
status before paste and can later send Enter into a changed UI. The next FIFO item
waits for an observed Working→idle cycle or explicit Continue after inspection.

Native linked Codex sessions offer expected-turn steering separately from queueing.
No error falls back to terminal input or a different turn. UI intent persists before
request dispatch, and unknown writes retain both the draft and uncertainty block.
All transport verification must use fake or isolated sessions, never user agents.

## OrcaRouter through OpenCode and notification excerpts — November 16, 2026

The macOS Orca models panel fetches the authenticated fixed-origin catalog and
intersects it with bundled primary-source release evidence. The four-calendar-month
cutoff is rolling; unknown/future dates, native Anthropic/OpenAI families, automatic
routers and unsupported chat endpoints are hidden. Selecting is inert; explicit
launch refreshes eligibility and opens a project picker.

OrcaSessionLauncher creates dedicated local OpenCode 2.1.4 server/TUI terminals.
Private nonsecret descriptors bind core/terminal incarnations, foreground PIDs,
listener ownership, exact session ID and model. A Python exec wrapper retrieves
Keychain credentials after HC launch; secrets never enter HC metadata or argv.
A unique custom provider avoids OpenCode's built-in Orca catalog merging. The
adapter verifies exactly one available model and provider, correct endpoint/package,
and exact directory before create/send. OpenCode accepts unknown model metadata,
but its resolver fails unavailable IDs; the HUD refuses drift and never falls back.
Existing permission policies remain inherited. Native text/image acknowledgement
and uncertainty guards apply; unknown/unmanaged OpenCode stays read-only.

Notification excerpts now retain opening sentences or end at a word boundary.
Native font measurement shortens any remaining overflow before drawing. A separate
Click to read full reply footer keeps the full chat accessible. No model call is
made to summarize notifications.
