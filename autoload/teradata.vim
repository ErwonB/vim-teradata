if exists('g:autoloaded_db_teradata')
  finish
endif
let g:autoloaded_db_teradata = 1

function! s:writebteq(bteq)
	" write into file
	call writefile(a:bteq, fnameescape(g:td_script))
endfunction


function! s:buildbteqtable(sql, user, tdpid, pattern, ...) abort
    let body = [
        \ '.logmech ' . g:log_mech,
        \ '.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');',
        \ '.EXPORT FILE = ' . g:td_out . ';',
        \ "lock row for access",
        \ "select DATABASENAME||'.'||TABLENAME (TITLE '')",
        \ "from DBC.TABLESV where DATABASENAME||TABLENAME like '" . a:pattern . "'",
        \ ';',
        \ '.LOGOFF',
        \ '.EXIT',
    \ ]
    return body
endfunction

function! s:buildbteqfield(sql, user, tdpid, pattern, ...) abort
    let body = [
        \ '.logmech ' . g:log_mech,
        \ '.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');',
        \ '.EXPORT FILE = ' . g:td_out . ';',
        \ "lock row for access",
        \ "select COLUMNNAME (TITLE '') ",
        \ "from DBC.COLUMNSV where DATABASENAME||TABLENAME like '" . a:pattern . "'",
        \ ';',
        \ '.LOGOFF',
        \ '.EXIT',
    \ ]
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

    let body = [
        \   '.logmech ' . g:log_mech,
        \   '.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');',
        \   '.set titledashes off',
        \   '.set WIDTH 30000',
        \   '.set retlimit ' . g:td_retlimit . ' * ',
        \   '.set separator ''@''',
        \   '.EXPORT FILE = ' . g:td_resultsets .'/' . l:max_num . ';',
        \ ]

        let body += split(a:sql, '\n')

        let body += [
        \   '.LOGOFF',
        \   '.EXIT',
        \ ]

	return { 'bteq' : body, 'max_num' : l:max_num }
endfunction

function! s:buildbteq(sql, user, tdpid, ...) abort
    let body = [
        \ '.logmech ' . g:log_mech,
        \ '.logon ' . a:tdpid . '/' . a:user . ',$tdwallet(' . a:user . ');',
        \ '.set titledashes off',
        \ '.set WIDTH 30000',
        \ '.set separator ''@''',
        \ '.EXPORT FILE = ' . g:td_out . ';',
    \ ]
    
    let body += split(a:sql, '\n') " Add the SQL content from the 'sql' argument
    
    let body += [
        \ ';',
        \ '.LOGOFF',
        \ '.EXIT',
    \ ]
    
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

    let bytecode = system('bteq < ' . fnameescape(g:td_script) . ' > ' . fnameescape(g:td_log))
    let bteq_result = {'rc' : v:shell_error, 'msg': bytecode}
	return bteq_result
endfunction

function! s:removefile(...)
	for file in a:000
        if filereadable(fnameescape(file))
            call delete(fnameescape(file))
        endif

	endfor
		
endfunction

function! ExtractRowsFound(logfile)
    let rows_found = ''

    let lines = readfile(a:logfile)
    for line in lines
        if line =~ '^ \*\*\* Query completed\.\s\+\(\d\+\) rows found\.'
            let rows_found = matchstr(line, '\d\+')
            break
        endif
    endfor

    return rows_found
endfunction

function! teradata#CompareFileMtime(f1, f2)
    return getftime(a:f2) - getftime(a:f1)
endfunction

function! s:OpenPair(file)
  let l:query_file = g:td_queries . '/' . a:file
  let l:result_file = g:td_resultsets . '/' . a:file

  wincmd p
  only

  let l:current_buf = bufnr('%')
  let l:buffers = filter(range(1, bufnr('$')), 'buflisted(v:val) && v:val != l:current_buf')

  let l:queries_dir = fnamemodify(g:td_queries, ':p')
  let l:resultsets_dir = fnamemodify(g:td_resultsets, ':p')

  for l:buf in l:buffers
    let l:buf_name = fnamemodify(bufname(l:buf), ':p')
    if !empty(l:buf_name) &&
          \ (stridx(l:buf_name, l:queries_dir) == 0 ||
          \  stridx(l:buf_name, l:resultsets_dir) == 0)
      execute 'bdelete ' . l:buf
    endif
  endfor

  execute 'edit ' . fnameescape(l:query_file)

  if filereadable(l:result_file)
    execute 'belowright split ' . fnameescape(l:result_file)
    setlocal filetype=csv
    wincmd p
  endif
endfunction


function! teradata#ShowQueries()
    let l:files = sort(glob(g:td_queries . '/*', 0, 1), 'teradata#CompareFileMtime')

    let l:basenames = map(copy(l:files), 'fnamemodify(v:val, ":t")')

    belowright 10split
    enew
    setlocal buftype=nofile
    setlocal bufhidden=delete
    setlocal noswapfile
    setlocal nobuflisted
    setlocal winfixheight
    file Teradata\ Queries

    call setline(1, l:basenames)
    setlocal nomodifiable

    nnoremap <buffer> <silent> <CR> :call <SID>OpenPair(getline('.'))<CR>

    
    setlocal updatetime=500
    augroup TeradataPreview
        autocmd!
        autocmd CursorHold <buffer> call <SID>PreviewQuery(getline('.'))
    augroup END

endfunction

