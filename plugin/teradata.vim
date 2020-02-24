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

" defining a command to call TP
command! -bang -nargs=* TD execute teradata#parser(<q-args>, <bang>0)

augroup teradata
	" database connection paramete
	let g:td_user='BOURREE'
	let g:td_tdpid='192.168.0.4'
	" temp file location and name 
	let g:td_script='~/tdsql'
	let g:td_out='~/tdout'
	let g:td_log='~/tdlog'
	" Variable replacement before running queries
	let g:td_replace={'${DB_NAME}' : 'ZDP_DVL_H1',
									\ '${STTM_DT}' : '2019-05-31',
									\}
augroup END
