# vim-teradata
vim-teradata is a vim plugin to interact directly with the Teradata database and provide different functions.
* Check query syntax (support checking of multiple queries)
* Output a sample of a select queries
* Keep your queries history and the associated resultsets

## Usage
The command starts always with TD:

Default command TD to check the query syntax

Default command TDO to run and output the result in a split buffer (dependency with [csv plugin](https://github.com/chrisbra/csv.vim) with @ as a delimiter)

Default command TDH to populate a buffer with the latest queries and resultsets (no external dependency)

Default command TDU to access the users management buffer

Default command TDB to access the bookmark management buffer

Default command TDBAdd to add the visually selected query to the bookmark list

Default command TDR to search for past queries (3 dependencies : [fzf.vim](https://github.com/junegunn/fzf.vim), [bat](https://github.com/sharkdp/bat) and [rg](https://github.com/BurntSushi/ripgrep))

Use `TDHelp` command to get the help

## Configuration
In lua/teradata/config.lua, some variables need to be instantiated :
* log_mech : TD2,ldap etc...
* user : username of the user to connect to the db (pwd in tdwallet)
* tdpid : hostname or ip address of the TD machine
* td_replace (optional) : list of variable that will be replaced at execution time

## Plugin demo
![plugin demo](https://imgur.com/BPrDc3t.gif)

## TODO
* Syntax SQL inside BTEQ from shell script
* Create BTEQ, SQL, SH+BTEQ,T PT snippet

## Thanks
* Initial syntax from [this repo](https://github.com/vim-scripts/Teradata-13.10-syntax/blob/master/syntax/teradata_13_10.vim)
