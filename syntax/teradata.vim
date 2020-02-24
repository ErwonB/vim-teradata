"Overwrite supported languages
"let language_list = ['sql', 'depl', 'bteq', 'tpt']
if exists("b:current_syntax") 
	finish
endif

syntax clear
syntax case ignore

syntax region SqlComment start="/\*" end="\*/"
syntax match SqlComment "\-\-.*$"
syntax region SqlString start="'" end="'"
syntax match SqlNumber "[+-]\?\<\d\+\(\.\d*\)\?\(e[+-]\?\d\+\)\?\>"
syntax match SqlStmtDelim ";"

syntax keyword SqlConnector SELECT FROM WHERE INNER LEFT RIGHT FULL OUTER JOIN 

syntax match SqlDataType "\<DOUBLE\s\+PRECISION\>"
syntax match SqlDataType "\<TO\s\+\(HOUR\|MINUTE\|MONTH\|SECOND\)\>"
syntax match SqlDataType "\<WITH\s\+TIMEZONE\>"
syntax match SqlDataType "\<LONG\s\+\(VARCHAR\|VARGRAPHIC\)\>"
syntax match SqlDataType "\<BINARY\s\+LARGE\s\+OBJECT\>"
syntax match SqlDataType "\<CHAR\(ACTER\)\?\(\s\+VARYING\)\?\>"
syntax match SqlDataType "\<CHARACTER\s\+LARGE\s\+OBJECT\>"
syntax match SqlDataType "\<TIME\(STAMP\)\?\>"

syntax match SqlCmd "\<CHARACTER\s\+SET\>" 
syntax match SqlCmd "\<EXTERNAL\s\+NAME\>"
syntax match SqlCmd "\<WITH\>\(\s*TIMEZONE\)\@!"

syntax match SqlOperator "=" 
syntax match SqlOperator ">"
syntax match SqlOperator "<"


syntax match BteqCmd "^\s*\.ABORT\>"
syntax match BteqCmd "^\s*\.EXIT\>"
syntax match BteqCmd "^\s*\.EXPORT\>"
syntax match BteqCmd "\.GOTO"
syntax match BteqCmd "^\s*\.HANG\>"
syntax match BteqCmd "^\s*\.HELP\>"
syntax match BteqCmd "^\s*\.IF\>"
syntax match BteqCmd "^\s*\.IMPORT\>"
syntax match BteqCmd "^\s*\.LABEL\>"
syntax match BteqCmd "^\s*\.LOGDATA\>"
syntax match BteqCmd "^\s*\.LOGMECH\>"
syntax match BteqCmd "^\s*\.LOGOFF\>"
syntax match BteqCmd "^\s*\.LOGON\>"
syntax match BteqCmd "^\s*\.MESSAGEOUT\>"
syntax match BteqCmd "^\s*\.OS\>"
syntax match BteqCmd "^\s*\.PACK\>"
syntax match BteqCmd "^\s*\.QUIT\>"
syntax match BteqCmd "^\s*\.REMARK\>"
syntax match BteqCmd "^\s*\.REPEAT\>"
syntax match BteqCmd "^\s*\.RUN\>"
syntax match BteqCmd "^\s*\.SET\>"
syntax match BteqCmd "^\s*\.SHOW\>"
syntax match BteqCmd "^\s*\.TSO\>"


syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?AUTOKEYRETRIEVE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?DECIMALDIGITS\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?DEFAULTS\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?ECHOREQ\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?ENCRYPTION\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?ERRORLEVEL\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?ERROROUT\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?EXPORTEJECT\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?FOLDLINE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?FOOTING\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?FORMAT\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?FORMCHAR\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?FULLYEAR\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?HEADING\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?INDICDATA\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?LARGEDATAMODE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?LOGONPROMPT\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?MAXERROR\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?NOTIFY\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?NULL\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?OMIT\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?PAGEBREAK\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?PAGELENGTH\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?QUIET\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?RECORDMODE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?REPEATSTOP\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?REPORTALIGN\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?RETCANCEL\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?RETLIMIT\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?RETRY\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?RTITLE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SEPARATOR\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SESSION\s\+CHARSET\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SESSION\s\+RESPBUFLEN\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SESSION\s\+SQLFLAG\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SESSION\s\+\(TRANSACTION\|TRANS\)\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SESSION\s\+TWORESPBUFS\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SESSIONS\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SIDETITLES\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SKIPDOUBLE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SKIPLINE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?SUPPRESS\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?TDP\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?TIMEMSG\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?TITLEDASHES\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?UNDERLINE\>"
syntax match BteqCmd2 "^\s*\.\(SET\s\+\)\?WIDTH\>"


syntax keyword BteqKW FILE CONTROLS CONTROL ERRORMAP VERSIONS VERSION ACTIVITYCO ACTIVITYCOUNT ERRORCODE
"SqlFunc

"SqlOperator

"SqlPredicate

highlight link SqlConnector Special
highlight link SqlComment Comment
highlight link SqlString String
highlight link SqlNumber Number
highlight link SqlStmtDelim Special
highlight link SqlCmd Statement
highlight link SqlCmd2  Statement
highlight link SqlFunc Function
highlight link SqlDataType Type
highlight link SqlDataType2 Type
highlight link SqlOperator Operator
highlight link BteqCmd Statement
highlight link BteqCmd2 Statement
highlight link BteqKW Statement

let b:current_syntax = "teradata"
