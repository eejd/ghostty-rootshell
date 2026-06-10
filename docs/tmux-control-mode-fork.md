# tmux Control Mode (-CC) Fork — Maintenance & Rebase Runbook

## Purpose & golden rule

This fork (the iOS/visionOS "rootshell" build of Ghostty) adds **tmux control mode
(`-CC`)** support that maps tmux windows/panes onto native Ghostty tabs/splits. We will
**never upstream** it. The goal of this document and the `ROOTSHELL-TMUX` markers in the
tree is to make rebasing onto `ghostty-org/ghostty` (`upstream/main`) mechanical.

> **Golden rule:** `grep -rn "ROOTSHELL-TMUX" src/ include/` finds **every** fork-owned
> tmux hook. Each carries a stable `id=` (see the registry below) and most carry a
> `reapply:` note describing how to put it back if it conflicts on rebase. Hooks that are
> part of the **frozen C ABI** the iOS Swift app consumes are additionally tagged
> `FROZEN-ABI` and must never be renamed or reordered.

The iOS Swift consumer lives in the separate `ghostty-ios` repo
(`Core/Tmux/TmuxController.swift`, the `ghostty_tmux_*` call sites, and
`ghostty-ios-Bridging-Header.h`). Any change to a `FROZEN-ABI` hook must be mirrored there.

---

## How the fork is structured (two kinds of divergence)

1. **Relocated, fully fork-owned files** — we *replaced* upstream's experimental tmux
   parser wholesale, then moved it off the shared path so it can never 3-way-merge.
2. **Hooks into live upstream files** — small edits interleaved into files upstream also
   maintains. We pulled the cleanly-separable parts into `*_tmux.zig` sidecars and left
   the irreducible remainder inline, each marked with a `ROOTSHELL-TMUX` banner.

### File inventory by tier

| Tier | Files | Strategy on rebase |
|------|-------|--------------------|
| **A. New, fork-only** | `src/termio/Tmux.zig` (tmux termio backend) | Carry forward verbatim. |
| **B. Relocated parser** | `src/terminal/tmux_cc/{control,viewer,layout,output,control_writer,integration_test}.zig` + aggregator `src/terminal/tmux.zig` | Take OUR version wholesale. See "Relocated parser" below. |
| **C. Sidecars (extracted glue)** | `src/Surface_tmux.zig`, `src/apprt/surface_tmux.zig` | Carry forward verbatim. |
| **C. Hooked upstream files** | `src/Surface.zig`, `src/apprt/embedded.zig`, `src/apprt/surface.zig`, `src/termio/stream_handler.zig`, `src/terminal/dcs.zig`, `src/terminal/parse_table.zig` | Re-apply banner-marked hooks; reconcile bodies live in the sidecars. |
| **D. One-/few-line hooks** | `src/apprt/action.zig`, `src/termio/backend.zig`, `src/termio/message.zig`, `src/termio/Termio.zig`, `src/termio/Thread.zig`, `src/termio.zig`, `src/config/Config.zig`, `include/ghostty.h` | Re-apply the marked lines. |

### Sidecar map (where extracted logic lives)

| Sidecar | Owns | Re-exported by |
|---------|------|----------------|
| `src/Surface_tmux.zig` | `TmuxReconcileOp`, `TmuxReconcilePayload`, and the planners `planTmuxReconcile` / `focusTmuxReconcile` / `titleTmuxReconcile` (pure, no `Surface` state) | `Surface.zig` re-exports the two types as `Surface.TmuxReconcile{Op,Payload}`; calls the planners via `tmux_reconcile.*` |
| `src/apprt/surface_tmux.zig` | `TmuxFocusChanged`, `TmuxTitleChanged`, `TmuxTopologySnapshot` value types | `apprt/surface.zig` re-exports them as `Message.Tmux*` |
| `src/termio/Tmux.zig` | the entire tmux termio backend (Tier A) | `src/termio.zig` (`pub const Tmux`) |
| `src/terminal/tmux_cc/` | the tmux control-mode parser/viewer/layout (Tier B) | `src/terminal/tmux.zig` aggregator, exposed as `terminal.tmux` |

> `SurfaceRelayWriter` intentionally stays in `apprt/surface.zig` (not the sidecar) because
> it is tightly coupled to that file's `Message` / `Mailbox` types; extracting it would
> create a circular import. It is marked `id=apprt-relay-writer`.

