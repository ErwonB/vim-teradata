if exists("g:loaded_teradata")
    finish
endif
let g:loaded_teradata = 1

lua require('vim-teradata').setup()
