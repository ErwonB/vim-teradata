au BufNewFile,BufRead *.sql set filetype=teradata
au BufNewFile,BufRead *.tpt set filetype=teradata
au BufNewFile,BufRead *.bteq set filetype=teradata
au BufNewFile,BufRead *.depl set filetype=teradata


" for the quickfix list
augroup AutoOpenSplit
    autocmd!
    autocmd BufEnter * if expand('%:p:h') == g:td_queries && exists('g:from_populate_quickfix') && g:from_populate_quickfix | call OpenCorrespondingFile() | endif
    autocmd QuitPre quickfix let g:from_populate_quickfix = 0

augroup END


