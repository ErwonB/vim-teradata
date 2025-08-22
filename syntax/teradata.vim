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
" syntax match SqlStmtDelim ";"

syntax keyword SqlConnector SELECT SEL DELETE DEL UPDATE UPD FROM INNER RIGHT LEFT OUTER JOIN
syntax keyword SqlConnector MERGE INTO INSERT INS FULL WHERE

syntax keyword SqlFunc ABS ACOS ACOSH ACTIVITY_COUNT ADD_MONTHS AGGGEOMINTERSECTION AGGGEOMUNION
syntax keyword SqlFunc APPLNAME ASIN ASINH ATAN ATAN2 ATANH ATTRIBUTE AVE AVERAGE AVG 
syntax keyword SqlFunc BITAND BITNOT BITOR BITXOR BOTH 
syntax keyword SqlFunc CASE_N  CEILING CHAR_LENGTH CHAR2HEXINT CHARACTER_LENGTH
syntax keyword SqlFunc CHARACTERS CHARS CLASS_ORIGIN COALESCE COLUMN_NAME COMMAND_FUNCTION
syntax keyword SqlFunc COMMAND_FUNCTION_CODE COMPRESS CONDITION_IDENTIFIER CONDITION_NUMBER CONTAINS
syntax keyword SqlFunc CORR COS COSH COSTS COUNT COUNT_SET COVAR_POP COVAR_SAMP COVARIANCE CREATOR
syntax keyword SqlFunc CS CSUM CURRENT_DATE CURRENT_ROLE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER 
syntax keyword SqlFunc DATABASE_NAME DECOMPRESS DEGREES 
syntax keyword SqlFunc ERRORCODE EXP EXTRACT 
syntax keyword SqlFunc FLOOR FOLLOWING FORMAT FRIDAY 
syntax keyword SqlFunc GCOUNT GEOSEQUENCEFROMROWS GEOSEQUENCETOROWS GETBIT GSUM GREATEST
syntax keyword SqlFunc HASHAMP HASHBAKAMP HASHBUCKET HASHROW 
syntax keyword SqlFunc KURTOSIS 
syntax keyword SqlFunc LDIFF LEADING LN LOG LOWER LAG LEAD LEAST
syntax keyword SqlFunc MAVG MAX MCHARACTERS MDIFF MEETS MESSAGE_LENGTH MESSAGE_TEXT MIN MINDEX
syntax keyword SqlFunc MLINREG MOD MONDAY MONTH_BEGIN MONTH_END MORE MOVE_DATE MSUBSTR MSUM 
syntax keyword SqlFunc NAMED NULLIF NULLIFZERO NUMBER 
syntax keyword SqlFunc OCTET_LENGTH OFF OVER OVERLAPS OWNER 
syntax keyword SqlFunc P_INTERSECT P_NORMALIZE PERCENT_RANK POSITION PRECEDES PRECEDING PRIOR 
syntax keyword SqlFunc QUANTILE 
syntax keyword SqlFunc RADIANS RANDOM RANGE_N RANK RDIFF REGR_AVGX REGR_AVGY REGR_COUNT
syntax keyword SqlFunc REGR_INTERCEPT REGR_R2 REGR_SLOPE REGR_SXX REGR_SXY REGR_SYY
syntax keyword SqlFunc RETURNED_SQLSTATE ROTATELEFT ROTATERIGHT ROW_COUNT ROW_NUMBER ROWS 
syntax keyword SqlFunc SAMPLES SATURDAY SETBIT SHIFTLEFT SHIFTRIGHT SIN SINH SKEW SOUNDEX SQLCODE
syntax keyword SqlFunc SQLERROR SQLEXCEPTION SQLSTATE SQRT STDEV STDEV_POP STDEV_SAMP STDEVP
syntax keyword SqlFunc STRING_CS SUBBITSTR SUBCLASS_ORIGIN SUBSTR SUBSTRING SUCCEEDS SUM SUNDAY 
syntax keyword SqlFunc TABLE_NAME TAN TANH TEMPORAL_DATE TEMPORAL_TIMESTAMP TESSELLATE
syntax keyword SqlFunc TESSELLATE_SEARCH THURSDAY TIMEZONE_HOUR TIMEZONE_MINUTE TITLE TO_BYTE
syntax keyword SqlFunc TRAILING TRANSACTION_ACTIVE TRANSLATE TRANSLATE_CHK TRIM TUESDAY 
syntax keyword SqlFunc UC UNBOUNDED UNTIL_CHANGED UNTIL_CLOSED UPPER UPPERCASE 
syntax keyword SqlFunc VAR_POP VAR_SAMP VARIANCE VARIANCEP 
syntax keyword SqlFunc WEDNESDAY WIDTH_BUCKET 
syntax keyword SqlFunc ZEROIFNULL 


