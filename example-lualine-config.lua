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