# Local branch: what it carries

`local` = `main` (mirror of kitknox/ghostty-rootshell `main`) + the topics below + MacPorts-only
commits (docs/development-model.md in eejd/macports-ports-local, "Forks, upstreams and port tiers").
Port: `devel/ghosttykit-local` (tag `v1.3.2-local01`; upstream has no release, `build.zig.zon`
says 1.3.2-dev).

| Branch / commit | What | Upstream PR status |
|---|---|---|
| `topic/appearance-propagation` | Report each surface's effective color scheme at runtime; bridge per-pane appearance queries in tmux control mode. Squash of fork PRs #1 and #2 (`Source:` trailers), re-resolved on upstream main. | not submitted (live-test first: issue #3) |
| `macports: source metal/metallib paths from build options (#4)` | Build-option plumbing for the Metal toolchain paths under MacPorts. MacPorts-only, never proposed upstream (ADR-0007 section 7). | n/a |
