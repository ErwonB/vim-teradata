create multiset table ${DB_VAR}.TABLE1
(
    ENT_ID           integer not null
  , MAIL_TO_RECIEVER varchar(250) null
  , MAIL_CC_RECIEVER varchar(250) null
  , CONTACT_NAME     varchar(250) null
  , PHONE_NUMBER     varchar(250) null
  , BEGIN_TT         timestamp(6) with time zone not null
  , END_TT           timestamp(6) with time zone not null
  , period for PERIOD_TT(BEGIN_TT, END_TT ) as transactiontime
  , constraint PRIMARY_1 primary key (COLUMN_1, COLUMN_2)
  , constraint UNIQUE_1 current transactiontime unique (COLUMN_3, COLUMN_4)
  , constraint CHECK_1 check (COLUMN_3 > 0
     or COLUMN_4 is not NULL )
  , constraint REF_1 foreign key (COLUMN_5, COLUMN_6) references PARENT_1(COLUMN_2, COLUMN_3 )
  , constraint U_REF_MAIL current transactiontime unique (ENT_ID)
)
primary index(ENT_ID)
partition by
   (
   case_n(END_TT = TIMESTAMP '9999-12-31 23:59:59.999999+00:00', NO CASE)
   )
; 

create multiset table XXXX.YYYY
(
    ENT_ID           integer not null
  , MAIL_TO_RECIEVER varchar(250) null
  , MAIL_CC_RECIEVER varchar(250) null
  , CONTACT_NAME     varchar(250) null
  , PHONE_NUMBER     varchar(250) null
  , BEGIN_TT         timestamp(6) with time zone not null
  , END_TT           timestamp(6) with time zone not null
  , period for PERIOD_TT(BEGIN_TT, END_TT ) as transactiontime
  , constraint PLOP current transactiontime check (ENT_ID > 0 )
)
primary index(ENT_ID)
partition by
   (
   case_n(END_TT = TIMESTAMP '9999-12-31 23:59:59.999999+00:00', NO CASE)
   )
;



merge into DB_RAND_1.TABLE_1_1 t 
using DB_RAND_1.TABLE_1_3 s 
   on (t.CUSTOMER = s.CUSTOMER)
   when matched then
   update set PURCHASES = s.PURCHASES + t.PURCHASES
    , PLOP = s.PLOP
   when not matched then
   insert
   (
       CUSTOMER
      , PURCHASES
      , ADDRESS
   )
   values
   (
       s.CUSTOMER
      , s.PURCHASES
      , s.ADDRESS
   );

lock table DB_RAND_1.TABLE_1_1 for access
lock table DB_RAND_1.TABLE_1_3 for access
select
*
from
DB_RAND_1.TABLE_1_1;


insert into DB1.TABLE1
(
   FILE_ID
  , FLOW_VERSION
  , STTM_DT
)
select
FILE_ID
, FLOW_VERSION
, STTM_DT
from
DB1.TABLE1
where PLOP = 50;

insert into DB1.TABLE1
(
   FILE_ID
  , FLOW_VERSION
  , STTM_DT
)
values
(
   10
  , 'plop'
  , date'2025-03-31'
);

create multiset table DB1.TABLE1
(
    FILE_ID       integer not null
  , FIELD8        varchar(10) character set LATIN not casespecific not null
  , FIELD24       varchar(20) character set LATIN not casespecific not null
  , FIELD21       varchar(30) character set LATIN not casespecific
  , FIELD16       varchar(128) character set LATIN not casespecific not null
  , FIELD14       integer
  , FIELD23       varchar(5) character set LATIN not casespecific
  , FIELD25       integer
  , FIELD27       date format 'YY/MM/DD'
  , FIELD11       byteint not null
  , FIELD13       char(1) character set LATIN not casespecific not null
  , FIELD19       byteint not null
  , FIELD18       timestamp(6) not null
  , FIELD17       timestamp(0)
  , FIELD23       varchar(30) character set LATIN not casespecific not null
  , FIELD21       integer
  , FIELD22       integer
  , FIELD21       varchar(30) character set LATIN not casespecific
  , FIELD21DSKLFS varchar(256) character set LATIN not casespecific
)
unique primary index(FILE_ID, FLOW_VERSION);                                           