---

## Relocated parser (Tier B) — the biggest rebase win

Upstream ships its own experimental tmux parser at `src/terminal/tmux/{control,viewer,
layout,output}.zig`. We replaced those with our own implementation and **relocated them to
`src/terminal/tmux_cc/`** so the two never collide. The module symbol stays `terminal.tmux`
and `src/terminal/main.zig`'s wiring line is byte-identical to upstream (no conflict there);
only the aggregator `src/terminal/tmux.zig` points at `tmux_cc/` instead of `tmux/`.

**On rebase:**
- `src/terminal/tmux/*` is **deleted in our tree**. If upstream edits those files, git raises
  a trivial *delete/modify* conflict — resolve by **keeping the deletion** (`git rm` them).
- Never try to 3-way-merge upstream's experimental parser into `tmux_cc/`. They are different
  implementations. Take ours.
- If upstream ever *renames/moves* its tmux module, you'll see a build break referencing the
  old path — update the aggregator only.

---

## Frozen C ABI contract (what the iOS Swift app depends on)

These must remain byte-stable. Mirror any change in `ghostty-ios`.

- **Action:** `GHOSTTY_ACTION_TMUX_RECONCILE` and the `action.zig` union member
  `tmux_reconcile` + `pub const Key` enum entry `tmux_reconcile` (tag value — do not
  reorder) + the `TmuxReconcile` payload struct and its `C` extern struct.
- **Session-dashboard actions (`id=action-session-variants` /
  `id=action-session-structs` / `id=ghostty-h-session-actions`):**
  `GHOSTTY_ACTION_TMUX_SESSIONS_CHANGED` (void — session list churn, incl.
  other-client attach/detach/switch; the app refreshes its dashboard),
  `GHOSTTY_ACTION_TMUX_SESSION_CHANGED`
  (`ghostty_action_tmux_session_changed_s {session_id, name, name_len}` — the
  attached session's identity on startup/switch/rename; name is borrowed for the
  callback only), and `GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE`
  (`ghostty_action_tmux_command_response_s {tag, is_err, body, body_len}` — the
  response to an app query sent via `ghostty_surface_tmux_command_with_reply`;
  body borrowed for the callback only; empty body + is_err means the query was
  dropped by a viewer reset/teardown before tmux answered). Key-enum order is
  append-only after `tmux_reconcile` and enforced by `checkGhosttyHEnum`.
- **Reconcile op consumer (`embedded.zig`, `id=embedded-capi-reconcile`):** enum tag values
  `CTmuxOpTag` (op `0..8`) and `CTmuxLayoutKind` (`0..2`); extern struct field order of
  `CTmuxOp` (= `ghostty_tmux_op_s`) and `CTmuxLayoutInfo` (= `ghostty_tmux_layout_info_s`);
  exports `ghostty_tmux_reconcile_op_count` / `ghostty_tmux_reconcile_op` /
  `ghostty_tmux_reconcile_free` / `ghostty_tmux_layout_info` / `ghostty_tmux_layout_child`.
