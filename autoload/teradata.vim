if exists('g:autoloaded_db_teradata')
  finish
endif
let g:autoloaded_db_teradata = 1

function! s:writebteq(bteq)
	" create file
	let bytecode = system("touch " . fnameescape(g:td_script))

	if v:shell_error > 0
		echom 'Could not create temp bteq script'
		finish
	endif
	
	" set permission
	let bytecode = system('chmod u+x ' . fnameescape(g:td_script))
	if v:shell_error > 0
		echom 'Could not change file permission'
		finish
	endif
	" write into file
	call writefile(a:bteq, glob(fnameescape(g:td_script)), 'b')
endfunction

function! s:buildbteqtable(sql, user, tdpid, pattern, ...)
	let body = ['#!/bin/bash', 'bteq > ' . g:td_log . ' <<EOF' , '.LOGON ' . a:tdpid . '/' . a:user 
	\ . ',\$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.os rm -f ' . g:td_out , ' ']
	\ + ['.EXPORT FILE = ' . g:td_out . ';', ' ']
	\ + ["SELECT DATABASENAME||'.'||TABLENAME (TITLE '')"]
	\ + ["FROM DBC.TABLESV WHERE DATABASENAME||TABLENAME like '" . a:pattern . "'"]
	\ + [';'] 
	\ + ['.LOGOFF']
	\ + ['.EXIT']
	\ + ['EOF', ' ']
	return body
endfunction

function! s:buildbteqfield(sql, user, tdpid, pattern, ...)
	let body = ['#!/bin/bash', 'bteq > ' . g:td_log . ' <<EOF' , '.LOGON ' . a:tdpid . '/' . a:user 
	\ . ',\$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.os rm -f ' . g:td_out , ' ']
	\ + ['.EXPORT FILE = ' . g:td_out . ';', ' ']
	\ + ["SELECT COLUMNNAME (TITLE '') "]
	\ + ["FROM DBC.COLUMNSV WHERE DATABASENAME||TABLENAME like '" . a:pattern . "'"]
	\ + [';']
	\ + ['.LOGOFF']
	\ + ['.EXIT']
	\ + ['EOF', ' ']
	return body
endfunction

function! s:buildbteq(sql, user, tdpid, ...)
	let body = ['#!/bin/bash', 'bteq > ' . g:td_log . ' <<EOF' , '.LOGON ' . a:tdpid . '/' . a:user 
	\ . ',\$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.os rm -f ' . g:td_out , ' ']
	\ + ['.set WIDTH 10000', ' ']
	\ + ['.EXPORT FILE = ' . g:td_out . ';', ' ']
	\ + split(a:sql, '\n')
	\ + [';']
	\ + ['.LOGOFF']
	\ + ['.EXIT']
	\ + ['EOF', ' ']
	return body
endfunction

function! s:replaceenvvar(sql)

	let l:clean_sql = a:sql
	for [key, value] in items(g:td_replace)
		let l:clean_sql = substitute(l:clean_sql,key,value,"g")
	endfor
	"echom l:clean_sql
	return l:clean_sql
endfunction

function! s:addexplain(sql)
	"add an explain to the beginning of every query 
	let l:explain = substitute(a:sql, '\(.\{-};\)', '\n Explain \1 ', 'g')
	
	"echom l:explain
	return l:explain 
endfunction

function! s:addsample(sql, sample)
	"add sample at the end of every query
	let l:sample = substitute(a:sql, '\(\(.\{-}\);\)', '\2 SAMPLE ' . a:sample . ';', 'g')
	
	"echom l:sample
	return l:sample 
endfunction
function! s:execbteq()

	"let bytecode = system('./' . fnameescape(g:td_script))
	let bytecode = system(fnameescape(g:td_script))
	let bteq_result = {'rc' : v:shell_error, 'msg': bytecode}
	"return v:shell_error 
	return bteq_result
endfunction

function! s:removefile(...)
	for file in a:000
		let bytecode = system('ls ' . fnameescape(file))
		if (v:shell_error == 0)
			let bytecode = system('rm -f ' . fnameescape(file)) 
		endif
	endfor
		
endfunction


