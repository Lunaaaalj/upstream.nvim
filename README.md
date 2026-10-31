# upstream.nvim

A full-screen GitHub UI inside Neovim, built on the [`gh`](https://cli.github.com) CLI.
Browse and manage the current repository's issues, pull requests, review requests and CI runs, review PRs with inline comments, and let Claude draft PR descriptions and review comments, all without leaving the editor.

```
╭─ owner/repo ── main ──────────────────────────────────── 4 PRs · 6 issues · ✓ CI ─╮
│  1 Issues   2 Pull requests   3 Review requests   4 Actions        / filter  open │
├────────────────────────────────┬──────────────────────────────────────────────────┤
│  #29 feat: music player ✓     │ # #29 feat: music player                         │
│  #28 fix(pdfview): spinner    │ Open · author wants to merge feat/music → main   │
│  ...                           │ ✓ checks · 2 approvals · +1,204 −38 · 9 files    │
╰─ <CR> open · c comment · x close · C configure · w work on · m merge · R review · ? help ─╯
```

## Requirements

- Neovim ≥ 0.10
- `gh`, authenticated (`gh auth login`)
- `git`
- Optional: [Claude Code](https://claude.com/claude-code) (`claude`) for the AI features
- Optional: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for prettier bodies (the detail pane is a `markdown` buffer)

Run `:checkhealth upstream` to verify the setup.

## Install

lazy.nvim:

```lua
{
  "Lunaaaalj/upstream.nvim",
  cmd = "Upstream",
  opts = {},
  keys = {
    { "<leader>Go", function() require("upstream").open() end, desc = "GitHub" },
    { "<leader>Gn", function() require("upstream").new_issue() end, desc = "GitHub: new issue" },
    { "<leader>Gc", function() require("upstream").new_pr({ ai = true }) end, desc = "GitHub: PR (AI draft)" },
  },
}
```

`setup()` is optional. Without it, the defaults apply.

## Usage

`:Upstream [issues|prs|reviews|actions]`, or `require("upstream").open({ tab = "prs" })`.
Reopening without a tab returns to the last tab you used.
Also `:Upstream new-issue`, `:Upstream new-pr`, `:Upstream draft-pr` (AI) and `:Upstream review <n> [assist]`.

| Key                       | Action                                                    |
| ------------------------- | --------------------------------------------------------- |
| `j` `k` `G`               | move; landing on "load more" fetches the next page        |
| `<Tab>` `<S-Tab>` `1`–`4` | switch tab                                                |
| `<CR>`                    | focus the detail pane (`<C-h>` / `q` back)                |
| `<C-d>` `<C-u>`           | scroll the detail pane from the list                      |
| `/` · `s`                 | filter (title, `#number`, author, labels) · open/closed/all |
| `c` · `e`                 | comment · edit title/body                                 |
| `x`                       | close as completed / not planned, or reopen (on a run: cancel) |
| `C`                       | configure: one menu with every setting (labels, assignees, assign yourself, milestone, state, …) |
| `w`                       | work on the issue: switch to a local `<number>-<slug>` branch, created from the fetched default branch |
| `l` · `a` · `M` · `v`     | labels · assignees · milestone · reviewers (pickers)      |
| `m` · `o`                 | merge (then offers to delete the branch; on conflicts, offers to merge the base in locally) · check out |
| `R`                       | review the PR (on a run: re-run)                          |
| `L`                       | run log (Actions tab)                                     |
| `n`                       | new issue / new PR (depends on the tab)                   |
| `A`                       | AI: work on this issue, review assist, draft a PR         |
| `r` · `gx` · `?`          | refresh · open in the browser · help                      |
| `q` `<Esc>`               | close (`<Esc>` clears an active filter first)             |

### Compose buffers

Comments, edits, new issues and new PRs open in a markdown buffer where **`:w` submits**. Metadata sits in a header that ends with `---`:

```
title: feat(github): browse issues
base: main   head: feat/x   draft: false
labels: enhancement, area:ui

---
body…
```

Every `:w` saves a draft first, so a failed submit never loses text; reopening the same compose buffer restores it.

### Review

`R` on a PR opens the diff in a tab, with existing threads drawn inline under their lines. `c` comments on a line (or a visual range, or a whole file from its header), `r` replies, `x` resolves, `]t`/`[t` jump between threads, `T` lists all of them (outdated ones too). Comments collect in a **pending review** that `S` submits as comment / approve / request changes. Anchors are checked against the diff hunks before anything is sent.

### AI

Claude Code runs headless (`claude -p --output-format json`) and only ever produces drafts:

- **Draft PR**: title and body from `git log` + the diff, opened in the new-PR compose buffer.
- **Review assist**: findings validated against the hunks, shown inline and in a drafts list where you accept (`a`), edit (`e`) or drop (`d`) each one into your pending review.
- **Work on this issue**: optionally switches to the issue branch (same as `w`), then a chat seeded with the issue (`ai.open_chat`, default `:terminal claude`).

### Actions

The Actions tab lists workflow runs with their jobs and steps. `L` opens the log (failed steps only for a failed run; `a` for everything), `R` re-runs, `x` cancels.

## Configuration

```lua
require("upstream").setup({
  timeout = 15000,     -- ms before a gh call is killed
  per_page = 50,       -- items per page (max 100)
  tab = "issues",      -- tab opened the first time
  compose = "current", -- where compose buffers open: current/split/vsplit/tab
  issue_branch = "{number}-{slug}", -- `w` branch: {number} {slug} {title}, or function(issue)
  highlights = {},     -- e.g. { UpstreamSel = { link = "Visual" } }
  keys = { ... },      -- see :help upstream-keys; false disables a key
  ai = {
    command = "claude",
    args = {},           -- e.g. { "--model", "sonnet" }
    timeout = 300000,
    max_findings = 15,
    open_chat = nil,     -- function(prompt, ctx) for "work on this issue"
  },
})
```

### Highlights

Every group is a `default` link, so colorschemes and `:hi` win:
`UpstreamNormal`, `UpstreamBorder`, `UpstreamTitle`, `UpstreamMuted`, `UpstreamAccent`, `UpstreamTab`, `UpstreamTabActive`, `UpstreamSel`, `UpstreamOpen`, `UpstreamClosed`, `UpstreamMerged`, `UpstreamDraft`, `UpstreamPending`, `UpstreamLabel`, `UpstreamNumber`, `UpstreamDraftAI`, and for the review diff `UpstreamDiffAdd`, `UpstreamDiffDelete`, `UpstreamDiffHunk`, `UpstreamDiffFile`, `UpstreamLineNr`.
Set `vim.g.ui_transparent = true` to drop the float background.

### Events

`User UpstreamChanged` fires (debounced) whenever fresh data lands and after every write, with `data = { repo = "owner/name", key = "issues-open" }` (plus `item`, the updated issue/PR, after a write).

## How it works

- One GraphQL query per tab (`gh api graphql`, cursor pagination) and one per detail item; CI runs come from `gh run list`.
- Responses are cached under `stdpath("cache")/upstream/<owner>/<repo>/` and served **stale-while-revalidate**: the cache draws instantly, then a refetch redraws.
- Writes are GraphQL mutations that return the updated item, which goes straight into the cache and the open float (no refetch).
- Every `gh` call is async and has a timeout, so a hung network never blocks the editor.
