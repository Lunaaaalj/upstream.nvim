# upstream.nvim

A full-screen GitHub UI inside Neovim, built on the [`gh`](https://cli.github.com) CLI.
Browse the current repository's issues, pull requests, review requests and CI runs without leaving the editor.

```
╭─ owner/repo ── main ──────────────────────────────────── 4 PRs · 6 issues · ✓ CI ─╮
│  1 Issues   2 Pull requests   3 Review requests   4 Actions        / filter  open │
├────────────────────────────────┬──────────────────────────────────────────────────┤
│  #29 feat: music player ✓     │ # #29 feat: music player                         │
│  #28 fix(pdfview): spinner    │ Open · author wants to merge feat/music → main   │
│  ...                           │ ✓ checks · 2 approvals · +1,204 −38 · 9 files    │
╰──────── <CR> open · / filter · s state · r refresh · gx web · ? help · q close ───╯
```

> **Status: v0.1, read-only.** Commenting, editing, merging, review and the AI features are planned next.

## Requirements

- Neovim ≥ 0.10
- `gh`, authenticated (`gh auth login`)
- `git`
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
  },
}
```

`setup()` is optional. Without it, the defaults apply.

## Usage

`:Upstream [issues|prs|reviews|actions]`, or `require("upstream").open({ tab = "prs" })`.
Reopening without a tab returns to the last tab you used.

| Key                 | Action                                          |
| ------------------- | ----------------------------------------------- |
| `j` `k` `G`         | move; landing on "load more" fetches next page  |
| `<Tab>` `<S-Tab>` `1`–`4` | switch tab                                |
| `<CR>`              | focus the detail pane (`<C-h>` / `q` back)      |
| `<C-d>` `<C-u>`     | scroll the detail pane from the list            |
| `/`                 | filter (title, `#number`, author, labels)       |
| `s`                 | state: open → closed → all                      |
| `r`                 | refresh                                         |
| `gx`                | open in the browser                             |
| `?`                 | help                                            |
| `q` `<Esc>`         | close (`<Esc>` clears an active filter first)   |

## Configuration

```lua
require("upstream").setup({
  timeout = 15000,     -- ms before a gh call is killed
  per_page = 50,       -- items per page (max 100)
  tab = "issues",      -- tab opened the first time
  highlights = {},     -- e.g. { UpstreamSel = { link = "Visual" } }
  keys = { ... },      -- see :help upstream-keys; false disables a key
})
```

### Highlights

Every group is a `default` link, so colorschemes and `:hi` win:
`UpstreamNormal`, `UpstreamBorder`, `UpstreamTitle`, `UpstreamMuted`, `UpstreamAccent`, `UpstreamTab`, `UpstreamTabActive`, `UpstreamSel`, `UpstreamOpen`, `UpstreamClosed`, `UpstreamMerged`, `UpstreamDraft`, `UpstreamPending`, `UpstreamLabel`, `UpstreamNumber`.
Set `vim.g.ui_transparent = true` to drop the float background.

### Events

`User UpstreamChanged` fires (debounced) whenever fresh data lands, with `data = { repo = "owner/name", key = "issues-open" }`.

## How it works

- One GraphQL query per tab (`gh api graphql`, cursor pagination) and one per detail item; CI runs come from `gh run list`.
- Responses are cached under `stdpath("cache")/upstream/<owner>/<repo>/` and served **stale-while-revalidate**: the cache draws instantly, then a refetch redraws.
- Every `gh` call is async and has a timeout, so a hung network never blocks the editor.