syntax match SqlDataType "\<DOUBLE\s\+PRECISION\>"
syntax match SqlDataType "\<TO\s\+\(HOUR\|MINUTE\|MONTH\|SECOND\)\>"
syntax match SqlDataType "\<WITH\s\+TIMEZONE\>"
syntax match SqlDataType "\<LONG\s\+\(VARCHAR\|VARGRAPHIC\)\>"
syntax match SqlDataType "\<BINARY\s\+LARGE\s\+OBJECT\>"
syntax match SqlDataType "\<CHAR\(ACTER\)\?\(\s\+VARYING\)\?\>"
syntax match SqlDataType "\<CHARACTER\s\+LARGE\s\+OBJECT\>"
syntax match SqlDataType "\<TIME\(STAMP\)\?\>"

syntax keyword SqlDataType2 BIGINT BLOB BYTE BYTEINT 
syntax keyword SqlDataType2 CLOB 
syntax keyword SqlDataType2 DATE DAY DEC DECIMAL 
syntax keyword SqlDataType2 FLOAT 
syntax keyword SqlDataType2 GRAPHIC 
syntax keyword SqlDataType2 HOUR
syntax keyword SqlDataType2 INT INTEGER INTERVAL
syntax keyword SqlDataType2 MBR MINUTE MONTH 
syntax keyword SqlDataType2 NUMERIC 
syntax keyword SqlDataType2 PERIOD 
syntax keyword SqlDataType2 REAL 
syntax keyword SqlDataType2 SECOND SMALLINT 
syntax keyword SqlDataType2 VARBYTE VARCHAR VARGRAPHIC 
syntax keyword SqlDataType2 YEAR

syntax match SqlCmd "\<CHARACTER\s\+SET\>" 
syntax match SqlCmd "\<EXTERNAL\s\+NAME\>"
syntax match SqlCmd "\<WITH\>\(\s*TIMEZONE\)\@!"

