" Language:    Teradata SQL, BTEQ Commands, TPT
" Maintainer: Erwan Bourre 

" TODO : create BTEQ,SQL,SH+BTEQ,TPT snippet
" TODO : syntax sql inside BTEQ from SH
" TODO : Complete syntax

"comment test for reloading purposes
 if exists("g:loaded_teradata")
 	finish
 endif
let g:loaded_teradata = 1

" defining a command to call TD
command! -bang -range -nargs=* TD call teradata#parser(<q-args>, <bang>0, <range>)
command! -bang -range -nargs=* TDO call teradata#parser('-o output', <bang>0, <range>)
command! -bang TDH call teradata#PopulateQuickfix()

augroup teradata
    if has('win32') || has('win64')
        let g:teradata_win = 1
    elseif has('unix')
        let g:teradata_win = 0
    endif
	" database connection parameters
	let g:td_user='*****'
    let g:log_mech='ldap'
	let g:td_tdpid='*****'
	" temp file location and name 
	let g:td_script='/path/to/tmp/tdsql.bteq'
	let g:td_out='/path/to/tmp/tdsql.out'
	let g:td_log='/path/to/tmp/tdsql.log'
    " historisation of queries and resultsets
    let g:td_queries='/path/to/history/queries'
    let g:td_resultsets='/path/to/history/resultsets'
	" Variable replacement before running queries
    let g:td_env='xxxx'
	let g:td_replace={'${MY_VAR}' : 'REPLACEMENT',
                    \ '${OTHER_VAR}' : 'OTHER_REPLACE',
                    \}
augroup END

