## Summary

A **full-screen GitHub UI inside Neovim**: browse and manage the current repo's issues and pull requests, review code with inline comments, and open PRs with Claude's help, without going to the browser. It is fully custom (no octo.nvim), GitHub only, and built on the `gh` CLI's GraphQL access, the same way `lua/defaults/dashboard_data.lua` already works.

It should be a **standalone plugin** (its own repo, name TBD). This config loads it with `dir = "~/dev/<name>.nvim", dev = true` during development and with a normal lazy spec once it's published.

## Layout

One full-screen float, opened by `<leader>Go`. It is laid out like the music player: a list on the left and a detail pane on the right.

```
╭─ Lunaaaalj/nvim ── main ────────────────────────────── 4 PRs · 6 issues · ✓ CI ─╮
│  Issues   Pull requests   Review requests   Actions                    / filter │
├────────────────────────────────┬────────────────────────────────────────────────┤
│ ● #29 feat(music): Apple Music │ #29 feat(music): Apple Music player            │
│   #28 fix(pdfview): spinner    │ Lunaaaalj wants to merge feat/music → main     │
│ ● #27 Typst templates          │ ✓ checks  · 2 approvals · +1,204 −38 · 9 files │
│   ...                          │                                                │
│                                │ ## Summary                                     │
│                                │ (body rendered as markdown)                    │
│                                │                                                │
│                                │ ── 3 comments ──────────────────────────────── │
│                                │ ...                                            │
├────────────────────────────────┴────────────────────────────────────────────────┤
│ <CR> open  c comment  x close  l labels  m merge  R review  A ai  gx web  ? help│
╰─────────────────────────────────────────────────────────────────────────────────╯
```

- **Tabs:** Issues · Pull requests · Review requests · Actions (CI runs). `<Tab>`/`<S-Tab>` or `1`–`4` switch tabs.
- **List:** one item per line, so `j`/`k`/`G` work natively. The selection is the float's own cursorline, so the filetype goes in `cursorline.lua`'s `unmanaged_ft`. `/` filters and `s` switches the state (open/closed/all).
- **Detail:** a `markdown` buffer, so render-markdown draws the body. It shows the timeline (comments, reviews, commits), labels, assignees, linked issues and check status.
- **Transparency:** respect `vim.g.ui_transparent`. Highlights come from linked defaults (`Function`, `Comment`, `DiagnosticOk`/`Error`…). This config overrides them through `defaults/colors.lua` on `ColorScheme`.

## Scope

| Area         | Included                                                                                                                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Browse       | Issues, PRs, review requests, CI runs; filter, state, pagination; open in browser (`gx`)                                                                |
| Manage       | Comment, edit, close/reopen, labels, assignees, reviewers, milestone; merge (merge/squash/rebase), check out a PR branch, delete a merged branch        |
| Create       | New issue, new PR (base/head/draft); both written in a compose buffer                                                                                   |
| Review       | PR diff, existing threads anchored inline, inline/multi-line comments, reply/resolve, pending review, then submit (approve / comment / request changes) |
| AI           | Draft PR title and body; review assist into _pending_ inline comments; "work on this issue" chat                                                        |
| Not included | GitLab/other forges, notifications inbox, Projects boards, Discussions, editing workflow files                                                          |

## Design

### Data layer

- **Repo detection:** `gh repo view --json nameWithOwner,defaultBranchRef` from the cwd, cached per cwd. No repo, no `gh`, or not authenticated → one clear notification and the float does not open.
- **Reads:** async `vim.system({ "gh", "api", "graphql", ... })`, one query per tab (`first: 50` + cursor pagination). The detail view uses one query per item. Responses are cached under `stdpath("cache")/<plugin>/<owner>/<repo>/`, **stale-while-revalidate**: draw from the cache instantly, refetch, then redraw. Don't block the UI.
- **Writes:** GraphQL mutations (`addComment`, `closeIssue`, `updateIssue`, `mergePullRequest`, `addPullRequestReview`, …). Each one returns the updated object, which is merged into the cache so the UI updates without refetching.
- **Events:** state changes fire a debounced `User GithubChanged`. The float listens for it, and the dashboard stats line can too.
- **Timeouts:** apply them, as in `lua/music/`, so a hung `gh` never freezes anything.

### Compose buffers

Comments, new issues, new PRs and edits open in a `buftype=acwrite` markdown buffer. **`:w` submits** (`BufWriteCmd`). A small header block holds the metadata:

```
title: feat(github): browse issues
base: main   draft: false
labels: enhancement, area:ui
---
body…
```

