# Main changes

- I dropped the `npm` dependency and only implemented Google Gemini backend, fully in Lua

# Chatvim

**Pure Lua AI chat with markdown files in Neovim using Google Gemini.**

Unlike many other Neovim AI plugins, **Chatvim uses a plain markdown document as
the chat window**. No special dialogs or UI elements are required. This version
is completely rewritten in pure Lua with no Node.js dependencies.

## Features

- **Pure Lua implementation** - No Node.js, TypeScript, or external dependencies
- **Google Gemini 2.0 Flash** - Fast and capable AI responses
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

## Default Keybindings

The plugin automatically sets up these keybindings:

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

For **lualine** users, add this to your lualine configuration to show active chat count:

```lua
require('lualine').setup {
  sections = {
    lualine_x = {
      function()
        return require('chatvim').get_status()
      end,
      'encoding', 'fileformat', 'filetype'
    },
  }
}
```

The status will show:
- Nothing when no chats are active
- "🤖 1 chat" when one completion is running
- "🤖 X chats" when multiple completions are running

## Model

This plugin uses **Google Gemini 2.0 Flash Experimental** which provides:
- Fast response times
- High-quality text generation
- Large context window (up to 8192 output tokens)
- Streaming responses for real-time feedback

## Copyright

Copyright (C) 2025 EarthBucks Inc.
