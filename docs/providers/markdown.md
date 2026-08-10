# Markdown Checklist Integration

## Overview

The Markdown provider keeps tasks in a local markdown checklist file using checkbox items like:

```markdown
- [ ] [md-20260810112233-123456](markdown://task/md-20260810112233-123456) Implement auth middleware
```

This is useful when you want issue-style tracking without relying on an external SaaS provider.

## Setup

### 1. Configure the provider

```lua
require("comment-tasks").setup({
    default_provider = "markdown",
    providers = {
        markdown = {
            enabled = true,
            file_path = "TASKS.md",               -- Relative to project root
            section_heading = "## Comment Tasks", -- Section to append tasks under
            statuses = {
                new = "open",
                completed = "completed",
                in_progress = "in_progress",
                review = "review",
                blocked = "blocked",
            },
        },
    },
})
```

### 2. No environment variable required

The Markdown provider does not use API tokens.

## Usage

### Commands

```vim
:MarkdownTask               " Create checklist task from current comment
:MarkdownTask new           " Explicit create
:MarkdownTask completed     " Mark item as done ([x])
:MarkdownTask in_progress   " Mark item as open ([ ])
:MarkdownTask addfile       " Add current file under task metadata
```

### Example workflow

1. Start with a comment in code:

```lua
-- TODO: Add retry support to HTTP client
-- Handle exponential backoff and cancellation
```

2. Run `:MarkdownTask` with your cursor on the comment.

3. The comment is extended with an internal markdown task URL:

```lua
-- TODO: Add retry support to HTTP client
-- Handle exponential backoff and cancellation
-- markdown://task/md-20260810112233-123456
```

4. The configured markdown file gets a checklist entry:

```markdown
## Comment Tasks

- [ ] [md-20260810112233-123456](markdown://task/md-20260810112233-123456) Add retry support to HTTP client
  - files: client.lua
```

## Configuration Options

```lua
markdown = {
    enabled = true,                          -- Required
    file_path = "TASKS.md",                 -- Optional; default: TASKS.md
    section_heading = "## Comment Tasks",   -- Optional; default heading
    statuses = {                              -- Optional; command/status map
        new = "open",
        completed = "completed",
        in_progress = "in_progress",
        review = "review",
        blocked = "blocked",
    },
}
```

## Project-level overrides

You can override markdown settings in `.comment-tasks.json`:

```json
{
  "default_provider": "markdown",
  "providers": {
    "markdown": {
      "file_path": "docs/TODO.md",
      "section_heading": "## Engineering Backlog"
    }
  }
}
```

## Notes

- `completed`, `complete`, `done`, and `closed` mark checklist items as `[x]`.
- Any other status keeps items open as `[ ]`.
- File references are tracked on the line immediately under each checklist item.
