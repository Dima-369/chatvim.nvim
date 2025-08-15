# Main changes

- I dropped the `npm` dependency and only implemented Google Gemini backend, fully in Lua

**This really shouldn't be a fork, but whatever...**

# Chatvim

**Pure Lua AI chat with markdown files in Neovim using Google Gemini.**

Unlike many other Neovim AI plugins, **Chatvim uses a plain markdown document as
the chat window**. No special dialogs or UI elements are required. This version
is completely rewritten in pure Lua with no Node.js dependencies.

## Features

- **Pure Lua implementation** - No Node.js, TypeScript, or external dependencies
- **Google Gemini 2.5 Flash** - Fast and capable AI responses
- **Multiple concurrent chats** - Run multiple AI conversations simultaneously
- **Status bar integration** - Shows active chat count in lualine/status bar
- **Markdown-based conversations** - Save, version, and share chat files
- **Streaming responses** - Real-time AI output with visual feedback

## Usage

Simply type a message into a markdown file in Neovim, and then run the `:ChatvimComplete`
command to get a response from Google Gemini. The entire file content is sent as context.

## Chat Delimiters

The plugin uses delimiters to separate different parts of the conversation:

- `# === USER ===` for user messages
- `# === ASSISTANT ===` for assistant messages  
- `# === SYSTEM ===` for system messages

If no delimiter is present, the entire document is treated as user input, and
`# === ASSISTANT ===` will be automatically added before the AI response.

## Installation

**Requirements:**
- Set `GOOGLE_API_KEY` or `GEMINI_API_KEY` environment variable with your Google AI API key
- `curl` command available in your system PATH

**LazyVim:**

```lua
{
  "chatvim/chatvim.nvim",
  config = function()
    require("chatvim")
  end,
}
```

**Packer:**

```lua
use {
  "chatvim/chatvim.nvim",
  config = function()
    require("chatvim")
  end,
}
```

## Commands

```vim
:ChatvimComplete
```

Completes the current markdown document using Google Gemini. If no delimiters are
present, it will treat the input as user input and append a response.

```vim
:ChatvimStop
```

Stops the streaming response in the current buffer.

```vim
:ChatvimStopAll
```

Stops all active streaming responses across all buffers.

```vim
:ChatvimNew [direction]
```

`direction` can be blank or `left`, `right`, `top`, or `bottom`. Opens a new
(unsaved) markdown document in a new split window for a new chat session. If
`direction` is not specified, it defaults to the current window.

## Optional Keybindings

Keymaps are disabled by default. You can enable and customize them via setup and then apply them:

```lua
require('chatvim').setup({
  keymaps = {
    enabled = true,        -- default: false
    prefix = '<Leader>cv', -- default prefix
    complete = 'c',        -- :ChatvimComplete -> <Leader>cvc
    stop = 's',            -- :ChatvimStop     -> <Leader>cvs
    stop_all = 'S',        -- :ChatvimStopAll  -> <Leader>cvS
    new = {
      current = 'nn', left = 'nl', right = 'nr', top = 'nt', bottom = 'nb',
    },
    help = {
      current = 'hh', left = 'hl', right = 'hr', top = 'ht', bottom = 'hb',
    },
  }
})
require('chatvim').apply_keymaps()
```

If you enable the defaults above, the following mappings will be set:

```lua
<Leader>cvc  -- :ChatvimComplete (start completion)
<Leader>cvs  -- :ChatvimStop (stop current buffer completion)
<Leader>cvS  -- :ChatvimStopAll (stop all completions)
<Leader>cvnn -- :ChatvimNew (new chat in current window)
<Leader>cvnl -- :ChatvimNewLeft (new chat in left split)
<Leader>cvnr -- :ChatvimNewRight (new chat in right split)
<Leader>cvnt -- :ChatvimNewTop (new chat in top split)
<Leader>cvnb -- :ChatvimNewBottom (new chat in bottom split)
<Leader>cvhh -- :ChatvimHelp (help in current window)
<Leader>cvhl -- :ChatvimHelpLeft (help in left split)
<Leader>cvhr -- :ChatvimHelpRight (help in right split)
<Leader>cvht -- :ChatvimHelpTop (help in top split)
<Leader>cvhb -- :ChatvimHelpBottom (help in bottom split)
```

## Status Bar Integration

For **lualine** users, here’s a full example that shows the Chatvim status and auto-refreshes when sessions start/stop:

```lua
-- Example lualine configuration with Chatvim status integration
-- Add this to your Neovim configuration

require('lualine').setup {
  options = {
    theme = 'auto',
    component_separators = { left = '', right = ''},
    section_separators = { left = '', right = ''},
  },
  sections = {
    lualine_a = {'mode'},
    lualine_b = {'branch', 'diff', 'diagnostics'},
    lualine_c = {'filename'},
    lualine_x = {
      -- Chatvim status integration
      {
        function()
          return require('chatvim').get_status()
        end,
        color = { fg = '#98be65' }, -- Optional: customize color
      },
      'encoding', 
      'fileformat', 
      'filetype'
    },
    lualine_y = {'progress'},
    lualine_z = {'location'}
  },
  inactive_sections = {
    lualine_a = {},
    lualine_b = {},
    lualine_c = {'filename'},
    lualine_x = {'location'},
    lualine_y = {},
    lualine_z = {}
  },
}

-- Optional: Register a callback to refresh lualine when status changes
require('chatvim').register_status_callback(function(active_count)
  -- This will automatically refresh lualine when chat status changes
  vim.schedule(function()
    require('lualine').refresh()
  end)
end)
```

The status will show:
- Nothing when no chats are active
- "🤖 1 chat" when one completion is running
- "🤖 X chats" when multiple completions are running