syntax keyword SqlCmd2 _GRAPHIC _KANJISJIS _LATIN1 _UNICODE 
syntax keyword SqlCmd2 ABORT ABORTSESSION ACCESS ACCESS_LOCK ACCOUNT ADD ADMIN AFTER AGGREGATE ALL
syntax keyword SqlCmd2 ALTER AMP ANALYSIS ANCHOR AND ANSIDATE ANY ARGLPAREN AS ASC ASSIGNMENT AT
syntax keyword SqlCmd2 ATOMIC ATTR ATTRIBUTES AUTHORIZATION 
syntax keyword SqlCmd2 BEFORE BEGIN BETWEEN BT BUT BY BYTES 
syntax keyword SqlCmd2 CALL CALLED CASE CASESPECIFIC CAST CD CHARACTERISTICS CHECK CHECKPOINT CHECKSUM CLASS CLOSE
syntax keyword SqlCmd2 CLUSTER CM COLLATION COLLECT COLUMN COLUMNS COMMENT COMMIT COMPILE CONDITION
syntax keyword SqlCmd2 CONNECT CONSTRAINT CONSTRUCTOR CONSUME CONTINUE CONVERT_TABLE_HEADER CPUTIME
syntax keyword SqlCmd2 CREATE CROSS CT CTCONTROL CUBE CURRENT CURSOR CV CYCLE 
syntax keyword SqlCmd2 DATA DATABASE DATABLOCKSIZE DATEFORM DEBUG DECLARE DEFAULT DEFERRED DEFINER
syntax keyword SqlCmd2 DEMOGRAPHICS DENIALS DESC DESCRIBE DETERMINISTIC DIAGNOSTIC
syntax keyword SqlCmd2 DIAGNOSTICS DIGITS DISABLED DISTINCT DO DOMAIN DOWN DROP DUAL DUMP DYNAMIC 
syntax keyword SqlCmd2 EACH ECHO ELSE ELSEIF ENABLED END EQUALS ERROR ERRORFILES ERRORS ERRORTABLES
syntax keyword SqlCmd2 ESCAPE ET EXCEPT EXCEPTION EXCL EXCLUSIVE EXEC EXECUTE EXISTS EXIT EXPAND
syntax keyword SqlCmd2 EXPANDING EXPIRE EXPLAIN EXPORT EXTERNAL 
syntax keyword SqlCmd2 FALLBACK FASTEXPORT FETCH FINAL FIRST FOR FOREIGN FOUND FREESPACE 
syntax keyword SqlCmd2 FUNCTION 
syntax keyword SqlCmd2 GENERATED GET GIVE GLOBAL GLOP GRANT GROUP GROUPING 
syntax keyword SqlCmd2 HANDLER HASH HAVING HELP HELPSTATS HIGH 
syntax keyword SqlCmd2 IDENTITY IF IFP IMMEDIATE IN INCONSISTENT INDEX INITIATE INOUT INPUT 
syntax keyword SqlCmd2 INSTANCE INSTANTIABLE INSTEAD INTEGERDATE INTERSECT INVOKER
syntax keyword SqlCmd2 IOCOUNT IS ISOLATION ITERATE 
syntax keyword SqlCmd2 JAR JAVA JOURNAL 
syntax keyword SqlCmd2 KANJI1 KANJISJIS KBYTES KEEP KEY KILOBYTES 
syntax keyword SqlCmd2 LANGUAGE LAST LATIN LEAVE LENGTH LEVEL LIKE LIMIT LOADING LOCAL
syntax keyword SqlCmd2 LOCATOR LOCK LOCKEDUSEREXPIRE LOCKING LOGGING LOGON LOOP LOW 
syntax keyword SqlCmd2 MACRO MAP MATCHED MAXCHAR MAXIMUM MAXLOGONATTEMPTS MEDIUM MEMBER 
syntax keyword SqlCmd2 MERGEBLOCKRATIO METHOD MINCHAR MINIMUM MINUS MLOAD MODE MODIFIED MODIFIES
syntax keyword SqlCmd2 MODIFY MONITOR MONRESOURCE MONSESSION MULTISET 
syntax keyword SqlCmd2 NATURAL NEW NEW_TABLE NEXT NO NODDLTEXT NONE NONSEQUENCED NONTEMPORAL
syntax keyword SqlCmd2 NORMALIZE NOT NOWAIT NULL 
syntax keyword SqlCmd2 OBJECTS OF OLD OLD_NEW_TABLE OLD_TABLE ON ONLY OPEN OPERATOR OPTION OR
syntax keyword SqlCmd2 ORDER ORDERING OUT OVERRIDE 
syntax keyword SqlCmd2 PARAMETER PARTITION PARTITIONED PASSWORD PERCENT PERM PERMANENT PREPARE
syntax keyword SqlCmd2 PRESERVE PRIMARY PRINT PRIVILEGES PROCEDURE PROFILE PROTECTED PROTECTION
syntax keyword SqlCmd2 PUBLIC 
syntax keyword SqlCmd2 QUALIFIED QUALIFY QUERY QUERY_BAND QUEUE 
syntax keyword SqlCmd2 RANGE READ READS RECURSIVE REFERENCES REFERENCING RELATIVE RELEASE RENAME
syntax keyword SqlCmd2 REPEAT REPLACE REPLCONTROL REPLICATION REQUEST RESET RESIGNAL RESTART RESTORE
syntax keyword SqlCmd2 RESTRICT RESTRICTWORDS RESULT RESUME RET RETRIEVE RETURN RETURNS REUSE
syntax keyword SqlCmd2 REVALIDATE REVOKE RIGHTS ROLE ROLLBACK ROLLFORWARD ROLLUP ROW ROWID
syntax keyword SqlCmd2 RULES RULESET 
syntax keyword SqlCmd2 SAMPLE SAMPLEID SCROLL SECURITY SELF SEQUENCED SERIALIZABLE SESSION
syntax keyword SqlCmd2 SET SETRESRATE SETS SETSESSRATE SHARE SHOW SIGNAL SIZE SOME SOURCE SPECCHAR
syntax keyword SqlCmd2 SPECIFIC SPL SPOOL SQL SQLTEXT SQLWARNING SS START STARTUP STAT STATEMENT
syntax keyword SqlCmd2 STATISTICS STATS STEPINFO STYLE SUBSCRIBER SUMMARY SUSPEND SYSTEM 
syntax keyword SqlCmd2 TABLE TARGET TBL_CS TD_GENERAL TEMPORARY TERMINATE TEXT THEN THRESHOLD THROUGH
syntax keyword SqlCmd2 TIES TOP TRACE TRANSACTION TRANSACTIONTIME TRANSFORM TRIGGER TYPE 
syntax keyword SqlCmd2 UDTCASTAS UDTCASTLPAREN UDTMETHOD UDTTYPE UDTUSAGE UESCAPE UNCOMMITTED
syntax keyword SqlCmd2 UNDEFINED UNDO UNICODE UNION UNIQUE UNKNOWN UNTIL USE USER USING 
syntax keyword SqlCmd2 VALIDTIME VALUE VALUES VARIANT_TYPE VIEW VOLATILE 
syntax keyword SqlCmd2 WARNING WHEN WHILE WORK WORKLOAD WRITE 
syntax keyword SqlCmd2 XML XMLPLAN 
syntax keyword SqlCmd2 ZONE 

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

highlight link SqlComment Comment
highlight link SqlString String
highlight link SqlNumber Number
" highlight link SqlStmtDelim Special
highlight link SqlConnector Special
highlight link SqlCmd Statement
highlight link SqlCmd2  Statement
highlight link SqlFunc Function
highlight link SqlDataType Type
highlight link SqlDataType2 Type
highlight link SqlOperator Operator
highlight link BteqCmd Special
highlight link BteqCmd2 Special
highlight link BteqKW Special

let b:current_syntax = "teradata"
