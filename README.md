# vim-teradata
vim-teradata is a vim plugin to interact directly with the Teradata database and provide different functions.
* Check query syntax (support checking of multiple queries)
* Output a sample of a select queries
* Research list of tables based on a pattern
* Return a list of column name fields of a table

## Usage
The command starts always with TD and can take various option :
 * syntax (default)
 * explain
 * table
 * field
 * sample
 * output

Default command TDO to run and output the result in a split buffer (dependency with ![csv plugin](https://github.com/chrisbra/csv.vim) with @ as a delimiter)

Default command TDH to populate a quickfix list with the latest queries and resultsets


## Configuration
In plugin/teradata.vim, some variables need to be instantiated :
* log_mech : TD2,ldap etc...
* td_user : username of the user to connect to the db (pwd in tdwallet)
* td_tdpid : hostname or ip address of the TD machine
* td_script : path and filename of the temp BTEQ file
* td_out : path and filename of the output file generated by BTEQ
* td_log : path and filename of the log generated by BTEQ
* td_queries : folder path to save executed queries
* td_resultsets : folder path to save query result
* td_replace (optional) : list of variable that will be replaced at execution time

## Plugin demo
![plugin demo](https://imgur.com/BPrDc3t.gif)

## TODO
* Syntax SQL inside BTEQ from shell script
* Create BTEQ, SQL, SH+BTEQ,T PT snippet

## Thanks
* Initial syntax from ![this repo](https://github.com/vim-scripts/Teradata-13.10-syntax/blob/master/syntax/teradata_13_10.vim)
