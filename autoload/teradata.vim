if exists('g:autoloaded_db_teradata')
  finish
endif
let g:autoloaded_db_teradata = 1

function! s:writebteq(bteq)
	" write into file
	call writefile(a:bteq, fnameescape(g:td_script))
endfunction

function! s:buildbteqtable(sql, user, tdpid, pattern, ...)
    let body = ['.logmech ' . g:log_mech, ' ']
    \ + ['.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.EXPORT FILE = ' . g:td_out . ';', ' ']
	\ + ["SELECT DATABASENAME||'.'||TABLENAME (TITLE '')"]
	\ + ["FROM DBC.TABLESV WHERE DATABASENAME||TABLENAME like '" . a:pattern . "'"]
	\ + [';'] 
	\ + ['.LOGOFF']
	\ + ['.EXIT']
	return body
endfunction

function! s:buildbteqfield(sql, user, tdpid, pattern, ...)
    let body = ['.logmech ' . g:log_mech, ' ']
    \ + ['.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.EXPORT FILE = ' . g:td_out . ';', ' ']
	\ + ["SELECT COLUMNNAME (TITLE '') "]
	\ + ["FROM DBC.COLUMNSV WHERE DATABASENAME||TABLENAME like '" . a:pattern . "'"]
	\ + [';']
	\ + ['.LOGOFF']
	\ + ['.EXIT']
	return body
endfunction

function! s:buildbteqoutput(sql, user, tdpid, ...)
    let l:files = split(glob(g:td_queries . '/*'), "\n")

    " Initialize max number
    let l:max_num = 0

    " Iterate through the files
    for l:file in l:files
        " Extract the filename
        let l:filename = fnamemodify(l:file, ':t')

        " Check if the filename is a number
        if l:filename =~ '^\d\+$'
            " Convert to number and compare
            let l:num = str2nr(l:filename)
            if l:num > l:max_num
                let l:max_num = l:num
            endif
        endif
    endfor

    let l:max_num += 1
    "save sql into query folder history
    call writefile(split(a:sql, '\n'), g:td_queries . '/' . l:max_num, 'a')

    let body = ['.logmech ' . g:log_mech, ' ']
    \ + ['.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.set titledashes off', ' ']
	\ + ['.set WIDTH 30000', ' ']
	\ + ['.set retlimit ' . g:td_retlimit . ' * ', ' ']
	\ + ['.set separator ''@''', ' ']
	\ + ['.EXPORT FILE = ' . g:td_resultsets .'/' . l:max_num . ';', ' ']
	\ + split(a:sql, '\n')
	\ + ['.LOGOFF']
	\ + ['.EXIT']
	return { 'bteq' : body, 'max_num' : l:max_num }
endfunction

function! s:buildbteq(sql, user, tdpid, ...)

    let body = ['.logmech ' . g:log_mech, ' ']
    \ + ['.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');', ' ' ]
	\ + ['.set titledashes off', ' ']
	\ + ['.set WIDTH 30000', ' ']
	\ + ['.set separator ''@''', ' ']
	\ + ['.EXPORT FILE = ' . g:td_out . ';', ' ']
	\ + split(a:sql, '\n')
	\ + [';']
	\ + ['.LOGOFF']
	\ + ['.EXIT']
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

    if (g:teradata_win == 0)
        let bytecode = system('bteq < '. fnameescape(g:td_script) . ' > ' . fnameescape(g:td_log))
        let bteq_result = {'rc' : v:shell_error, 'msg': bytecode}
    else
        let bytecode = system('powershell -Command "' . 'Get-Content -Path ' . fnameescape(g:td_script) . ' | & bteq | Out-File -FilePath ' . fnameescape(g:td_log) . '"')
        let bteq_result = {'rc' : v:shell_error, 'msg': bytecode}
    endif
	return bteq_result
endfunction

function! s:removefile(...)
	for file in a:000
        if filereadable(fnameescape(file))
            call delete(fnameescape(file))
        endif

	endfor
		
endfunction

"quicklist functionnality
function! teradata#PopulateQuickfix()
    let g:from_populate_quickfix = 1

    " let l:files = split(glob(g:td_queries . '/*'), "\n")
    if (g:teradata_win == 0)
        let l:files = split(system('ls -1t ' . fnameescape(g:td_queries) . '/*', '\n'))
    else
        let l:files = split(system('powershell -Command "' . 'Get-ChildItem ' . fnameescape(g:td_queries) . ' | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName } ' . '"', '\n'))
    endif

    let l:quickfix_list = []

    for l:file in l:files
        call add(l:quickfix_list, {'filename': l:file, 'lnum': 1, 'col': 1, 'text': ''})
    endfor

    call setqflist(l:quickfix_list)
    copen

