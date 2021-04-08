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

augroup teradata
	" database connection paramete
	let g:td_user='ZDP_DVL_H1_US_BATCH'
	let g:td_tdpid='10.245.67.1'
	" temp file location and name 
	let g:td_script='/users/bourren/tmp/tdsql'
	let g:td_out='/users/bourren/tmp/tdout'
	let g:td_log='/users/bourren/tmp/tdlog'
	" Variable replacement before running queries
	let g:td_replace={'${DB_NAME}' : 'ZDP_DVL_H1',
                    \ '${STTM_DT}' : '2019-05-31',
                    \ '${ENT_LIST}' : '88200',
                    \ '${LOT_ENT_LIST}' : '88200',
                    \ '${ENVIRONMENT}' : 'ZDP_DVL_H1',
                    \ '${DB_B_TEC}' : 'ZDP_DVL_H1_DB_TEC',
                    \ '${DB_B_SOC}' : 'ZDP_DVL_H1_DB_SOC',
                    \ '${JOB_ID}' : '1',
                    \}
augroup END

