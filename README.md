# vim-teradata

The **core Neovim plugin** for Teradata SQL development.  
It provides query execution via BTEQ, on-the-fly syntax diagnostics, schema-aware autocompletion, query history, and results editing.

---

## Features
- **Query execution via BTEQ**: Run single queries, multistatement batches, visual ranges, and track jobs in the background.
- **Tree-sitter diagnostics**: Fast syntax and reference linting for Teradata SQL statements.
- **Schema-aware autocompletion**: Native completion for tables, columns, and databases supporting `blink.cmp`, `nvim-cmp`, and `omnifunc`.
- **Query history & bookmarks**: Search past queries using your choice of picker (`fzf-lua`, `snacks`, `telescope`, `fzf.vim`, or built-in `native` picker).
- **In-grid editing**: Edit query result tables directly with staged preview and updates generation.
- **Health check**: Built-in `:checkhealth vim-teradata` to verify TTU binaries, tree-sitter parsers, and connection profiles.

---

## Requirements
- **Neovim 0.12+**
- **Teradata Tools and Utilities (TTU)**: `bteq` on `$PATH` and `tdwallet` for passwordless authentication.
- **Tree-sitter parser**: `teradata` grammar installed.
- Optional: `blink.cmp` or `nvim-cmp` for autocompletion; `fzf-lua`, `snacks.nvim`, or `telescope.nvim` for fuzzy search.

---

## Installation

### Built-in package manager (Neovim 0.12+)
```lua
vim.pack.add('ErwonB/vim-teradata')

require('vim-teradata').setup({
  users = {
    { log_mech = 'TD2', user = 'MY_USER', tdpid = 'MY_HOST' },
  },
})
```

### lazy.nvim
```lua
{
  'ErwonB/vim-teradata',
  ft = { 'sql', 'teradata' },
  opts = {
    users = {
      { log_mech = 'TD2', user = 'MY_USER', tdpid = 'MY_HOST' },
    },
  },
}
```

---

## Documentation

For complete setup instructions, configuration options, and advanced usage:

👉 [teradata-nvim.com](https://teradata-nvim.com) or view `:help vim-teradata` inside Neovim.

---

## Health Check

Run `:checkhealth vim-teradata` to inspect your configuration and verify prerequisites.

---

## License
MIT