function! s:PreviewQuery(file)
    let l:query_file = g:td_queries . '/' . a:file
    if !filereadable(l:query_file)
        return
    endif

    if has('nvim')
        let l:buf = nvim_create_buf(v:false, v:true)
        call setbufline(l:buf, 1, readfile(l:query_file))
        call setbufvar(l:buf, '&modifiable', 0)

        let l:cursor = getpos('.')
        let l:line = l:cursor[1]
        let l:col = l:cursor[2]

        let l:win_opts = {
            \ 'relative': 'win',
            \ 'win': win_getid(),
            \ 'row': l:line - 1,
            \ 'col': l:col + 10,
            \ 'width': 80,
            \ 'height': 10,
            \ 'style': 'minimal',
            \ 'border': 'single'
        \ }

        if exists('s:preview_win') && nvim_win_is_valid(s:preview_win)
            call nvim_win_close(s:preview_win, v:true)
        endif

        let s:preview_win = nvim_open_win(l:buf, v:false, l:win_opts)
    else
        let l:preview_win = -1
        for l:w in range(1, winnr('$'))
            if getwinvar(l:w, '&previewwindow')
                let l:preview_win = l:w
                break
            endif
        endfor

        if l:preview_win != -1
            execute l:preview_win . 'wincmd w'
            execute 'edit ' . fnameescape(l:query_file)
            wincmd p
        else
            execute 'pedit ' . fnameescape(l:query_file)
        endif
    endif
endfunction


function! teradata#FindQueryByContent() abort
   if !exists('*fzf#run')
    echohl WarningMsg | echo "Error: fzf.vim plugin not found." | echohl None
    return
  endif
  if !executable('rg')
    echohl WarningMsg | echo "Error: ripgrep (rg) is not installed or not in your PATH." | echohl None
    return
  endif
  if !executable('bat')
    echohl WarningMsg | echo "Error: bat is not installed or not in your PATH." | echohl None
    return
  endif

  " Ensure the query directory is configured.
  if !exists('g:td_queries') || !isdirectory(g:td_queries)
    echohl WarningMsg | echo "Error: Query directory g:td_queries is not set or found." | echohl None
    return
  endif

  let l:rg_command = 'rg --column --line-number --no-heading --smart-case "" .'
  let l:fzf_options = [
        \ '--ansi',
        \ '--prompt="Grep Queries> "',
        \ '--delimiter=:',
        \ '--preview="bat --style=numbers --color=always --highlight-line {2} -- {1}"',
        \ '--preview-window=right:60%:wrap'
        \ ]

  call fzf#run({
        \ 'source': l:rg_command,
        \ 'sink': function('s:ProcessFzfSelection'),
        \ 'options': join(l:fzf_options, ' '),
        \ 'dir': g:td_queries
        \ })
endfunction

function! s:ProcessFzfSelection(selected_line) abort
  let l:parts = split(a:selected_line, ':', 3)
  let l:filename = fnamemodify(l:parts[0], ":t")

  call s:OpenPair(l:filename)
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
                let dir = g:td_resultsets
                let num = bteq['max_num']
                let file_path = dir . '/' . num
                let tmp_path = file_path . '.tmp'

                let lines = readfile(file_path)
                let new_lines = []

                for line in lines
                  let parts = split(line, '@')
                  let trimmed_parts = map(parts, {_, part -> substitute(part, '\s\+$', '', '')})
                  let new_line = join(trimmed_parts, '@')
                  call add(new_lines, new_line)
                endfor

                let write_result = writefile(new_lines, tmp_path)
                if write_result != 0
                  echoerr 'Failed to write temporary file: ' . tmp_path
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

  " Handle selected text based on whether a visual range is provided
  if a:range > 0
    let [lnum1, col1] = getpos("'<")[1:2]
    let [lnum2, col2] = getpos("'>")[1:2]
    let l:lines = getline(lnum1, lnum2)
    let l:lines[-1] = l:lines[-1][: col2 - (&selection == 'inclusive' ? 1 : 2)]
    let l:lines[0] = l:lines[0][col1 - 1:]
    let l:selected_text = join(l:lines, "\n")
  else
    let l:saved_unnamed_register = @@
    let l:selected_text = @@
  endif

  " Clean SQL by replacing environment variables if configured
  let l:clean_sql = empty(g:td_replace) ? l:selected_text : s:replaceenvvar(l:selected_text)

  " Default options
  let l:opts = {
        \ 'user': g:td_user,
        \ 'tdpid': g:td_tdpid,
        \ 'option': 'syntax',
        \ 'table': '',
        \ 'sample': '500'
        \ }

  if l:cmd !=# ''
    " Parse command-line arguments for overrides
    let l:args = split(l:cmd)
    let l:i = 0
    while l:i < len(l:args)
      let l:arg = l:args[l:i]
      if l:arg ==# '-u' && l:i + 1 < len(l:args)
        let l:opts.user = l:args[l:i + 1]
        let l:i += 2
      elseif l:arg ==# '-t' && l:i + 1 < len(l:args)
        let l:opts.tdpid = l:args[l:i + 1]
        let l:i += 2
      elseif l:arg ==# '-o' && l:i + 1 < len(l:args)
        let l:opts.option = l:args[l:i + 1]
        let l:i += 2
      elseif l:arg ==# '-p' && l:i + 1 < len(l:args)
        let l:opts.table = l:args[l:i + 1]
        let l:i += 2
      elseif l:arg ==# '-s' && l:i + 1 < len(l:args)
        let l:opts.sample = l:args[l:i + 1]
        let l:i += 2
      else
        echoerr 'Unknown or incomplete option: ' . l:arg
        return
      endif
    endwhile
  endif

  " Execute the SQL with parsed options
  call s:runSql(l:clean_sql, l:opts.user, l:opts.tdpid, l:opts.option, l:opts.table, l:opts.sample)

  " Restore unnamed register if no visual range was used
  if a:range == 0
    let @@ = l:saved_unnamed_register
  endif
endfunction

