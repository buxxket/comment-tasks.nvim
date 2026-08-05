# Trello Integration
## Setup

### 1. Get API Credentials

#### API Key
1. Go to [Trello Developer API Keys](https://trello.com/app-key)
2. Copy your "Key" (this is your API key)

#### Token  
1. On the same page, click "Token" link
2. Authorize the application
3. Copy the generated token

### 2. Environment Configuration

```bash
export TRELLO_API_KEY="your_trello_api_key_here"
export TRELLO_API_TOKEN="your_trello_token_here"
```

### 3. Plugin Configuration

```lua
require("comment-tasks").setup({
    providers = {
        trello = {
            enabled = true,
            api_key_env = "TRELLO_API_KEY",
            api_token_env = "TRELLO_API_TOKEN",
            board_id = "your_board_id",         -- Required: Trello board ID

            -- New card defaults (optional)
            assign_to_me = true,                 -- Assign new cards to current Trello user
            add_repo_label = true,               -- Add repo/root folder name as label
            auto_create_labels = true,           -- Create missing labels automatically
            default_label_color = "blue",       -- Color for auto-created labels
            default_label_names = { "todo" },   -- Additional labels by name
            default_member_ids = {},             -- Additional Trello member IDs
            card_position = "top",              -- "top", "bottom", or numeric position
            default_due_in_days = 3,             -- Set due date relative to creation time
            
            -- Statuses map to list names on the board; cards move between lists
            statuses = {
                new = "To Do",          -- Special: list for new cards
                completed = "Done",     -- Special: list for completed cards
                in_progress = "Doing",  -- Moves card to "Doing"
                review = "Review",      -- Moves card to "Review"
            },
        }
    }
})
```

### 4. Finding Your IDs

#### Board ID (Required)

**Method 1: From Trello URL**
```
https://trello.com/b/[BOARD_ID]/board-name
                     ↳ This is your board_id
```

**Method 2: Using API**
```bash
curl "https://api.trello.com/1/members/me/boards?key=YOUR_API_KEY&token=YOUR_TOKEN"
```

#### List Names

Statuses are configured with list **names** (e.g. "To Do", "Doing", "Done");
the plugin resolves them to list IDs on the board automatically. To see the
lists on your board:

```bash
curl "https://api.trello.com/1/boards/BOARD_ID/lists?key=YOUR_API_KEY&token=YOUR_TOKEN"
```

## Usage

### Commands

Trello uses a list-based workflow (cards move between lists):

```vim
:TrelloTask new          " Create card in the list mapped to 'new'
:TrelloTask in_progress  " Move card to the list mapped to 'in_progress'
:TrelloTask review       " Move card to the list mapped to 'review'
:TrelloTask close        " Move card to the list mapped to 'completed'
:TrelloTask addfile      " Append current file reference to card description
```

### Moving Cards Between Lists

Each configured status maps to a list name on the board; running a status
command moves the card to that list:

```lua
trello = {
    enabled = true,
    api_key_env = "TRELLO_API_KEY", 
    api_token_env = "TRELLO_API_TOKEN",
    board_id = "abc123def456",
    
    statuses = {
        new = "To Do",
        in_progress = "Doing",
        review = "Review",
        completed = "Done",
    }
}
```

### Example Workflow

1. **Create a card**:
   ```css
   /* TODO: Improve responsive design for mobile screens */
   /* Current layout breaks on screens smaller than 768px */
   ```
   
   Place cursor on comment → `:TrelloTask new`
   
   ```css
   /* TODO: Improve responsive design for mobile screens */
   /* Current layout breaks on screens smaller than 768px */
   /* https://trello.com/c/abc123def */
   ```

2. **Move card through workflow**:
   ```vim
   :TrelloTask in_progress  " When you start working
   :TrelloTask review       " When ready for review
   :TrelloTask close        " When completed
   ```

3. **Add file references**:
   ```vim
   :TrelloTask addfile      " Appends current file to the card description
   ```

## Configuration Options

### Basic Configuration

```lua
trello = {
    enabled = true,
    api_key_env = "TRELLO_API_KEY",
    api_token_env = "TRELLO_API_TOKEN",
    board_id = "abc123def456",
    
    statuses = {
        new = "To Do",
        completed = "Done",
    },
}
```

### Advanced Configuration

```lua
trello = {
    enabled = true,
    api_key_env = "TRELLO_API_KEY",
    api_token_env = "TRELLO_API_TOKEN",
    board_id = "abc123def456",

    assign_to_me = true,
    default_member_ids = { "64fabc123def4567890abcd" },
    default_label_ids = { "64fdef123abc4567890dcba" },
    default_label_names = { "backend", "todo" },
    add_repo_label = true,
    auto_create_labels = true,
    default_label_color = "blue",
    card_position = "top",
    default_due_in_days = 2,
    
    -- Map as many workflow statuses to lists as you need
    statuses = {
        new = "To Do",
        backlog = "Backlog",
        in_progress = "Doing",
        review = "Review",
        testing = "Testing",
        completed = "Done",
    },
}
```

### Advanced Trello Defaults

- `assign_to_me`: Resolves the current API token user via `/1/members/me` and adds them to every new card.
- `default_member_ids`: Additional Trello member IDs to assign to all new cards.
- `default_label_ids`: Existing Trello label IDs to apply to all new cards.
- `default_label_names`: Label names to resolve on the board. Missing labels are auto-created when `auto_create_labels = true`.
- `add_repo_label`: Uses the git repository root folder name as a label (falls back to project root/cwd if git root is unavailable).
- `default_label_color`: Label color for labels created automatically (`blue`, `green`, `red`, etc.).
- `card_position`: Sets Trello card position (`top`, `bottom`, or numeric string).
- `default_due_in_days`: Sets a due date offset for new cards. Use `0` (or `nil`) to disable due dates.

## Troubleshooting

### "Board not found" or "Invalid board_id"

1. **Verify board ID**:
   ```bash
   curl "https://api.trello.com/1/boards/BOARD_ID?key=API_KEY&token=TOKEN"
   ```

2. **Check permissions**: 
   - Ensure you're a member of the board
   - Verify board isn't private (if you're not a member)