- **Pane creation / resize / detach / command / active / resume:** `ghostty_surface_new_tmux_pane` (`id=embedded-new-tmux-pane`),
  `ghostty_surface_tmux_set_client_size` (`id=embedded-set-client-size`),
  `ghostty_surface_tmux_detach` (`id=embedded-tmux-detach`),
  `ghostty_surface_tmux_command` (`id=embedded-tmux-command`) — queues a raw
  `split-window`/`kill-pane` through the viewer command queue (drives splits),
  `ghostty_surface_tmux_command_with_reply` (`id=embedded-tmux-command-with-reply`)
  — queues an app query (`list-sessions`, `new-session -P`, ...) through the
  viewer command queue (`Command.user_query`, `id=viewer-user-query`) and
  delivers its `%begin/%end` block (or `%error` body) back through the action
  callback as `GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE`, correlated by the
  app-chosen `tag`. Pending queries are errored back (empty body, is_err) on
  every queue-clearing reset: `%session-changed` rebuild, `forceResync`,
  teardown, resume abort (`id=streamhandler-query-command`),
  `ghostty_surface_tmux_active` (`id=embedded-tmux-active`) — bool probe of live
  control-mode state for the Swift ESC escape hatch,
  `ghostty_surface_tmux_resume` (`id=embedded-tmux-resume`) — re-enters control
  mode on a relaunched surface whose tssh session reattached a live `tmux -CC`
  (synthesizes the `ESC P 1000 p` entry, then the viewer `.resync` state drains
  the reattached stream and rebuilds via list-windows),
  `ghostty_surface_tmux_resume_abort` (`id=embedded-tmux-resume-abort`) — aborts a
  resume from the app's watchdog (tmux gone / session expired), tearing down the
  resync viewer and returning the parser to ground,
  `ghostty_surface_tmux_recover` (`id=embedded-tmux-recover`) — heals a LIVE
  gateway whose command/response stream desynced or that lost mid-stream data
  (the tsshd buffer overflowing while backgrounded). Drives `tmuxForceResync` (a
  live re-resync: reset the command pipeline, realign the parser, re-probe,
  rebuild via list-windows) WITHOUT tearing down panes. No-op unless a viewer is
  live in the steady command-queue state (distinct from `..._resume`, which only
  acts when NO viewer exists). Called from the app's always-on wedge watchdog,
  `ghostty_surface_tmux_force_exit` (`id=embedded-tmux-force-exit`) — the
  watchdog's give-up path: forcibly exits control mode LOCALLY (tears down the
  viewer, emits the empty-topology snapshot so the app prunes via the normal
  reconcile path AND drops the controller, returns the parser to ground). Unlike
  `..._detach` it does not wait for tmux to answer `detach-client`, so it works
  when tmux/the link is unresponsive. Server session stays alive.
- **Debug snapshot (`id=embedded-tmux-debug-snapshot`, FROZEN):**
  `ghostty_surface_tmux_debug_snapshot` fills a privacy-safe scalar
  `ghostty_tmux_debug_snapshot_s` (viewer/parser state, command-queue + sent-FIFO
  depths, in-flight command kind, pending pane responses, ages) for the iOS tmux
  debug log. It is a **lockless atomic read on the app thread** (no IO-thread hop)
  off an atomic mirror (`TmuxDebugMirror`, `id=tmux-debug-mirror`) the IO thread
  refreshes at tmux event sites — so it stays valid even when control mode is
  protocol-stalled. The first call flips an `enabled` atomic that gates the
  refresh, so it is a true no-op until the app opts in. The struct contains ONLY
  numeric ids/counts/enum-codes/ages/booleans — never pane output, titles,
  command text, keystrokes, or hostnames. The `ghostty_tmux_debug_snapshot_s`
  layout is **append-only**: add fields at the end and bump `abi_version`; keep
  `stream_handler.zig`'s `TmuxDebugSnapshot` and the `include/ghostty.h` typedef
  byte-for-byte in sync. Error/state codes are documented inline in both. The
  shared `control.ErrorCode` enum (`id=control-error-code`, in `control.zig`,
  also set on `viewer.zig`) backs `parser_last_error` / `viewer_last_error`.
- **Header:** the matching block in `include/ghostty.h`.

**Verify the ABI** (from the `ghostty-dec20` repo, after a build):
```bash
nm macos/GhosttyKit.xcframework/ios-arm64/libghostty-internal-fat.a \
  | grep -E '_ghostty_(tmux|surface_new_tmux|surface_tmux_(set_client|detach|command|active|resume|recover|force_exit))' | sort -u
```
Expect 15 `T` (defined text) symbols:
`_ghostty_surface_new_tmux_pane`, `_ghostty_surface_tmux_set_client_size`,
`_ghostty_surface_tmux_detach`, `_ghostty_surface_tmux_command`,
`_ghostty_surface_tmux_command_with_reply`,
`_ghostty_surface_tmux_active`, `_ghostty_surface_tmux_resume`,
`_ghostty_surface_tmux_resume_abort`, `_ghostty_surface_tmux_recover`,
`_ghostty_surface_tmux_force_exit`, `_ghostty_tmux_layout_child`,
`_ghostty_tmux_layout_info`, `_ghostty_tmux_reconcile_free`,
`_ghostty_tmux_reconcile_op`, `_ghostty_tmux_reconcile_op_count`. Also
`git diff include/ghostty.h` should be comment-only across a refactor.