endfunction

function! OpenCorrespondingFile()
    let l:current_file = expand('%:t')
    let l:corresponding_file = g:td_resultsets . '/' . l:current_file

let l:current_buf = bufnr('%')
    let l:quickfix_buf = bufnr('#')
    let l:buffers = filter(range(1, bufnr('$')), 'buflisted(v:val)')

    for l:buf in l:buffers
        if l:buf != l:current_buf && l:buf != l:quickfix_buf
            execute 'bdelete ' . l:buf
        endif
    endfor


    if filereadable(l:corresponding_file)
        execute 'belowright split ' . l:corresponding_file
        setlocal filetype=csv
    endif
endfunction

function! ExtractRowsFound(logfile)
    " Initialize the variable to store the result
    let rows_found = ''

    " Read the file line by line
    let lines = readfile(a:logfile)
    for line in lines
        " Check if the line matches the pattern
        if line =~ '^ \*\*\* Query completed\.\s\+\(\d\+\) rows found\.'
            " Extract the number of rows found
            let rows_found = matchstr(line, '\d\+')
            break
        endif
    endfor

    " Return the extracted value
    return rows_found
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
            set splitbelow
			execute "split " . fnameescape(g:td_out)
		else
			call s:removefile(g:td_script, g:td_out, g:td_log)
			" execute "vsplit " . fnameescape(g:td_log) 		
			echom res.msg
		endif

	elseif (a:option ==? 'output')
		" let clean_sql = s:addsample(clean_sql, a:sample)
		let bteq = s:buildbteqoutput(clean_sql, a:user, a:tdpid)
        call s:writebteq(bteq['bteq'])
		let res = s:execbteq()
		if (res.rc == 0)
            let l:actual_lines = ExtractRowsFound(g:td_log)
			call s:removefile(g:td_script, g:td_log)
            let filesize = getfsize(g:td_resultsets .'/' . bteq['max_num'] )
            if (filesize == 0)
                echom "No line"
            else
                if (g:teradata_win == 0)
                    let awk_cmd = 'awk -F@ ''{for(i=1;i<=NF;i++) gsub(/[[:space:]]+$/, "", $i); print}'' OFS=@ ' . g:td_resultsets .'/' . bteq['max_num'] . ' > ' . g:td_resultsets .'/' . bteq['max_num'] . '.tmp'
                    call system(awk_cmd)
                else
                    let replace_cmd = '(Get-Content ' . fnameescape(g:td_resultsets .'/' . bteq['max_num']) . ') -replace ''\s+@'', ''@'' | Set-Content ' . fnameescape(g:td_resultsets .'/' . bteq['max_num']) . '.tmp' 
                    call system('powershell -Command "' . replace_cmd . '"')
                endif
                if filereadable(fnameescape(g:td_resultsets .'/' . bteq['max_num'] . '.tmp'))
                        call rename(fnameescape(g:td_resultsets .'/' . bteq['max_num'] . '.tmp'), fnameescape(g:td_resultsets .'/' . bteq['max_num']))
                endif

                set splitbelow
                execute "split " . fnameescape(g:td_resultsets .'/' . bteq['max_num'])
                setlocal filetype=csv
                call csv#ArrangeCol(1,line('$'), 1, -1)
                write
            endif
            if (l:actual_lines != '' && str2nr(l:actual_lines) > str2nr(g:td_retlimit))
                echom l:actual_lines . ' actual lines, only ' . g:td_retlimit . ' displayed'
            endif
		else
			call s:removefile(g:td_script, g:td_log)
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
	elseif (a:option ==? 'help')

        split 
        resize 6
        enew
      " Set the buffer to be unmodifiable
          setlocal buftype=nofile
          setlocal bufhidden=wipe
          setlocal noswapfile

          " Insert the text
          call setline(1, ':TD : no param for syntax checking')
          call setline(2, ':TD -o explain  : to get the explain')
          call setline(3, ':TD -o table -p %%  : to get the list of tables matching the pattern')
          call setline(4, ':TD -o field -p table  : to get the list of fields matching the table')
          call setline(5, ':TD -o output  : to get the output of the selected query')
        setlocal nomodifiable
 
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
		let l:sample = (l:sample == '' ? '500' : l:sample[3:])

		call s:runSql(clean_sql, l:user, l:tdpid, l:option, l:table[3:], l:sample)
	endif
	if a:range == 0
		let @@ = saved_unnamed_register
	endif

endfunction