`:q` on an unsent compose buffer goes through `bufclose.lua`'s Save/Discard/Cancel prompt, so drafts aren't lost.

### Review

- The diff for `base...head` is rendered by a custom unified/split diff view. diffview.nvim may be reused only as a renderer if that turns out simpler; that decision is open.
- **Anchoring:** a cursor position maps to GitHub's `path` / `line` / `side` (`LEFT`/`RIGHT`) / `start_line`. Only lines inside a diff hunk can take a comment, because GitHub rejects anything else, so this check is enforced client-side.
- Existing threads are drawn as `virt_lines` below their line. `isOutdated` threads appear in a thread list but are not anchored. `]t`/`[t` move between threads.
- Comments go into a **pending review** (`addPullRequestReview` without an event, then `addPullRequestReviewThread`). They are only published when you submit with approve / comment / request changes.

### AI assistance (Claude produces drafts, the user posts)

Nothing is ever posted without an explicit `:w` or a confirmation.

1. **Draft PR:** collect `git log base..HEAD` and the diff (large diffs are truncated per file, falling back to `--stat`), then run headless `claude -p --output-format json` and request `{title, body}`. The result opens in the new-PR compose buffer for editing.
2. **Review assist:** headless Claude gets the PR diff (plus the PR description and linked issue) and returns `[{path, line, side, start_line?, severity, body}]`. Each finding is **validated against the diff hunks**; invalid anchors are dropped or attached at file level. Findings go into a drafts list where you accept (`a`), edit (`e`) or drop (`d`) each one. Accepted findings become pending review comments, and submitting is still a separate step.
3. **Work on issue:** start an interactive chat seeded with the issue's title, body and comments. Optionally run `git switch -c <n>-<slug>` first. In this config that goes through `claude_chats` (`require("claude_chats").open`, which needs a new `prompt` option passed as `claude`'s positional argument). In the plugin it is a `setup({ ai = { open_chat = fn } })` hook that defaults to a plain `:terminal claude`.

### Plugin boundaries

- No `require` of anything in this config. Integration points are `setup()` options: `highlights`, `ai.open_chat`, `ai.command` (default `claude`), `keys`.
- This config's glue (colours, `claude_chats`, cursorline `unmanaged_ft`, dashboard key) lives in `lua/plugins/<name>.lua`.
- `:checkhealth <name>` checks for `gh`, authentication, `git` and `claude`.

## Keymaps

Global (`<leader>G`; `<leader>g` stays git/diffview):

| Key                                        | Action                                           |
| ------------------------------------------ | ------------------------------------------------ |
| `<leader>Go`                               | Open the GitHub float (last tab)                 |
| `<leader>Gi` / `<leader>Gp` / `<leader>Gr` | Open on Issues / Pull requests / Review requests |
| `<leader>Gn`                               | New issue (compose buffer)                       |
| `<leader>Gc`                               | Create PR from the current branch (AI draft)     |

Inside the float: `<CR>` open, `c` comment, `e` edit, `x` close/reopen, `l` labels, `a` assignees, `v` reviewers, `m` merge, `o` check out, `R` review, `A` AI menu, `r` refresh, `gx` browser, `?` help, `q`/`<Esc>` close.

## Phases

- [ ] **0. Scaffold:** create the plugin repo; lazy `dev` spec in this config; `:checkhealth`; repo detection; async `gh` runner with timeout
- [ ] **1. Browse:** float layout, tabs, list and detail panes, cache with stale-while-revalidate, filter/state, pagination, `gx`
- [ ] **2. Manage:** compose buffers (`:w` submits), comment/edit/close/labels/assignees/reviewers, new issue, new PR, merge and check out (with confirmations)
- [ ] **3. AI drafts:** draft PR title/body; "work on issue" chat (adds `prompt` to `claude_chats.open`)
- [ ] **4. Review:** diff view, hunk-aware anchoring, existing threads inline, pending review, reply/resolve, submit
- [ ] **5. AI review assist:** structured findings, hunk validation, accept/edit/drop drafts list into the pending review
- [ ] **6. Polish:** Actions tab (runs, logs in a buffer, re-run), dashboard tie-in, highlights through `defaults/colors.lua`
- [ ] **Docs:** CLAUDE.md section, `doc/*.txt` (`:help`), cheatsheet `sections`, the plugin's own README and vimdoc

## Open questions

- Plugin name.
- Diff renderer for review: fully custom, or diffview.nvim as the renderer only?
- Whether to show CI check annotations inline in the review diff.