function! s:runSql(sql, user, tdpid, option, table, sample, ...)
	let clean_sql = a:sql
	if (clean_sql !~ '\;')
		let clean_sql = clean_sql . ';'
	endif
	if (a:option ==? 'syntax')
		let clean_sql = s:addexplain(clean_sql)
		let bteq = s:buildbteq(clean_sql, a:user, a:tdpid)
        call s:writebteq(bteq)
		let res = s:execbteq()
		if (res.rc == 0)
			call s:removefile(g:td_script, g:td_out, g:td_log)
			echom "No syntax error"
		else
			call s:removefile(g:td_script, g:td_out, g:td_log)
			"execute "vsplit " . fnameescape(g:td_log) 		
			echom res.msg
		endif
	
	elseif (a:option ==? 'explain')
		let clean_sql = s:addexplain(clean_sql)
		let bteq = s:buildbteq(clean_sql, a:user, a:tdpid)
        call s:writebteq(bteq)
		let res = s:execbteq()
		if (res.rc == 0)
			call s:removefile(g:td_script, g:td_log)
			execute "vsplit " . fnameescape(g:td_out)
		else
			call s:removefile(g:td_script, g:td_out, g:td_log)
			" execute "vsplit " . fnameescape(g:td_log) 		
			echom res.msg
		endif

	elseif (a:option ==? 'output')
		let clean_sql = s:addsample(clean_sql, a:sample)
		let bteq = s:buildbteq(clean_sql, a:user, a:tdpid)
        call s:writebteq(bteq)
		let res = s:execbteq()
		if (res.rc == 0)
			call s:removefile(g:td_script, g:td_log)
			execute "vsplit " . fnameescape(g:td_out)
		else
			call s:removefile(g:td_script, g:td_out, g:td_log)
			" execute "vsplit " . fnameescape(g:td_log) 		
			echom res.msg
		endif

	elseif (a:option ==? 'field')
		let pattern = a:table
		let bteq = s:buildbteqfield(clean_sql, a:user, a:tdpid, pattern)
        call s:writebteq(bteq)
		let res = s:execbteq()
		if (res.rc == 0)
			call s:removefile(g:td_script, g:td_log)
			execute "vsplit " . fnameescape(g:td_out)
		else
			call s:removefile(g:td_script, g:td_out)
			execute "vsplit " . fnameescape(g:td_log) 		
		endif

	elseif (a:option ==? 'table')
		let pattern = a:table
		let bteq = s:buildbteqtable(clean_sql, a:user, a:tdpid, pattern)
        call s:writebteq(bteq)
		let res = s:execbteq()
		if (res.rc == 0)
			call s:removefile(g:td_script, g:td_log)
			execute "vsplit " . fnameescape(g:td_out)
		else
			call s:removefile(g:td_script, g:td_out)
			execute "vsplit " . fnameescape(g:td_log) 		
		endif
	endif	
endfunction

function! teradata#parser(param, bang, range, ...)
	let l:cmd = substitute(a:param, '\s\+', ' ', 'g')
	"No argument passed : default behavior
    if a:range > 0
        " Get the line and column of the visual selection marks
        let [lnum1, col1] = getpos("'<")[1:2]
        let [lnum2, col2] = getpos("'>")[1:2]
		" Get all the lines represented by this range
		let lines = getline(lnum1, lnum2)         

		" The last line might need to be cut if the visual selection didn't end on the last column
		let lines[-1] = lines[-1][: col2 - (&selection == 'inclusive' ? 1 : 2)]
		" The first line might need to be trimmed if the visual selection didn't start on the first column
		let lines[0] = lines[0][col1 - 1:]

		" Get the desired text
		let selectedText = join(lines, "\n")  
	else 
		let saved_unnamed_register = @@
		let selectedText = @@
    endif

	let clean_sql = (empty(g:td_replace) ? selectedText : s:replaceenvvar(selectedText))

	if a:param == ''
		" no param : default behavior enable
		call s:runSql(clean_sql, g:td_user, g:td_tdpid, 'syntax', '', '')
	else
		"otherwise parsing command parameter
		let l:user = matchstr(l:cmd, '-u\s\w*')
		let l:tdpid = matchstr(l:cmd, '-t\s\w*')
		let l:option = matchstr(l:cmd, '-o\s\w*')
		let l:user = (l:user == '' ? g:td_user : l:user[3:])
		let l:tdpid = (l:tdpid == '' ? g:td_tdpid : l:tdpid[3:])
		let l:option = (l:option == '' ? 'syntax' : l:option[3:])
		let l:table = matchstr(l:cmd, '-p\s\(\w\|%\)*')
		let l:sample = matchstr(l:cmd, '-s\s\w*')
		let l:sample = (l:sample == '' ? '10' : l:sample[3:])

		call s:runSql(clean_sql, l:user, l:tdpid, l:option, l:table[3:], l:sample)
	endif
	if a:range == 0
		let @@ = saved_unnamed_register
	endif

endfunction