---

## Banner convention

```zig
// ROOTSHELL-TMUX BEGIN (id=some-id)          // multi-line region; add FROZEN-ABI if C ABI
// what:    ...
// reapply: ...
...hooked code...
// ROOTSHELL-TMUX END (id=some-id)
```
```zig
foo, // ROOTSHELL-TMUX (id=some-id): one-line hook (e.g. a union variant or field)
```
Rules: every `BEGIN` has a matching `END`; C-ABI hooks carry `FROZEN-ABI` + a `DO NOT
REORDER` note; behavioral hooks in `dcs.zig` / `stream_handler.zig` / `parse_table.zig`
(the `dcs_passthrough` override) are also gated with
`if (comptime build_options.tmux_control_mode)` (a second greppable marker). The
`tmux_control_mode` build option is currently aliased to `oniguruma`
(`src/terminal/build_options.zig`); it was deliberately **not** decoupled.

### `id` registry

88 hook ids across 30 files (the table below enumerates the Tier C/D upstream-hooked
files; the fork-owned sidecars `src/Surface_tmux.zig`, `src/apprt/surface_tmux.zig`,
`src/termio/Tmux.zig`, and the `src/terminal/tmux_cc/*` parser also carry `id=`-tagged hooks
but are carried forward verbatim, so they are not re-listed here). Regenerate the full list
any time with:
```bash
grep -rn 'ROOTSHELL-TMUX' src/ include/ | grep -oE 'id=[a-z0-9-]+' | sort -u
```

| File | ids |
|------|-----|
| `src/apprt/action.zig` | `action-reconcile-variant` (FROZEN), `action-key-variant` (FROZEN), `action-reconcile-struct` (FROZEN) |
| `src/apprt/embedded.zig` | `embedded-capi-reconcile` (FROZEN), `embedded-new-tmux-pane` (FROZEN), `embedded-set-client-size` (FROZEN), `embedded-tmux-detach` (FROZEN), `embedded-tmux-command` (FROZEN), `embedded-tmux-active` (FROZEN), `embedded-tmux-resume-abort` (FROZEN), `embedded-tmux-recover` (FROZEN), `embedded-tmux-force-exit` (FROZEN), `embedded-new-tmux-pane-fn`, `embedded-init-tmux-pane-fn`, `embedded-relay-field`, `embedded-relay-deinit`, `embedded-ui-terminal-arm` |
| `src/apprt/surface.zig` | `apprt-surface-tmux-types-extracted`, `apprt-msg-topology`, `apprt-msg-write`, `apprt-msg-focus`, `apprt-msg-title`, `apprt-relay-writer` |
| `src/Surface.zig` | `surface-reconcile-extracted`, `surface-initoptions-backend`, `surface-init-backend-select`, `surface-arm-topology`, `surface-arm-write`, `surface-send-keys-untracked`, `surface-arm-focus`, `surface-arm-title` |
| `src/termio/stream_handler.zig` | `streamhandler-viewer-field`, `streamhandler-force-unhook-field`, `streamhandler-deinit-viewer`, `streamhandler-changeconfig-disable`, `streamhandler-changeconfig-colors`, `streamhandler-set-client-size`, `streamhandler-pump-command-queue`, `streamhandler-write-tracked-command`, `streamhandler-record-tracked`, `streamhandler-record-untracked`, `streamhandler-pane-command`, `streamhandler-detach`, `streamhandler-tmux-active`, `streamhandler-tmux-active-flag`, `streamhandler-dcs-ground`, `streamhandler-block-fifo-filter`, `streamhandler-command-tracked`, `streamhandler-windows-empty-guard`, `streamhandler-dcs-dispatch`, `streamhandler-broken-control-unhook`, `streamhandler-tmux-teardown`, `streamhandler-gateway-menu`, `streamhandler-suppress-gateway-reports`, `snapshot-feed-pane-titles`, `streamhandler-resume-resend-probe`, `streamhandler-resume-abort`, `streamhandler-force-resync`, `streamhandler-force-exit` |
| `src/termio/backend.zig` | `backend-kind`, `backend-config-tmux`, `backend-tmux`, `backend-threaddata-tmux` |
| `src/termio/Termio.zig` | `termio-derived-config`, `termio-derived-init`, `termio-stream-config` |
| `src/terminal/dcs.zig` | `dcs-tmux-enter`, `dcs-can-sub-abort`, `dcs-is-inactive`, `dcs-begin-tmux-resync`, `dcs-tmux-take-recover` (rest gated by `build_options.tmux_control_mode`) |
| `src/terminal/parse_table.zig` | `parsetable-dcs-utf8-passthrough`, `parsetable-dcs-utf8-test` |
| `src/terminal/stream_terminal.zig` | `streamterm-dcs-st`, `streamterm-dcs-can-sub` |
| `src/termio/message.zig` | `termio-msg-set-client-size`, `termio-msg-pane-command`, `termio-msg-send-keys`, `termio-msg-track-command`, `termio-msg-detach`, `termio-msg-resume`, `termio-msg-resume-abort`, `termio-msg-recover`, `termio-msg-force-exit` |
| `src/termio/Thread.zig` | `thread-set-client-size`, `thread-pane-command`, `thread-send-keys`, `thread-track-command`, `thread-detach`, `thread-resume`, `thread-resume-abort`, `thread-recover`, `thread-force-exit` |
| `src/termio.zig` | `termio-tmux-export` |
| `src/config/Config.zig` | `config-tmux-control-mode` |
| `include/ghostty.h` | `ghostty-h-action-enum` (FROZEN), `ghostty-h-reconcile` (FROZEN), `ghostty-h-set-client-size` (FROZEN), `ghostty-h-tmux-detach` (FROZEN), `ghostty-h-tmux-command` (FROZEN), `ghostty-h-tmux-active` (FROZEN), `ghostty-h-tmux-resume` (FROZEN), `ghostty-h-tmux-resume-abort` (FROZEN), `ghostty-h-tmux-recover` (FROZEN), `ghostty-h-tmux-force-exit` (FROZEN) |