lock row for access
select
TECHNICAL_NAME
, REAL_LENGTH
from
(
   select
   f.TECHNICAL_NAME
  , cast(case
     when FIELD_TYPE = 'DATE' then 8
     when trim(t.FIELD_TYPE) = 'STRING' then FIELD_LENGTH
     when trim(FIELD_TYPE) = 'DECIMAL'
     and instr(FIELD_LENGTH, ',') > 0 then strtok(FIELD_LENGTH, ',', 1)
     when trim(FIELD_TYPE) = 'DECIMAL'
     and instr(FIELD_LENGTH, '.') > 0 then strtok(FIELD_LENGTH, '.', 1)
     end as integer) as REAL_LENGTH
  , sum(REAL_LENGTH) over (partition by FLOW_TYPE_CD order by FIELD_POSITION rows unbounded preceding) as TOTAL_LENGTH
  , cast(TOTAL_LENGTH - REAL_LENGTH + 1 as integer) as STARTING_POSITION
   from
   DB2.TABLE22 f
   where f.FLOW_VERSION = 'V024'
   and f.LANG_CD = 'FR'
   and f.TYPE_LINE = 'D'
   and f.FLOW_TYPE_CD = 'P2'
   and f.TECHNICAL_NAME <> 'SYSINFOSOURCE'
) as z
full join
(
   select
   f.TECHNICAL_NAME
  , cast(case
     when FIELD_TYPE = 'DATE' then 8
     when trim(FIELD_TYPE) = 'STRING' then FIELD_LENGTH
     when trim(FIELD_TYPE) = 'DECIMAL'
     and instr(FIELD_LENGTH, ',') > 0 then strtok(FIELD_LENGTH, ',', 1)
     when trim(FIELD_TYPE) = 'DECIMAL'
     and instr(FIELD_LENGTH, '.') > 0 then strtok(FIELD_LENGTH, '.', 1)
     end as integer) as REAL_LENGTH
  , sum(REAL_LENGTH) over (partition by FLOW_TYPE_CD order by FIELD_POSITION rows unbounded preceding) as TOTAL_LENGTH
  , cast(TOTAL_LENGTH - REAL_LENGTH + 1 as integer) as STARTING_POSITION
   from
   DB3.TABLE23 f
   where FLOW_VERSION = 'V024'
   and LANG_CD = 'FR'
   and TYPE_LINE = 'D'
   and FLOW_TYPE_CD = 'P2'
   and TECHNICAL_NAME <> 'SYSINFOSOURCE'
) as m
on z.TECHNICAL_NAME = m.TECHNICAL_NAME
and z.PLOP = m.PLOP
group by 1, 2, 3, 4
order by z.STARTING_POSITION asc;


nontemporal
update TGT
from
   DB1.TABLE1 tgt,
   (
   nonsequenced transactiontime
   
   select
   FIELD1
  , FIELD2
  , FIELD3
  , FIELD4
   from
   DB1.TABLE2
   where FIELD4 is not null
   and FIELD1 is not null
   qualify row_number () over (partition by FIELD2 order by FIELD5 desc) = 1
) src
set FIELD4 = src.FIELD4
where tgt.FIELD1 = src.FIELD1
and tgt.FIELD4 is NULL;


update T
from
   DB1.TABLE1 t,
   DB2.TABLE2 s,
   DB3.TABLE3 dd
set FIELD1 = s.FIELD1
where s.FIELD2 = dd.FIELD2
and s.FIELD3 = t.FIELD3;

    update DB1.TABLE1
from
   (
   select
   FIELD1
  , FIELD2
  , FIELD3
   from
   DB2.TABLE2
) as f
set FIELD1 = f.FIELD1
  , FIELD4 = 1
where table1.FIELD2 = f.FIELD2
and table1.FIELD3 = f.FIELD3;

select
NAME
, DEPT
from
DEPT1
union all
select
NAME
, DEPT
from
DEPT2;


with CTE(E, B) as (
   select
   *
   from
   EMPLOYEE
   where DEPT_NO = 100
   and PLOP < 100
)
, CTE2(A, B, C) as (
   select
   *
   from
   PLOP
)
select
*
from
CTE;



create macro MY_MACRO (
    P1 integer
  , P2 varchar(50)
)
as (
   update EMPLOYEE
   set SALARY = SALARY * 1.1
   where EMP_NO = P1
   ;
   select
   *
   from
   IPP
);

replace view DB.VIEW1 as
locking row for access
select
FIELD1
, FIELD2
from
DB.TABLE1
;
:qa



