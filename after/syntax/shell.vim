if exists('b:current_syntax')
  let s:current_syntax = b:current_syntax
  unlet b:current_syntax
endif

syntax include @teradata syntax/teradata.vim

let b:current_syntax = s:current_syntax

syntax region bteqBlock 
  \ matchgroup=bteqDelimiter 
  \ start=/.*bteq.*<<\s*EOF$/ 
  \ end=/^EOF$/ 
  \ contains=@teradata 
  \ keepend

highlight default link bteqDelimiter Delimiter