---

## Step-by-step rebase procedure

1. `git fetch upstream && git rebase upstream/main` (or merge).
2. **Tier A / C sidecars / B parser** (`src/termio/Tmux.zig`, `src/Surface_tmux.zig`,
   `src/apprt/surface_tmux.zig`, `src/terminal/tmux_cc/*`): these are fork-owned, no upstream
   equivalent — carry forward. If `src/terminal/tmux/*` reappears as a delete/modify
   conflict, **keep it deleted**.
3. **Tier C/D hooked upstream files:** for each conflicted file, run
   `grep -n ROOTSHELL-TMUX <file>` and re-apply each marked hook using its `reapply:` note
   and the registry above. Check off every `id` for that file.
4. Rebuild (fast iteration build, from `ghostty-dec20`):
   ```bash
   /opt/homebrew/opt/zig@0.15/bin/zig build -Doptimize=ReleaseFast -Demit-xcframework \
     -Dxcframework-target=universal -Dsentry=false -Dappstore=false
   ```
5. **ABI verify** (see "Frozen C ABI contract"): `nm` the static archive for the 7 tmux
   symbols; `git diff include/ghostty.h` should be comment-only.
6. Run tests: `zig build test` (covers `src/terminal/tmux_cc/integration_test.zig` and the
   `dcs.zig` tmux tests).
7. Rebuild the shippable framework and the iOS app:
   `./scripts/build-framework.sh appstore`, then build `rootshell-AppStore` in `ghostty-ios`
   and smoke-test `tmux -CC` on device (native tab/split mapping, pane input, scrollback,
   resize).

### Drift checks (run any time)
```bash
# BEGIN/END must balance:
echo "$(grep -rc 'ROOTSHELL-TMUX BEGIN' src/ include/ | awk -F: '{s+=$2} END{print s}') begin / \
      $(grep -rc 'ROOTSHELL-TMUX END'   src/ include/ | awk -F: '{s+=$2} END{print s}') end"
# Every FROZEN-ABI symbol still present:
nm macos/GhosttyKit.xcframework/ios-arm64/libghostty-internal-fat.a \
  | grep -cE '_ghostty_(tmux|surface_new_tmux|surface_tmux_(set_client|detach|command|active))'   # expect 10
# No stale upstream tmux/ path references crept back in:
grep -rn 'terminal/tmux/' src/ --include='*.zig' | grep -v 'tmux_cc/'      # expect empty
```