3. **API access**: Confirm API key and token have board access

### "List not found" or "Could not determine target list"

1. **Check available lists**:
   ```bash
   curl "https://api.trello.com/1/boards/BOARD_ID/lists?key=API_KEY&token=TOKEN"
   ```

2. **List permissions**: Ensure list exists and isn't archived

### Label creation or lookup failures

When Trello label lookup/creation fails, card creation now continues without those label-name defaults.

1. **Check board labels endpoint**:
    ```bash
    curl "https://api.trello.com/1/boards/BOARD_ID/labels?key=API_KEY&token=TOKEN"
    ```

2. **If needed, disable auto create**:
    - Set `auto_create_labels = false`
    - Use `default_label_ids` for existing labels only

### Authentication Issues

1. **API Key verification**:
   ```bash
   curl "https://api.trello.com/1/members/me?key=API_KEY&token=TOKEN"
   ```

2. **Token expiry**: Tokens can expire - regenerate if needed

3. **Scope permissions**: Ensure token has read/write access

### Cards Not Creating

1. **List permissions**: Check if you can manually add cards to the list
2. **Board access**: Verify you have write access to the board
3. **Rate limits**: Trello has API rate limits (300 requests per 10 seconds)

## API Reference

Trello uses the [REST API v1](https://developer.atlassian.com/cloud/trello/rest/). The plugin makes requests to:

- `POST /1/cards` - Create cards
- `PUT /1/cards/{id}` - Update card details, description, and list
- `GET /1/cards/{id}` - Retrieve card information
- `GET /1/boards/{id}/lists` - Resolve list names to IDs

## Workflow Examples

### Kanban Development Workflow

```lua
trello = {
    statuses = {
        new = "Backlog",          -- New cards land in Backlog
        todo = "To Do",           -- Ready for development
        in_progress = "Doing",    -- Currently in progress
        review = "Review",        -- Code review stage
        testing = "Testing",      -- QA testing stage
        completed = "Done",       -- Completed work
    }
}
```

Usage:
```vim
:TrelloTask new          " Create in Backlog
:TrelloTask todo         " Move to ready for work
:TrelloTask in_progress  " Start working
:TrelloTask review       " Ready for review
:TrelloTask close        " Complete (moves to Done)
```

## Integration Tips

1. **Board organization**: Use separate boards for different projects
2. **List workflow**: Design lists to match your team's process
3. **File references**: Use `:addfile` to maintain code references
