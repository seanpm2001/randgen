# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2020,2022 MariaDB Corporation
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

package GenTest::Executor::MariaDB;

require Exporter;

@ISA = qw(GenTest::Executor);

use strict;
use Carp;
use DBI;
use GenUtil;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Executor;
use Time::HiRes;
use Digest::MD5;
use GenTest::Random;

use constant RARE_QUERY_THRESHOLD    => 5;
use constant MAX_ROWS_THRESHOLD        => 7000000;

my %reported_errors;

my @errors = (
    "The target table .*? of the .*? is",
    "Duplicate entry '.*?' for key '.*?'",
    "Can't DROP '.*?'",
    "Duplicate key name '.*?'",
    "Duplicate column name '.*?'",
    "Record has changed since last read in table '.*?'",
    "savepoint does not exist",
    "'.*?' doesn't exist",
    " .*? does not exist",
    "'.*?' already exists",
    "Unknown database '.*?'",
    "Unknown table '.*?'",
    "Unknown column '.*?'",
    "Unknown event '.*?'",
    "Column '.*?' specified twice",
    "Column '.*?' cannot be null",
    "Column '.*?' in .*? clause is ambiguous",
    "Duplicate partition name .*?",
    "Tablespace '.*?' not empty",
    "Tablespace '.*?' already exists",
    "Tablespace data file '.*?' already exists",
    "Can't find file: '.*?'",
    "Table '.*?' already exists",
    "You can't specify target table '.*?' for update",
    "Illegal mix of collations .*?, .*?, .*? for operation '.*?'",
    "Illegal mix of collations .*? and .*? for operation '.*?'",
    "Invalid .*? character string: '.*?'",
    "This version of MySQL doesn't yet support '.*?'",
    "PROCEDURE .*? already exists",
    "FUNCTION .*? already exists",
    "'.*?' isn't in GROUP BY",
    "non-grouping field '.*?' is used in HAVING clause",
    "Table has no partition for value .*?",
    "Unknown prepared statement handler (.*?) given to EXECUTE",
    "Unknown prepared statement handler (.*?) given to DEALLOCATE PREPARE",
    "Can't execute the query because you have a conflicting read lock",
    "Can't execute the given command because you have active locked tables or an active transaction",
    "Not unique table/alias: '.*?'",
    "View .* references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them",
    "Unknown thread id: .*?" ,
    "Unknown table '.*?' in .*?",
    "Table '.*?' is read only",
    "Duplicate condition: .*?",
    "Duplicate condition information item '.*?'",
    "Undefined CONDITION: .*?",
    "Incorrect .*? value '.*?'",
    "Recursive limit \\d+ (as set by the max_sp_recursion_depth variable) was exceeded for routine .*?",
        "There is no such grant defined for user '.*?' on host '.*?' on table '.*?'",
    "There is no such grant defined for user '.*?' on host '.*?'",
    "'.*?' is not a .*?",
    "Incorrect usage of .*? and .*?",
    "Can't reopen table: '.*?'",
    "Trigger's '.*?' is view or temporary table",
    "Column '.*?' is not updatable"
);

my @patterns = map { qr{$_}i } @errors;

use constant EXECUTOR_MYSQL_AUTOCOMMIT => 101;
use constant EXECUTOR_MYSQL_SERVER_VARIABLES => 102;

#
# Column positions for SHOW SLAVES
#

use constant SLAVE_INFO_HOST => 1;
use constant SLAVE_INFO_PORT => 2;

#
# Error codes
#

use constant  ER_OUTOFMEMORY2                                   => 5; # returned by some storage engines
use constant  ER_CRASHED1                                       => 126; # Index is corrupted
use constant  ER_CRASHED2                                       => 145; # Table was marked as crashed and should be repaired
use constant  HA_ERR_TABLE_DEF_CHANGED                          => 159; # The table changed in the storage engine
use constant  ER_AUTOINCREMENT                                  => 167; # Failed to set row auto increment value
use constant  ER_INCOMPATIBLE_FRM                               => 190; # Incompatible key or row definition between the MariaDB .frm file and the information in the storage engine

use constant  ER_NISAMCHK                                       => 1001; # !!! NOT MAPPED !!! # isamchk
use constant  ER_NO                                             => 1002; # !!! NOT MAPPED !!! # NO
use constant  ER_YES                                            => 1003; # !!! NOT MAPPED !!! # YES
use constant  ER_CANT_CREATE_FILE                               => 1004; # Can't create file '%-.200s' (errno: %M)
use constant  ER_CANT_CREATE_TABLE                              => 1005; # Can't create table %`s.%`s (errno: %M)
use constant  ER_CANT_CREATE_DB                                 => 1006; # Can't create database '%-.192s' (errno: %M)
use constant  ER_DB_CREATE_EXISTS                               => 1007; # Can't create database '%-.192s'; database exists
use constant  ER_DB_DROP_EXISTS                                 => 1008; # Can't drop database '%-.192s'; database doesn't exist
use constant  ER_DB_DROP_DELETE                                 => 1009; # Error dropping database (can't delete '%-.192s', errno: %M)
use constant  ER_DB_DROP_RMDIR                                  => 1010; # Error dropping database (can't rmdir '%-.192s', errno: %M)
use constant  ER_CANT_DELETE_FILE                               => 1011; # Error on delete of '%-.192s' (errno: %M)
use constant  ER_CANT_FIND_SYSTEM_REC                           => 1012; # Can't read record in system table
use constant  ER_CANT_GET_STAT                                  => 1013; # Can't get status of '%-.200s' (errno: %M)
use constant  ER_CANT_GET_WD                                    => 1014; # Can't get working directory (errno: %M)
use constant  ER_CANT_LOCK                                      => 1015; # Can't lock file (errno: %M)
use constant  ER_CANT_OPEN_FILE                                 => 1016; # Can't open file: '%-.200s' (errno: %M)
use constant  ER_FILE_NOT_FOUND                                 => 1017; # Can't find file: '%-.200s' (errno: %M)
use constant  ER_CANT_READ_DIR                                  => 1018; # Can't read dir of '%-.192s' (errno: %M)
use constant  ER_CANT_SET_WD                                    => 1019; # Can't change dir to '%-.192s' (errno: %M)
use constant  ER_CHECKREAD                                      => 1020; # Record has changed since last read in table '%-.192s'
use constant  ER_DISK_FULL                                      => 1021; # Disk full (%s); waiting for someone to free some space... (errno: %M)
use constant  ER_DUP_KEY                                        => 1022; # Can't write; duplicate key in table '%-.192s'
use constant  ER_ERROR_ON_CLOSE                                 => 1023; # Error on close of '%-.192s' (errno: %M)
use constant  ER_ERROR_ON_READ                                  => 1024; # Error reading file '%-.200s' (errno: %M)
use constant  ER_ERROR_ON_RENAME                                => 1025; # Error on rename of '%-.210s' to '%-.210s' (errno: %M)
use constant  ER_ERROR_ON_WRITE                                 => 1026; # Error writing file '%-.200s' (errno: %M)
use constant  ER_FILE_USED                                      => 1027; # '%-.192s' is locked against change
use constant  ER_FILSORT_ABORT                                  => 1028; # Sort aborted
use constant  ER_FORM_NOT_FOUND                                 => 1029; # View '%-.192s' doesn't exist for '%-.192s'
use constant  ER_GET_ERRNO                                      => 1030; # Got error %M from storage engine %s
use constant  ER_ILLEGAL_HA                                     => 1031; # Storage engine %s of the table %`s.%`s doesn't have this option
use constant  ER_KEY_NOT_FOUND                                  => 1032; # Can't find record in '%-.192s'
use constant  ER_NOT_FORM_FILE                                  => 1033; # Incorrect information in file: '%-.200s'
use constant  ER_NOT_KEYFILE                                    => 1034; # Index for table '%-.200s' is corrupt; try to repair it
use constant  ER_OLD_KEYFILE                                    => 1035; # !!! NOT MAPPED !!! # Old key file for table '%-.192s'; repair it!
use constant  ER_OPEN_AS_READONLY                               => 1036; # Table '%-.192s' is read only
use constant  ER_OUTOFMEMORY                                    => 1037; # Out of memory; restart server and try again (needed %d bytes)
use constant  ER_OUT_OF_SORTMEMORY                              => 1038; # Out of sort memory, consider increasing server sort buffer size
use constant  ER_UNEXPECTED_EOF                                 => 1039; # Unexpected EOF found when reading file '%-.192s' (errno: %M)
use constant  ER_CON_COUNT_ERROR                                => 1040; # Too many connections
use constant  ER_OUT_OF_RESOURCES                               => 1041; # Out of memory.
use constant  ER_BAD_HOST_ERROR                                 => 1042; # Can't get hostname for your address
use constant  ER_HANDSHAKE_ERROR                                => 1043; # Bad handshake
use constant  ER_DBACCESS_DENIED_ERROR                          => 1044; # Access denied for user '%s'@'%s' to database '%-.192s'
use constant  ER_ACCESS_DENIED_ERROR                            => 1045; # Access denied for user '%s'@'%s' (using password: %s)
use constant  ER_NO_DB_ERROR                                    => 1046; # No database selected
use constant  ER_UNKNOWN_COM_ERROR                              => 1047; # Unknown command
use constant  ER_BAD_NULL_ERROR                                 => 1048; # Column '%-.192s' cannot be null
use constant  ER_BAD_DB_ERROR                                   => 1049; # Unknown database '%-.192s'
use constant  ER_TABLE_EXISTS_ERROR                             => 1050; # Table '%-.192s' already exists
use constant  ER_BAD_TABLE_ERROR                                => 1051; # Unknown table '%-.100T'
use constant  ER_NON_UNIQ_ERROR                                 => 1052; # Column '%-.192s' in %-.192s is ambiguous
use constant  ER_SERVER_SHUTDOWN                                => 1053; # Server shutdown in progress
use constant  ER_BAD_FIELD_ERROR                                => 1054; # Unknown column '%-.192s' in '%-.192s'
use constant  ER_WRONG_FIELD_WITH_GROUP                         => 1055; # '%-.192s' isn't in GROUP BY
use constant  ER_WRONG_GROUP_FIELD                              => 1056; # Can't group on '%-.192s'
use constant  ER_WRONG_SUM_SELECT                               => 1057; # Statement has sum functions and columns in same statement
use constant  ER_WRONG_VALUE_COUNT                              => 1058; # Column count doesn't match value count
use constant  ER_TOO_LONG_IDENT                                 => 1059; # Identifier name '%-.100T' is too long
use constant  ER_DUP_FIELDNAME                                  => 1060; # Duplicate column name '%-.192s'
use constant  ER_DUP_KEYNAME                                    => 1061; # Duplicate key name '%-.192s'
use constant  ER_DUP_ENTRY                                      => 1062; # Duplicate entry '%-.192T' for key %d
use constant  ER_WRONG_FIELD_SPEC                               => 1063; # Incorrect column specifier for column '%-.192s'
use constant  ER_PARSE_ERROR                                    => 1064; # %s near '%-.80T' at line %d
use constant  ER_EMPTY_QUERY                                    => 1065; # Query was empty
use constant  ER_NONUNIQ_TABLE                                  => 1066; # Not unique table/alias: '%-.192s'
use constant  ER_INVALID_DEFAULT                                => 1067; # Invalid default value for '%-.192s'
use constant  ER_MULTIPLE_PRI_KEY                               => 1068; # Multiple primary key defined
use constant  ER_TOO_MANY_KEYS                                  => 1069; # Too many keys specified; max %d keys allowed
use constant  ER_TOO_MANY_KEY_PARTS                             => 1070; # Too many key parts specified; max %d parts allowed
use constant  ER_TOO_LONG_KEY                                   => 1071; # Specified key was too long; max key length is %d bytes
use constant  ER_KEY_COLUMN_DOES_NOT_EXIST                      => 1072; # Key column '%-.192s' doesn't exist in table
use constant  ER_BLOB_USED_AS_KEY                               => 1073; # BLOB column %`s can't be used in key specification in the %s table
use constant  ER_TOO_BIG_FIELDLENGTH                            => 1074; # Column length too big for column '%-.192s' (max = %lu); use BLOB or TEXT instead
use constant  ER_WRONG_AUTO_KEY                                 => 1075; # Incorrect table definition; there can be only one auto column and it must be defined as a key
use constant  ER_BINLOG_CANT_DELETE_GTID_DOMAIN                 => 1076; # Could not delete gtid domain. Reason: %s.
use constant  ER_NORMAL_SHUTDOWN                                => 1077; # %s (initiated by: %s): Normal shutdown
use constant  ER_GOT_SIGNAL                                     => 1078; # %s: Got signal %d. Aborting!
use constant  ER_SHUTDOWN_COMPLETE                              => 1079; # %s: Shutdown complete
use constant  ER_FORCING_CLOSE                                  => 1080; # %s: Forcing close of thread %ld  user: '%-.48s'
use constant  ER_IPSOCK_ERROR                                   => 1081; # Can't create IP socket
use constant  ER_NO_SUCH_INDEX                                  => 1082; # Table '%-.192s' has no index like the one used in CREATE INDEX; recreate the table
use constant  ER_WRONG_FIELD_TERMINATORS                        => 1083; # Field separator argument is not what is expected; check the manual
use constant  ER_BLOBS_AND_NO_TERMINATED                        => 1084; # You can't use fixed rowlength with BLOBs; please use 'fields terminated by'
use constant  ER_TEXTFILE_NOT_READABLE                          => 1085; # The file '%-.128s' must be in the database directory or be readable by all
use constant  ER_FILE_EXISTS_ERROR                              => 1086; # File '%-.200s' already exists
use constant  ER_LOAD_INFO                                      => 1087; # !!! NOT MAPPED ! # Records: %ld  Deleted: %ld  Skipped: %ld  Warnings: %ld
use constant  ER_ALTER_INFO                                     => 1088; # !!! NOT MAPPED ! # Records: %ld  Duplicates: %ld
use constant  ER_WRONG_SUB_KEY                                  => 1089; # Incorrect prefix key; the used key part isn't a string, the used length is longer <...>
use constant  ER_CANT_REMOVE_ALL_FIELDS                         => 1090; # You can't delete all columns with ALTER TABLE; use DROP TABLE instead
use constant  ER_CANT_DROP_FIELD_OR_KEY                         => 1091; # Can't DROP %s %`-.192s; check that it exists
use constant  ER_INSERT_INFO                                    => 1092; # !!! NOT MAPPED !!! # Records: %ld  Duplicates: %ld  Warnings: %ld
use constant  ER_UPDATE_TABLE_USED                              => 1093; # Table '%-.192s' is specified twice, both as a target for '%s' and as a separate source for data
use constant  ER_NO_SUCH_THREAD                                 => 1094; # Unknown thread id: %lu
use constant  ER_KILL_DENIED_ERROR                              => 1095; # You are not owner of thread %lld
use constant  ER_NO_TABLES_USED                                 => 1096; # No tables used
use constant  ER_TOO_BIG_SET                                    => 1097; # Too many strings for column %-.192s and SET
use constant  ER_NO_UNIQUE_LOGFILE                              => 1098; # Can't generate a unique log-filename %-.200s.(1-999)
use constant  ER_TABLE_NOT_LOCKED_FOR_WRITE                     => 1099; # Table '%-.192s' was locked with a READ lock and can't be updated
use constant  ER_TABLE_NOT_LOCKED                               => 1100; # Table '%-.192s' was not locked with LOCK TABLES
#             ER_UNUSED_17                                      => 1101; # You should never see it
use constant  ER_WRONG_DB_NAME                                  => 1102; # Incorrect database name '%-.100T'
use constant  ER_WRONG_TABLE_NAME                               => 1103; # Incorrect table name '%-.100s'
use constant  ER_TOO_BIG_SELECT                                 => 1104; # The SELECT would examine more than MAX_JOIN_SIZE rows <...>
use constant  ER_UNKNOWN_ERROR                                  => 1105; # Unknown error
use constant  ER_UNKNOWN_PROCEDURE                              => 1106; # Unknown procedure '%-.192s'
use constant  ER_WRONG_PARAMCOUNT_TO_PROCEDURE                  => 1107; # Incorrect parameter count to procedure '%-.192s'
use constant  ER_WRONG_PARAMETERS_TO_PROCEDURE                  => 1108; # Incorrect parameters to procedure '%-.192s'
use constant  ER_UNKNOWN_TABLE                                  => 1109; # Unknown table '%-.192s' in %-.32s
use constant  ER_FIELD_SPECIFIED_TWICE                          => 1110; # Column '%-.192s' specified twice
use constant  ER_INVALID_GROUP_FUNC_USE                         => 1111; # Invalid use of group function
use constant  ER_UNSUPPORTED_EXTENSION                          => 1112; # Table '%-.192s' uses an extension that doesn't exist in this MariaDB version
use constant  ER_TABLE_MUST_HAVE_COLUMNS                        => 1113; # A table must have at least 1 column
use constant  ER_RECORD_FILE_FULL                               => 1114; # The table '%-.192s' is full
use constant  ER_UNKNOWN_CHARACTER_SET                          => 1115; # Unknown character set: '%-.64s'
use constant  ER_TOO_MANY_TABLES                                => 1116; # Too many tables; MariaDB can only use %d tables in a join
use constant  ER_TOO_MANY_FIELDS                                => 1117; # Too many columns
use constant  ER_TOO_BIG_ROWSIZE                                => 1118; # Row size too large. The maximum row size for the used table type, <...>
use constant  ER_STACK_OVERRUN                                  => 1119; # Thread stack overrun:  Used: %ld of a %ld stack.  Use 'mariadbd --thread_stack=#' to specify a bigger stack if needed
use constant  ER_WRONG_OUTER_JOIN                               => 1120; # Cross dependency found in OUTER JOIN; examine your ON conditions
use constant  ER_NULL_COLUMN_IN_INDEX                           => 1121; # Table handler doesn't support NULL in given index <...>
use constant  ER_CANT_FIND_UDF                                  => 1122; # Can't load function '%-.192s'
use constant  ER_CANT_INITIALIZE_UDF                            => 1123; # Can't initialize function '%-.192s'; %-.80s
use constant  ER_UDF_NO_PATHS                                   => 1124; # No paths allowed for shared library
use constant  ER_UDF_EXISTS                                     => 1125; # Function '%-.192s' already exists
use constant  ER_CANT_OPEN_LIBRARY                              => 1126; # Can't open shared library '%-.192s' (errno: %d, %-.128s)
use constant  ER_CANT_FIND_DL_ENTRY                             => 1127; # Can't find symbol '%-.128s' in library
use constant  ER_FUNCTION_NOT_DEFINED                           => 1128; # Function '%-.192s' is not defined
use constant  ER_HOST_IS_BLOCKED                                => 1129; # Host '%-.64s' is blocked because of many connection errors; unblock with 'mariadb-adm<...>
use constant  ER_HOST_NOT_PRIVILEGED                            => 1130; # Host '%-.64s' is not allowed to connect to this MariaDB server
use constant  ER_PASSWORD_ANONYMOUS_USER                        => 1131; # You are using MariaDB as an anonymous user and anonymous users are not allowed to mod<...>
use constant  ER_PASSWORD_NOT_ALLOWED                           => 1132; # You must have privileges to update tables in the mysql database to be able to change <...>
use constant  ER_PASSWORD_NO_MATCH                              => 1133; # Can't find any matching row in the user table
use constant  ER_UPDATE_INFO                                    => 1134; # !!! NOT MAPPED !!! # Rows matched: %ld  Changed: %ld  Warnings: %ld
use constant  ER_CANT_CREATE_THREAD                             => 1135; # Can't create a new thread (errno %M); if you are not out of available memory, <...>
use constant  ER_WRONG_VALUE_COUNT_ON_ROW                       => 1136; # Column count doesn't match value count at row %lu
use constant  ER_CANT_REOPEN_TABLE                              => 1137; # Can't reopen table: '%-.192s'
use constant  ER_INVALID_USE_OF_NULL                            => 1138; # Invalid use of NULL value
use constant  ER_REGEXP_ERROR                                   => 1139; # Regex error '%s'
use constant  ER_MIX_OF_GROUP_FUNC_AND_FIELDS                   => 1140; # Mixing of GROUP columns <...> with no GROUP columns is illegal if there is no GROUP BY clause
use constant  ER_NONEXISTING_GRANT                              => 1141; # There is no such grant defined for user '%-.48s' on host '%-.64s'
use constant  ER_TABLEACCESS_DENIED_ERROR                       => 1142; # %-.100T command denied to user '%s'@'%s' for table '%-.192s'
use constant  ER_COLUMNACCESS_DENIED_ERROR                      => 1143; # %-.32s command denied to user '%s'@'%s' for column '%-.192s' in table '%-.192s'
use constant  ER_ILLEGAL_GRANT_FOR_TABLE                        => 1144; # Illegal GRANT/REVOKE command; please consult the manual to see which privileges can be used
use constant  ER_GRANT_WRONG_HOST_OR_USER                       => 1145; # The host or user argument to GRANT is too long
use constant  ER_NO_SUCH_TABLE                                  => 1146; # Table '%-.192s.%-.192s' doesn't exist
use constant  ER_NONEXISTING_TABLE_GRANT                        => 1147; # There is no such grant defined for user '%-.48s' on host '%-.64s' on table '%-.192s'
use constant  ER_NOT_ALLOWED_COMMAND                            => 1148; # The used command is not allowed with this MariaDB version
use constant  ER_SYNTAX_ERROR                                   => 1149; # You have an error in your SQL syntax
use constant  ER_DELAYED_CANT_CHANGE_LOCK                       => 1150; # Delayed insert thread couldn't get requested lock for table %-.192s
use constant  ER_TOO_MANY_DELAYED_THREADS                       => 1151; # Too many delayed threads in use
use constant  ER_ABORTING_CONNECTION                            => 1152; # Aborted connection %ld to db: '%-.192s' user: '%-.48s' (%-.64s)
use constant  ER_NET_PACKET_TOO_LARGE                           => 1153; # Got a packet bigger than 'max_allowed_packet' bytes
use constant  ER_NET_READ_ERROR_FROM_PIPE                       => 1154; # Got a read error from the connection pipe
use constant  ER_NET_FCNTL_ERROR                                => 1155; # Got an error from fcntl()
use constant  ER_NET_PACKETS_OUT_OF_ORDER                       => 1156; # Got packets out of order
use constant  ER_NET_UNCOMPRESS_ERROR                           => 1157; # Couldn't uncompress communication packet
use constant  ER_NET_READ_ERROR                                 => 1158; # Got an error reading communication packets
use constant  ER_NET_READ_INTERRUPTED                           => 1159; # Got timeout reading communication packets
use constant  ER_NET_ERROR_ON_WRITE                             => 1160; # Got an error writing communication packets
use constant  ER_NET_WRITE_INTERRUPTED                          => 1161; # Got timeout writing communication packets
use constant  ER_TOO_LONG_STRING                                => 1162; # Result string is longer than 'max_allowed_packet' bytes
use constant  ER_TABLE_CANT_HANDLE_BLOB                         => 1163; # Storage engine %s doesn't support BLOB/TEXT columns
use constant  ER_TABLE_CANT_HANDLE_AUTO_INCREMENT               => 1164; # Storage engine %s doesn't support AUTO_INCREMENT columns
use constant  ER_DELAYED_INSERT_TABLE_LOCKED                    => 1165; # INSERT DELAYED can't be used with table '%-.192s' because it is locked with LOCK TABLES
use constant  ER_WRONG_COLUMN_NAME                              => 1166; # Incorrect column name '%-.100s'
use constant  ER_WRONG_KEY_COLUMN                               => 1167; # The storage engine %s can't index column %`s
use constant  ER_WRONG_MRG_TABLE                                => 1168; # Unable to open underlying table which is differently defined or of non-MyISAM type or doesn't exist
use constant  ER_DUP_UNIQUE                                     => 1169; # Can't write, because of unique constraint, to table '%-.192s'
use constant  ER_BLOB_KEY_WITHOUT_LENGTH                        => 1170; # BLOB/TEXT column '%-.192s' used in key specification without a key length
use constant  ER_PRIMARY_CANT_HAVE_NULL                         => 1171; # All parts of a PRIMARY KEY must be NOT NULL; if you need NULL in a key, use UNIQUE instead
use constant  ER_TOO_MANY_ROWS                                  => 1172; # Result consisted of more than one row
use constant  ER_REQUIRES_PRIMARY_KEY                           => 1173; # This table type requires a primary key
use constant  ER_NO_RAID_COMPILED                               => 1174; # This version of MariaDB is not compiled with RAID support
use constant  ER_UPDATE_WITHOUT_KEY_IN_SAFE_MODE                => 1175; # You are using safe update mode and you tried to update a table without a WHERE that uses a KEY column
use constant  ER_KEY_DOES_NOT_EXITS                             => 1176; # Key '%-.192s' doesn't exist in table '%-.192s'
use constant  ER_CHECK_NO_SUCH_TABLE                            => 1177; # Can't open table
use constant  ER_CHECK_NOT_IMPLEMENTED                          => 1178; # The storage engine for the table doesn't support %s
use constant  ER_CANT_DO_THIS_DURING_AN_TRANSACTION             => 1179; # You are not allowed to execute this command in a transaction
use constant  ER_ERROR_DURING_COMMIT                            => 1180; # Got error %M during COMMIT
use constant  ER_ERROR_DURING_ROLLBACK                          => 1181; # Got error %M during ROLLBACK
use constant  ER_ERROR_DURING_FLUSH_LOGS                        => 1182; # Got error %M during FLUSH_LOGS
use constant  ER_ERROR_DURING_CHECKPOINT                        => 1183; # Got error %M during CHECKPOINT
use constant  ER_NEW_ABORTING_CONNECTION                        => 1184; # Aborted connection %lld to db: '%-.192s' user: '%-.48s' host: '%-.64s' (%-.64s)
#             ER_UNUSED_10                                      => 1185; # You should never see it
use constant  ER_FLUSH_MASTER_BINLOG_CLOSED                     => 1186; # Binlog closed, cannot RESET MASTER
use constant  ER_INDEX_REBUILD                                  => 1187; # Failed rebuilding the index of  dumped table '%-.192s'
use constant  ER_MASTER                                         => 1188; # Error from master: '%-.64s'
use constant  ER_MASTER_NET_READ                                => 1189; # Net error reading from master
use constant  ER_MASTER_NET_WRITE                               => 1190; # Net error writing to master
use constant  ER_FT_MATCHING_KEY_NOT_FOUND                      => 1191; # Can't find FULLTEXT index matching the column list
use constant  ER_LOCK_OR_ACTIVE_TRANSACTION                     => 1192; # Can't execute the given command because you have active locked tables or an active transaction
use constant  ER_UNKNOWN_SYSTEM_VARIABLE                        => 1193; # Unknown system variable '%-.*s'
use constant  ER_CRASHED_ON_USAGE                               => 1194; # Table '%-.192s' is marked as crashed and should be repaired
use constant  ER_CRASHED_ON_REPAIR                              => 1195; # Table '%-.192s' is marked as crashed and last (automatic?) repair failed
use constant  ER_WARNING_NOT_COMPLETE_ROLLBACK                  => 1196; # Some non-transactional changed tables couldn't be rolled back
use constant  ER_TRANS_CACHE_FULL                               => 1197; # Multi-statement transaction required more than 'max_binlog_cache_size' bytes of storage; increase this mariadbd variable and try again
use constant  ER_SLAVE_MUST_STOP                                => 1198; # This operation cannot be performed as you have a running slave '%2$*1$s'; run STOP SL<...>
use constant  ER_SLAVE_NOT_RUNNING                              => 1199; # This operation requires a running slave; configure slave and do START SLAVE
use constant  ER_BAD_SLAVE                                      => 1200; # The server is not configured as slave; fix in config file or with CHANGE MASTER TO
use constant  ER_MASTER_INFO                                    => 1201; # Could not initialize master info structure for '%.*s'; more error messages can be fou<...>
use constant  ER_SLAVE_THREAD                                   => 1202; # Could not create slave thread; check system resources
use constant  ER_TOO_MANY_USER_CONNECTIONS                      => 1203; # User %-.64s already has more than 'max_user_connections' active connections
use constant  ER_SET_CONSTANTS_ONLY                             => 1204; # You may only use constant expressions in this statement
use constant  ER_LOCK_WAIT_TIMEOUT                              => 1205; # Lock wait timeout exceeded; try restarting transaction
use constant  ER_LOCK_TABLE_FULL                                => 1206; # The total number of locks exceeds the lock table size
use constant  ER_READ_ONLY_TRANSACTION                          => 1207; # Update locks cannot be acquired during a READ UNCOMMITTED transaction
use constant  ER_DROP_DB_WITH_READ_LOCK                         => 1208; # DROP DATABASE not allowed while thread is holding global read lock
use constant  ER_CREATE_DB_WITH_READ_LOCK                       => 1209; # CREATE DATABASE not allowed while thread is holding global read lock
use constant  ER_WRONG_ARGUMENTS                                => 1210; # Incorrect arguments to %s
use constant  ER_NO_PERMISSION_TO_CREATE_USER                   => 1211; # '%s'@'%s' is not allowed to create new users
use constant  ER_UNION_TABLES_IN_DIFFERENT_DIR                  => 1212; # Incorrect table definition; all MERGE tables must be in the same database
use constant  ER_LOCK_DEADLOCK                                  => 1213; # Deadlock found when trying to get lock; try restarting transaction
use constant  ER_TABLE_CANT_HANDLE_FT                           => 1214; # The storage engine %s doesn't support FULLTEXT indexes
use constant  ER_CANNOT_ADD_FOREIGN                             => 1215; # Cannot add foreign key constraint for `%s`
use constant  ER_NO_REFERENCED_ROW                              => 1216; # Cannot add or update a child row: a foreign key constraint fails
use constant  ER_ROW_IS_REFERENCED                              => 1217; # Cannot delete or update a parent row: a foreign key constraint fails
use constant  ER_CONNECT_TO_MASTER                              => 1218; # Error connecting to master: %-.128s
use constant  ER_QUERY_ON_MASTER                                => 1219; # Error running query on master: %-.128s
use constant  ER_ERROR_WHEN_EXECUTING_COMMAND                   => 1220; # Error when executing command %s: %-.128s
use constant  ER_WRONG_USAGE                                    => 1221; # Incorrect usage of %s and %s
use constant  ER_WRONG_NUMBER_OF_COLUMNS_IN_SELECT              => 1222; # The used SELECT statements have a different number of columns
use constant  ER_CANT_UPDATE_WITH_READLOCK                      => 1223; # Can't execute the query because you have a conflicting read lock
use constant  ER_MIXING_NOT_ALLOWED                             => 1224; # Mixing of transactional and non-transactional tables is disabled
use constant  ER_DUP_ARGUMENT                                   => 1225; # Option '%s' used twice in statement
use constant  ER_USER_LIMIT_REACHED                             => 1226; # User '%-.64s' has exceeded the '%s' resource (current value: %ld)
use constant  ER_SPECIFIC_ACCESS_DENIED_ERROR                   => 1227; # Access denied; you need (at least one of) the %-.128s privilege(s) for this operation
use constant  ER_LOCAL_VARIABLE                                 => 1228; # Variable '%-.64s' is a SESSION variable and can't be used with SET GLOBAL
use constant  ER_GLOBAL_VARIABLE                                => 1229; # Variable '%-.64s' is a GLOBAL variable and should be set with SET GLOBAL
use constant  ER_NO_DEFAULT                                     => 1230; # Variable '%-.64s' doesn't have a default value
use constant  ER_WRONG_VALUE_FOR_VAR                            => 1231; # Variable '%-.64s' can't be set to the value of '%-.200T'
use constant  ER_WRONG_TYPE_FOR_VAR                             => 1232; # Incorrect argument type to variable '%-.64s'
use constant  ER_VAR_CANT_BE_READ                               => 1233; # Variable '%-.64s' can only be set, not read
use constant  ER_CANT_USE_OPTION_HERE                           => 1234; # Incorrect usage/placement of '%s'
use constant  ER_NOT_SUPPORTED_YET                              => 1235; # This version of MariaDB doesn't yet support '%s'
use constant  ER_MASTER_FATAL_ERROR_READING_BINLOG              => 1236; # Got fatal error %d from master when reading data from binary log: '%-.320s'
use constant  ER_SLAVE_IGNORED_TABLE                            => 1237; # Slave SQL thread ignored the query because of replicate-*-table rules
use constant  ER_INCORRECT_GLOBAL_LOCAL_VAR                     => 1238; # Variable '%-.192s' is a %s variable
use constant  ER_WRONG_FK_DEF                                   => 1239; # Incorrect foreign key definition for '%-.192s': %s
use constant  ER_KEY_REF_DO_NOT_MATCH_TABLE_REF                 => 1240; # Key reference and table reference don't match
use constant  ER_OPERAND_COLUMNS                                => 1241; # Operand should contain %d column(s)
use constant  ER_SUBQUERY_NO_1_ROW                              => 1242; # Subquery returns more than 1 row
use constant  ER_UNKNOWN_STMT_HANDLER                           => 1243; # Unknown prepared statement handler (%.*s) given to %s
use constant  ER_CORRUPT_HELP_DB                                => 1244; # Help database is corrupt or does not exist
use constant  ER_CYCLIC_REFERENCE                               => 1245; # Cyclic reference on subqueries
use constant  ER_AUTO_CONVERT                                   => 1246; # !!! NOT MAPPED !!! # Converting column '%s' from %s to %s
use constant  ER_ILLEGAL_REFERENCE                              => 1247; # Reference '%-.64s' not supported (%s)
use constant  ER_DERIVED_MUST_HAVE_ALIAS                        => 1248; # Every derived table must have its own alias
use constant  ER_SELECT_REDUCED                                 => 1249; # !!! NOT MAPPED !!! Select %u was reduced during optimization
use constant  ER_TABLENAME_NOT_ALLOWED_HERE                     => 1250; # Table '%-.192s' from one of the SELECTs cannot be used in %-.32s
use constant  ER_NOT_SUPPORTED_AUTH_MODE                        => 1251; # Client does not support authentication protocol requested by server; consider upgradi<...>
use constant  ER_SPATIAL_CANT_HAVE_NULL                         => 1252; # All parts of a SPATIAL index must be NOT NULL
use constant  ER_COLLATION_CHARSET_MISMATCH                     => 1253; # COLLATION '%s' is not valid for CHARACTER SET '%s'
use constant  ER_SLAVE_WAS_RUNNING                              => 1254; # Slave is already running
use constant  ER_SLAVE_WAS_NOT_RUNNING                          => 1255; # Slave already has been stopped
use constant  ER_TOO_BIG_FOR_UNCOMPRESS                         => 1256; # Uncompressed data size too large; the maximum size is %d (probably, length of uncompr<...>
use constant  ER_ZLIB_Z_MEM_ERROR                               => 1257; # ZLIB: Not enough memory
use constant  ER_ZLIB_Z_BUF_ERROR                               => 1258; # ZLIB: Not enough room in the output buffer (probably, length of uncompressed data was<...>
use constant  ER_ZLIB_Z_DATA_ERROR                              => 1259; # ZLIB: Input data corrupted
use constant  ER_CUT_VALUE_GROUP_CONCAT                         => 1260; # Row %u was cut by %s)
use constant  ER_WARN_TOO_FEW_RECORDS                           => 1261; # Row %lu doesn't contain data for all columns
use constant  ER_WARN_TOO_MANY_RECORDS                          => 1262; # Row %lu was truncated; it contained more data than there were input columns
use constant  ER_WARN_NULL_TO_NOTNULL                           => 1263; # Column set to default value; NULL supplied to NOT NULL column '%s' at row %lu
use constant  ER_WARN_DATA_OUT_OF_RANGE                         => 1264; # Out of range value for column '%s' at row %lu
use constant  WARN_DATA_TRUNCATED                               => 1265; # Data truncated for column '%s' at row %lu
use constant  ER_WARN_USING_OTHER_HANDLER                       => 1266; # Using storage engine %s for table '%s'
use constant  ER_CANT_AGGREGATE_2COLLATIONS                     => 1267; # Illegal mix of collations (%s,%s) and (%s,%s) for operation '%s'
use constant  ER_DROP_USER                                      => 1268; # Cannot drop one or more of the requested users
use constant  ER_REVOKE_GRANTS                                  => 1269; # Can't revoke all privileges for one or more of the requested users
use constant  ER_CANT_AGGREGATE_3COLLATIONS                     => 1270; # Illegal mix of collations (%s,%s), (%s,%s), (%s,%s) for operation '%s'
use constant  ER_CANT_AGGREGATE_NCOLLATIONS                     => 1271; # Illegal mix of collations for operation '%s'
use constant  ER_VARIABLE_IS_NOT_STRUCT                         => 1272; # Variable '%-.64s' is not a variable component (can't be used as XXXX.variable_name)
use constant  ER_UNKNOWN_COLLATION                              => 1273; # Unknown collation: '%-.64s'
use constant  ER_SLAVE_IGNORED_SSL_PARAMS                       => 1274; # SSL parameters in CHANGE MASTER are ignored because this MariaDB slave was compiled w<...>
use constant  ER_SERVER_IS_IN_SECURE_AUTH_MODE                  => 1275; # Server is running in --secure-auth mode, but '%s'@'%s' has a password in the old form<...>
use constant  ER_WARN_FIELD_RESOLVED                            => 1276; # !!! NOT MAPPED !!! # Field or reference '%-.192s%s%-.192s%s%-.192s' of SELECT #%d was resolved in SELECT #%d
use constant  ER_BAD_SLAVE_UNTIL_COND                           => 1277; # Incorrect parameter or combination of parameters for START SLAVE UNTIL
use constant  ER_MISSING_SKIP_SLAVE                             => 1278; # It is recommended to use --skip-slave-start when doing step-by-step replication with <...>
use constant  ER_UNTIL_COND_IGNORED                             => 1279; # SQL thread is not to be started so UNTIL options are ignored
use constant  ER_WRONG_NAME_FOR_INDEX                           => 1280; # Incorrect index name '%-.100s'
use constant  ER_WRONG_NAME_FOR_CATALOG                         => 1281; # Incorrect catalog name '%-.100s'
use constant  ER_WARN_QC_RESIZE                                 => 1282; # Query cache failed to set size %llu; new query cache size is %lu
use constant  ER_BAD_FT_COLUMN                                  => 1283; # Column '%-.192s' cannot be part of FULLTEXT index
use constant  ER_UNKNOWN_KEY_CACHE                              => 1284; # Unknown key cache '%-.100s'
use constant  ER_WARN_HOSTNAME_WONT_WORK                        => 1285; # MariaDB is started in --skip-name-resolve mode; you must restart it without this switch for this grant to work
use constant  ER_UNKNOWN_STORAGE_ENGINE                         => 1286; # Unknown storage engine '%s'
use constant  ER_WARN_DEPRECATED_SYNTAX                         => 1287; # '%s' is deprecated and will be removed in a future release. Please use %s instead
use constant  ER_NON_UPDATABLE_TABLE                            => 1288; # The target table %-.100s of the %s is not updatable
use constant  ER_FEATURE_DISABLED                               => 1289; # The '%s' feature is disabled; you need MariaDB built with '%s' to have it working
use constant  ER_OPTION_PREVENTS_STATEMENT                      => 1290; # The MariaDB server is running with the %s option so it cannot execute this statement
use constant  ER_DUPLICATED_VALUE_IN_TYPE                       => 1291; # !!! NOT MAPPED !!! # Column '%-.100s' has duplicated value '%-.64s' in %s
use constant  ER_TRUNCATED_WRONG_VALUE                          => 1292; # Truncated incorrect %-.32T value: '%-.128T'
use constant  ER_TOO_MUCH_AUTO_TIMESTAMP_COLS                   => 1293; # Incorrect table definition; there can be only one TIMESTAMP column with CURRENT_TIMES<...>
use constant  ER_INVALID_ON_UPDATE                              => 1294; # Invalid ON UPDATE clause for '%-.192s' column
use constant  ER_UNSUPPORTED_PS                                 => 1295; # This command is not supported in the prepared statement protocol yet
use constant  ER_GET_ERRMSG                                     => 1296; # Got error %d '%-.200s' from %s
use constant  ER_GET_TEMPORARY_ERRMSG                           => 1297; # Got temporary error %d '%-.200s' from %s
use constant  ER_UNKNOWN_TIME_ZONE                              => 1298; # Unknown or incorrect time zone: '%-.64s'
use constant  ER_WARN_INVALID_TIMESTAMP                         => 1299; # Invalid TIMESTAMP value in column '%s' at row %lu
use constant  ER_INVALID_CHARACTER_STRING                       => 1300; # Invalid %s character string: '%.64T'
use constant  ER_WARN_ALLOWED_PACKET_OVERFLOWED                 => 1301; # Result of %s() was larger than max_allowed_packet (%ld) - truncated
use constant  ER_CONFLICTING_DECLARATIONS                       => 1302; # Conflicting declarations: '%s%s' and '%s%s'
use constant  ER_SP_NO_RECURSIVE_CREATE                         => 1303; # Can't create a %s from within another stored routine
use constant  ER_SP_ALREADY_EXISTS                              => 1304; # %s %s already exists
use constant  ER_SP_DOES_NOT_EXIST                              => 1305; # %s %s does not exist
use constant  ER_SP_DROP_FAILED                                 => 1306; # Failed to DROP %s %s
use constant  ER_SP_STORE_FAILED                                => 1307; # Failed to CREATE %s %s
use constant  ER_SP_LILABEL_MISMATCH                            => 1308; # %s with no matching label: %s
use constant  ER_SP_LABEL_REDEFINE                              => 1309; # Redefining label %s
use constant  ER_SP_LABEL_MISMATCH                              => 1310; # End-label %s without match
use constant  ER_SP_UNINIT_VAR                                  => 1311; # Referring to uninitialized variable %s
use constant  ER_SP_BADSELECT                                   => 1312; # PROCEDURE %s can't return a result set in the given context
use constant  ER_SP_BADRETURN                                   => 1313; # RETURN is only allowed in a FUNCTION
use constant  ER_SP_BADSTATEMENT                                => 1314; # %s is not allowed in stored procedures
use constant  ER_UPDATE_LOG_DEPRECATED_IGNORED                  => 1315; # The update log is deprecated and replaced by the binary log; SET SQL_LOG_UPDATE has b<...>
use constant  ER_UPDATE_LOG_DEPRECATED_TRANSLATED               => 1316; # The update log is deprecated and replaced by the binary log; SET SQL_LOG_UPDATE has b<...>
use constant  ER_QUERY_INTERRUPTED                              => 1317; # Query execution was interrupted
use constant  ER_SP_WRONG_NO_OF_ARGS                            => 1318; # Incorrect number of arguments for %s %s; expected %u, got %u
use constant  ER_SP_COND_MISMATCH                               => 1319; # Undefined CONDITION: %s
use constant  ER_SP_NORETURN                                    => 1320; # No RETURN found in FUNCTION %s
use constant  ER_SP_NORETURNEND                                 => 1321; # FUNCTION %s ended without RETURN
use constant  ER_SP_BAD_CURSOR_QUERY                            => 1322; # Cursor statement must be a SELECT
use constant  ER_SP_BAD_CURSOR_SELECT                           => 1323; # Cursor SELECT must not have INTO
use constant  ER_SP_CURSOR_MISMATCH                             => 1324; # Undefined CURSOR: %s
use constant  ER_SP_CURSOR_ALREADY_OPEN                         => 1325; # Cursor is already open
use constant  ER_SP_CURSOR_NOT_OPEN                             => 1326; # Cursor is not open
use constant  ER_SP_UNDECLARED_VAR                              => 1327; # Undeclared variable: %s
use constant  ER_SP_WRONG_NO_OF_FETCH_ARGS                      => 1328; # Incorrect number of FETCH variables
use constant  ER_SP_FETCH_NO_DATA                               => 1329; # No data - zero rows fetched, selected, or processed
use constant  ER_SP_DUP_PARAM                                   => 1330; # Duplicate parameter: %s
use constant  ER_SP_DUP_VAR                                     => 1331; # Duplicate variable: %s
use constant  ER_SP_DUP_COND                                    => 1332; # Duplicate condition: %s
use constant  ER_SP_DUP_CURS                                    => 1333; # Duplicate cursor: %s
use constant  ER_SP_CANT_ALTER                                  => 1334; # Failed to ALTER %s %s
use constant  ER_SP_SUBSELECT_NYI                               => 1335; # Subquery value not supported
use constant  ER_STMT_NOT_ALLOWED_IN_SF_OR_TRG                  => 1336; # %s is not allowed in stored function or trigger
use constant  ER_SP_VARCOND_AFTER_CURSHNDLR                     => 1337; # Variable or condition declaration after cursor or handler declaration
use constant  ER_SP_CURSOR_AFTER_HANDLER                        => 1338; # Cursor declaration after handler declaration
use constant  ER_SP_CASE_NOT_FOUND                              => 1339; # Case not found for CASE statement
use constant  ER_FPARSER_TOO_BIG_FILE                           => 1340; # Configuration file '%-.192s' is too big
use constant  ER_FPARSER_BAD_HEADER                             => 1341; # Malformed file type header in file '%-.192s'
use constant  ER_FPARSER_EOF_IN_COMMENT                         => 1342; # Unexpected end of file while parsing comment '%-.200s'
use constant  ER_FPARSER_ERROR_IN_PARAMETER                     => 1343; # Error while parsing parameter '%-.192s' (line: '%-.192s')
use constant  ER_FPARSER_EOF_IN_UNKNOWN_PARAMETER               => 1344; # Unexpected end of file while skipping unknown parameter '%-.192s'
use constant  ER_VIEW_NO_EXPLAIN                                => 1345; # ANALYZE/EXPLAIN/SHOW can not be issued; lacking privileges for underlying table
use constant  ER_FRM_UNKNOWN_TYPE                               => 1346; # File '%-.192s' has unknown type '%-.64s' in its header
use constant  ER_WRONG_OBJECT                                   => 1347; # '%-.192s.%-.192s' is not of type '%s'
use constant  ER_NONUPDATEABLE_COLUMN                           => 1348; # Column '%-.192s' is not updatable
use constant  ER_VIEW_SELECT_DERIVED                            => 1349; # View's SELECT contains a subquery in the FROM clause
use constant  ER_VIEW_SELECT_CLAUSE                             => 1350; # View's SELECT contains a '%s' clause
use constant  ER_VIEW_SELECT_VARIABLE                           => 1351; # View's SELECT contains a variable or parameter
use constant  ER_VIEW_SELECT_TMPTABLE                           => 1352; # View's SELECT refers to a temporary table '%-.192s'
use constant  ER_VIEW_WRONG_LIST                                => 1353; # View's SELECT and view's field list have different column counts
use constant  ER_WARN_VIEW_MERGE                                => 1354; # View merge algorithm can't be used here for now (assumed undefined algorithm)
use constant  ER_WARN_VIEW_WITHOUT_KEY                          => 1355; # View being updated does not have complete key of underlying table in it
use constant  ER_VIEW_INVALID                                   => 1356; # View '%-.192s.%-.192s' references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them
use constant  ER_SP_NO_DROP_SP                                  => 1357; # Can't drop or alter a %s from within another stored routine
use constant  ER_SP_GOTO_IN_HNDLR                               => 1358; # GOTO is not allowed in a stored procedure handler
use constant  ER_TRG_ALREADY_EXISTS                             => 1359; # Trigger '%s' already exists
use constant  ER_TRG_DOES_NOT_EXIST                             => 1360; # Trigger does not exist
use constant  ER_TRG_ON_VIEW_OR_TEMP_TABLE                      => 1361; # Trigger's '%-.192s' is a view, temporary table or sequence
use constant  ER_TRG_CANT_CHANGE_ROW                            => 1362; # Updating of %s row is not allowed in %strigger
use constant  ER_TRG_NO_SUCH_ROW_IN_TRG                         => 1363; # There is no %s row in %s trigger
use constant  ER_NO_DEFAULT_FOR_FIELD                           => 1364; # Field '%-.192s' doesn't have a default value
use constant  ER_DIVISION_BY_ZERO                               => 1365; # Division by 0
use constant  ER_TRUNCATED_WRONG_VALUE_FOR_FIELD                => 1366; # Incorrect %-.32s value: '%-.128T' for column `%.192s`.`%.192s`.`%.192s` at row %lu
use constant  ER_ILLEGAL_VALUE_FOR_TYPE                         => 1367; # Illegal %s '%-.192T' value found during parsing
use constant  ER_VIEW_NONUPD_CHECK                              => 1368; # CHECK OPTION on non-updatable view %`-.192s.%`-.192s
use constant  ER_VIEW_CHECK_FAILED                              => 1369; # CHECK OPTION failed %`-.192s.%`-.192s
use constant  ER_PROCACCESS_DENIED_ERROR                        => 1370; # %-.32s command denied to user '%s'@'%s' for routine '%-.192s'
use constant  ER_RELAY_LOG_FAIL                                 => 1371; # Failed purging old relay logs: %s
use constant  ER_PASSWD_LENGTH                                  => 1372; # Password hash should be a %d-digit hexadecimal number
use constant  ER_UNKNOWN_TARGET_BINLOG                          => 1373; # Target log not found in binlog index
use constant  ER_IO_ERR_LOG_INDEX_READ                          => 1374; # I/O error reading log index file
use constant  ER_BINLOG_PURGE_PROHIBITED                        => 1375; # Server configuration does not permit binlog purge
use constant  ER_FSEEK_FAIL                                     => 1376; # Failed on fseek()
use constant  ER_BINLOG_PURGE_FATAL_ERR                         => 1377; # Fatal error during log purge
use constant  ER_LOG_IN_USE                                     => 1378; # A purgeable log is in use, will not purge
use constant  ER_LOG_PURGE_UNKNOWN_ERR                          => 1379; # Unknown error during log purge
use constant  ER_RELAY_LOG_INIT                                 => 1380; # Failed initializing relay log position: %s
use constant  ER_NO_BINARY_LOGGING                              => 1381; # You are not using binary logging
use constant  ER_RESERVED_SYNTAX                                => 1382; # The '%-.64s' syntax is reserved for purposes internal to the MariaDB server
use constant  ER_WSAS_FAILED                                    => 1383; # WSAStartup Failed
use constant  ER_DIFF_GROUPS_PROC                               => 1384; # Can't handle procedures with different groups yet
use constant  ER_NO_GROUP_FOR_PROC                              => 1385; # Select must have a group with this procedure
use constant  ER_ORDER_WITH_PROC                                => 1386; # Can't use ORDER clause with this procedure
use constant  ER_LOGGING_PROHIBIT_CHANGING_OF                   => 1387; # Binary logging and replication forbid changing the global server %s
use constant  ER_NO_FILE_MAPPING                                => 1388; # Can't map file: %-.200s, errno: %M
use constant  ER_WRONG_MAGIC                                    => 1389; # Wrong magic in %-.64s
use constant  ER_PS_MANY_PARAM                                  => 1390; # Prepared statement contains too many placeholders
use constant  ER_KEY_PART_0                                     => 1391; # Key part '%-.192s' length cannot be 0
use constant  ER_VIEW_CHECKSUM                                  => 1392; # View text checksum failed
use constant  ER_VIEW_MULTIUPDATE                               => 1393; # Can not modify more than one base table through a join view '%-.192s.%-.192s'
use constant  ER_VIEW_NO_INSERT_FIELD_LIST                      => 1394; # Can not insert into join view '%-.192s.%-.192s' without fields list
use constant  ER_VIEW_DELETE_MERGE_VIEW                         => 1395; # Can not delete from join view '%-.192s.%-.192s'
use constant  ER_CANNOT_USER                                    => 1396; # Operation %s failed for %.256s
use constant  ER_XAER_NOTA                                      => 1397; # Unknown XID
use constant  ER_XAER_INVAL                                     => 1398; # Invalid arguments (or unsupported command)
use constant  ER_XAER_RMFAIL                                    => 1399; # The command cannot be executed when global transaction is in the  %.64s state
use constant  ER_XAER_OUTSIDE                                   => 1400; # Some work is done outside global transaction
use constant  ER_XAER_RMERR                                     => 1401; # XAER_RMERR: Fatal error occurred in the transaction branch - check your data for cons<...>
use constant  ER_XA_RBROLLBACK                                  => 1402; # XA_RBROLLBACK: Transaction branch was rolled back
use constant  ER_NONEXISTING_PROC_GRANT                         => 1403; # There is no such grant defined for user '%-.48s' on host '%-.64s' on routine '%-.192s'
use constant  ER_PROC_AUTO_GRANT_FAIL                           => 1404; # Failed to grant EXECUTE and ALTER ROUTINE privileges
use constant  ER_PROC_AUTO_REVOKE_FAIL                          => 1405; # Failed to revoke all privileges to dropped routine
use constant  ER_DATA_TOO_LONG                                  => 1406; # Data too long for column '%s' at row %lu
use constant  ER_SP_BAD_SQLSTATE                                => 1407; # Bad SQLSTATE: '%s'
use constant  ER_STARTUP                                        => 1408; # !!! NOT MAPPED !!! # %s: ready for connections.
use constant  ER_LOAD_FROM_FIXED_SIZE_ROWS_TO_VAR               => 1409; # Can't load value from file with fixed size rows to variable
use constant  ER_CANT_CREATE_USER_WITH_GRANT                    => 1410; # You are not allowed to create a user with GRANT
use constant  ER_WRONG_VALUE_FOR_TYPE                           => 1411; # Incorrect %-.32s value: '%-.128T' for function %-.32s
use constant  ER_TABLE_DEF_CHANGED                              => 1412; # Table definition has changed, please retry transaction
use constant  ER_SP_DUP_HANDLER                                 => 1413; # Duplicate handler declared in the same block
use constant  ER_SP_NOT_VAR_ARG                                 => 1414; # OUT or INOUT argument %d for routine %s is not a variable or NEW pseudo-variable in B<...>
use constant  ER_SP_NO_RETSET                                   => 1415; # Not allowed to return a result set from a %s
use constant  ER_CANT_CREATE_GEOMETRY_OBJECT                    => 1416; # Cannot get geometry object from data you send to the GEOMETRY field
use constant  ER_FAILED_ROUTINE_BREAK_BINLOG                    => 1417; # A routine failed and has neither NO SQL nor READS SQL DATA in its declaration and bin<...>
use constant  ER_BINLOG_UNSAFE_ROUTINE                          => 1418; # This function has none of DETERMINISTIC, <..> in its declaration and binary logging <...>
use constant  ER_BINLOG_CREATE_ROUTINE_NEED_SUPER               => 1419; # You do not have the SUPER privilege and binary logging is enabled (you *might* want t<...>
use constant  ER_EXEC_STMT_WITH_OPEN_CURSOR                     => 1420; # You can't execute a prepared statement which has an open cursor associated with it. R<...>
use constant  ER_STMT_HAS_NO_OPEN_CURSOR                        => 1421; # The statement (%lu) has no open cursor
use constant  ER_COMMIT_NOT_ALLOWED_IN_SF_OR_TRG                => 1422; # Explicit or implicit commit is not allowed in stored function or trigger
use constant  ER_NO_DEFAULT_FOR_VIEW_FIELD                      => 1423; # Field of view '%-.192s.%-.192s' underlying table doesn't have a default value
use constant  ER_SP_NO_RECURSION                                => 1424; # Recursive stored functions and triggers are not allowed
use constant  ER_TOO_BIG_SCALE                                  => 1425; # Too big scale specified for '%-.192s'. Maximum is %u
use constant  ER_TOO_BIG_PRECISION                              => 1426; # Too big precision specified for '%-.192s'. Maximum is %u
use constant  ER_M_BIGGER_THAN_D                                => 1427; # For float(M,D), double(M,D) or decimal(M,D), M must be >= D (column '%-.192s')
use constant  ER_WRONG_LOCK_OF_SYSTEM_TABLE                     => 1428; # You can't combine write-locking of system tables with other tables or lock types
use constant  ER_CONNECT_TO_FOREIGN_DATA_SOURCE                 => 1429; # Unable to connect to foreign data source: %.64s
use constant  ER_QUERY_ON_FOREIGN_DATA_SOURCE                   => 1430; # There was a problem processing the query on the foreign data source. Data source erro<...>
use constant  ER_FOREIGN_DATA_SOURCE_DOESNT_EXIST               => 1431; # The foreign data source you are trying to reference does not exist. Data source error<...>
use constant  ER_FOREIGN_DATA_STRING_INVALID_CANT_CREATE        => 1432; # Can't create federated table. The data source connection string '%-.64s' is not in th<...>
use constant  ER_FOREIGN_DATA_STRING_INVALID                    => 1433; # The data source connection string '%-.64s' is not in the correct format
use constant  ER_CANT_CREATE_FEDERATED_TABLE                    => 1434; # Can't create federated table. Foreign data src error:  %-.64s
use constant  ER_TRG_IN_WRONG_SCHEMA                            => 1435; # Trigger in wrong schema
use constant  ER_STACK_OVERRUN_NEED_MORE                        => 1436; # Thread stack overrun:  %ld bytes used of a %ld byte stack, and %ld bytes needed. Cons<...>
use constant  ER_TOO_LONG_BODY                                  => 1437; # Routine body for '%-.100s' is too long
use constant  ER_WARN_CANT_DROP_DEFAULT_KEYCACHE                => 1438; # Cannot drop default keycache
use constant  ER_TOO_BIG_DISPLAYWIDTH                           => 1439; # Display width out of range for '%-.192s' (max = %lu)
use constant  ER_XAER_DUPID                                     => 1440; # The XID already exists
use constant  ER_DATETIME_FUNCTION_OVERFLOW                     => 1441; # Datetime function: %-.32s field overflow
use constant  ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG            => 1442; # Can't update table '%-.192s' in stored function/trigger because it is already used by statement which invoked this stored function/trigger
use constant  ER_VIEW_PREVENT_UPDATE                            => 1443; # The definition of table '%-.192s' prevents operation %-.192s on table '%-.192s'
use constant  ER_PS_NO_RECURSION                                => 1444; # The prepared statement contains a stored routine call that refers to that same statem<...>
use constant  ER_SP_CANT_SET_AUTOCOMMIT                         => 1445; # Not allowed to set autocommit from a stored function or trigger
use constant  ER_MALFORMED_DEFINER                              => 1446; # Invalid definer
use constant  ER_VIEW_FRM_NO_USER                               => 1447; # View '%-.192s'.'%-.192s' has no definer information (old table format). Current user <...>
use constant  ER_VIEW_OTHER_USER                                => 1448; # You need the SUPER privilege for creation view with '%-.192s'@'%-.192s' definer
use constant  ER_NO_SUCH_USER                                   => 1449; # The user specified as a definer ('%-.64s'@'%-.64s') does not exist
use constant  ER_FORBID_SCHEMA_CHANGE                           => 1450; # Changing schema from '%-.192s' to '%-.192s' is not allowed
use constant  ER_ROW_IS_REFERENCED_2                            => 1451; # Cannot delete or update a parent row: a foreign key constraint fails (%.192s)
use constant  ER_NO_REFERENCED_ROW_2                            => 1452; # Cannot add or update a child row: a foreign key constraint fails (%.192s)
use constant  ER_SP_BAD_VAR_SHADOW                              => 1453; # Variable '%-.64s' must be quoted with `...`, or renamed
use constant  ER_TRG_NO_DEFINER                                 => 1454; # No definer attribute for trigger '%-.192s'.'%-.192s'. The trigger will be activated u<...>
use constant  ER_OLD_FILE_FORMAT                                => 1455; # '%-.192s' has an old format, you should re-create the '%s' object(s)
use constant  ER_SP_RECURSION_LIMIT                             => 1456; # Recursive limit %d (as set by the max_sp_recursion_depth variable) was exceeded for routine %.192s
use constant  ER_SP_PROC_TABLE_CORRUPT                          => 1457; # Failed to load routine %-.192s (internal code %d)
use constant  ER_SP_WRONG_NAME                                  => 1458; # Incorrect routine name '%-.192s'
use constant  ER_TABLE_NEEDS_UPGRADE                            => 1459; # Upgrade required. Please do "REPAIR %s %`s" or dump/reload to fix it!
use constant  ER_SP_NO_AGGREGATE                                => 1460; # AGGREGATE is not supported for stored functions
use constant  ER_MAX_PREPARED_STMT_COUNT_REACHED                => 1461; # Can't create more than max_prepared_stmt_count statements (current value: %u)
use constant  ER_VIEW_RECURSIVE                                 => 1462; # %`s.%`s contains view recursion
use constant  ER_NON_GROUPING_FIELD_USED                        => 1463; # Non-grouping field '%-.192s' is used in %-.64s clause
use constant  ER_TABLE_CANT_HANDLE_SPKEYS                       => 1464; # The storage engine %s doesn't support SPATIAL indexes
use constant  ER_NO_TRIGGERS_ON_SYSTEM_SCHEMA                   => 1465; # Triggers can not be created on system tables
use constant  ER_REMOVED_SPACES                                 => 1466; # !!! NOT MAPPED !!! Leading spaces are removed from name '%s'
use constant  ER_AUTOINC_READ_FAILED                            => 1467; # Failed to read auto-increment value from storage engine
use constant  ER_USERNAME                                       => 1468; # !!! NOT MAPPED !!! user name
use constant  ER_HOSTNAME                                       => 1469; # !!! NOT MAPPED !!! host name
use constant  ER_WRONG_STRING_LENGTH                            => 1470; # String '%-.70T' is too long for %s (should be no longer than %d)
use constant  ER_NON_INSERTABLE_TABLE                           => 1471; # The target table %-.100s of the %s is not insertable-into
use constant  ER_ADMIN_WRONG_MRG_TABLE                          => 1472; # Table '%-.64s' is differently defined or of non-MyISAM type or doesn't exist
use constant  ER_TOO_HIGH_LEVEL_OF_NESTING_FOR_SELECT           => 1473; # Too high level of nesting for select
use constant  ER_NAME_BECOMES_EMPTY                             => 1474; # Name '%-.64s' has become ''
use constant  ER_AMBIGUOUS_FIELD_TERM                           => 1475; # First character of the FIELDS TERMINATED string is ambiguous; please use non-optional<...>
use constant  ER_FOREIGN_SERVER_EXISTS                          => 1476; # Cannot create foreign server '%s' as it already exists
use constant  ER_FOREIGN_SERVER_DOESNT_EXIST                    => 1477; # The foreign server name you are trying to reference does not exist. Data source error:  %-.64s
use constant  ER_ILLEGAL_HA_CREATE_OPTION                       => 1478; # Table storage engine '%-.64s' does not support the create option '%.64s'
use constant  ER_PARTITION_REQUIRES_VALUES_ERROR                => 1479; # Syntax error: %-.64s PARTITIONING requires definition of VALUES %-.64s for each partition
use constant  ER_PARTITION_WRONG_VALUES_ERROR                   => 1480; # Only %-.64s PARTITIONING can use VALUES %-.64s in partition definition
use constant  ER_PARTITION_MAXVALUE_ERROR                       => 1481; # MAXVALUE can only be used in last partition definition
use constant  ER_PARTITION_SUBPARTITION_ERROR                   => 1482; # Subpartitions can only be hash partitions and by key
use constant  ER_PARTITION_SUBPART_MIX_ERROR                    => 1483; # Must define subpartitions on all partitions if on one partition
use constant  ER_PARTITION_WRONG_NO_PART_ERROR                  => 1484; # Wrong number of partitions defined, mismatch with previous setting
use constant  ER_PARTITION_WRONG_NO_SUBPART_ERROR               => 1485; # Wrong number of subpartitions defined, mismatch with previous setting
use constant  ER_WRONG_EXPR_IN_PARTITION_FUNC_ERROR             => 1486; # Constant, random or timezone-dependent expressions in (sub)partitioning function are <...>
use constant  ER_NOT_CONSTANT_EXPRESSION                        => 1487; # Expression in %s must be constant
use constant  ER_FIELD_NOT_FOUND_PART_ERROR                     => 1488; # Field in list of fields for partition function not found in table
use constant  ER_LIST_OF_FIELDS_ONLY_IN_HASH_ERROR              => 1489; # List of fields is only allowed in KEY partitions
use constant  ER_INCONSISTENT_PARTITION_INFO_ERROR              => 1490; # The partition info in the frm file is not consistent with what can be written into th<...>
use constant  ER_PARTITION_FUNC_NOT_ALLOWED_ERROR               => 1491; # The %-.192s function returns the wrong type
use constant  ER_PARTITIONS_MUST_BE_DEFINED_ERROR               => 1492; # For %-.64s partitions each partition must be defined
use constant  ER_RANGE_NOT_INCREASING_ERROR                     => 1493; # VALUES LESS THAN value must be strictly increasing for each partition
use constant  ER_INCONSISTENT_TYPE_OF_FUNCTIONS_ERROR           => 1494; # VALUES value must be of same type as partition function
use constant  ER_MULTIPLE_DEF_CONST_IN_LIST_PART_ERROR          => 1495; # Multiple definition of same constant in list partitioning
use constant  ER_PARTITION_ENTRY_ERROR                          => 1496; # Partitioning can not be used stand-alone in query
use constant  ER_MIX_HANDLER_ERROR                              => 1497; # The mix of handlers in the partitions is not allowed in this version of MariaDB
use constant  ER_PARTITION_NOT_DEFINED_ERROR                    => 1498; # For the partitioned engine it is necessary to define all %-.64s
use constant  ER_TOO_MANY_PARTITIONS_ERROR                      => 1499; # Too many partitions (including subpartitions) were defined
use constant  ER_SUBPARTITION_ERROR                             => 1500; # It is only possible to mix RANGE/LIST partitioning with HASH/KEY partitioning for sub<...>
use constant  ER_CANT_CREATE_HANDLER_FILE                       => 1501; # Failed to create specific handler file
use constant  ER_BLOB_FIELD_IN_PART_FUNC_ERROR                  => 1502; # A BLOB field is not allowed in partition function
use constant  ER_UNIQUE_KEY_NEED_ALL_FIELDS_IN_PF               => 1503; # A %-.192s must include all columns in the table's partitioning function
use constant  ER_NO_PARTS_ERROR                                 => 1504; # Number of %-.64s = 0 is not an allowed value
use constant  ER_PARTITION_MGMT_ON_NONPARTITIONED               => 1505; # Partition management on a not partitioned table is not possible
use constant  ER_FOREIGN_KEY_ON_PARTITIONED                     => 1506; # Partitioned tables do not support %s
use constant  ER_DROP_PARTITION_NON_EXISTENT                    => 1507; # Wrong partition name or partition list
use constant  ER_DROP_LAST_PARTITION                            => 1508; # Cannot remove all partitions, use DROP TABLE instead
use constant  ER_COALESCE_ONLY_ON_HASH_PARTITION                => 1509; # COALESCE PARTITION can only be used on HASH/KEY partitions
use constant  ER_REORG_HASH_ONLY_ON_SAME_NO                     => 1510; # REORGANIZE PARTITION can only be used to reorganize partitions not to change their numbers
use constant  ER_REORG_NO_PARAM_ERROR                           => 1511; # REORGANIZE PARTITION without parameters can only be used on auto-partitioned tables using HASH PARTITIONs
use constant  ER_ONLY_ON_RANGE_LIST_PARTITION                   => 1512; # %-.64s PARTITION can only be used on RANGE/LIST partitions
use constant  ER_ADD_PARTITION_SUBPART_ERROR                    => 1513; # Trying to Add partition(s) with wrong number of subpartitions
use constant  ER_ADD_PARTITION_NO_NEW_PARTITION                 => 1514; # At least one partition must be added
use constant  ER_COALESCE_PARTITION_NO_PARTITION                => 1515; # At least one partition must be coalesced
use constant  ER_REORG_PARTITION_NOT_EXIST                      => 1516; # More partitions to reorganize than there are partitions
use constant  ER_SAME_NAME_PARTITION                            => 1517; # Duplicate partition name %-.192s
use constant  ER_NO_BINLOG_ERROR                                => 1518; # It is not allowed to shut off binlog on this command
use constant  ER_CONSECUTIVE_REORG_PARTITIONS                   => 1519; # When reorganizing a set of partitions they must be in consecutive order
use constant  ER_REORG_OUTSIDE_RANGE                            => 1520; # Reorganize of range partitions cannot change total ranges except for last partition w<...>
use constant  ER_PARTITION_FUNCTION_FAILURE                     => 1521; # Partition function not supported in this version for this handler
use constant  ER_PART_STATE_ERROR                               => 1522; # Partition state cannot be defined from CREATE/ALTER TABLE
use constant  ER_LIMITED_PART_RANGE                             => 1523; # The %-.64s handler only supports 32 bit integers in VALUES
use constant  ER_PLUGIN_IS_NOT_LOADED                           => 1524; # Plugin '%-.192s' is not loaded
use constant  ER_WRONG_VALUE                                    => 1525; # Incorrect %-.32s value: '%-.128T'
use constant  ER_NO_PARTITION_FOR_GIVEN_VALUE                   => 1526; # Table has no partition for value %-.64s
use constant  ER_FILEGROUP_OPTION_ONLY_ONCE                     => 1527; # It is not allowed to specify %s more than once
use constant  ER_CREATE_FILEGROUP_FAILED                        => 1528; # Failed to create %s
use constant  ER_DROP_FILEGROUP_FAILED                          => 1529; # Failed to drop %s
use constant  ER_TABLESPACE_AUTO_EXTEND_ERROR                   => 1530; # The handler doesn't support autoextend of tablespaces
use constant  ER_WRONG_SIZE_NUMBER                              => 1531; # A size parameter was incorrectly specified, either number or on the form 10M
use constant  ER_SIZE_OVERFLOW_ERROR                            => 1532; # The size number was correct but we don't allow the digit part to be more than 2 billion
use constant  ER_ALTER_FILEGROUP_FAILED                         => 1533; # Failed to alter: %s
use constant  ER_BINLOG_ROW_LOGGING_FAILED                      => 1534; # Writing one row to the row-based binary log failed
use constant  ER_BINLOG_ROW_WRONG_TABLE_DEF                     => 1535; # Table definition on master and slave does not match: %s
use constant  ER_BINLOG_ROW_RBR_TO_SBR                          => 1536; # Slave running with --log-slave-updates must use row-based binary logging to be able t<...>
use constant  ER_EVENT_ALREADY_EXISTS                           => 1537; # Event '%-.192s' already exists
use constant  ER_EVENT_STORE_FAILED                             => 1538; # Failed to store event %s. Error code %M from storage engine
use constant  ER_EVENT_DOES_NOT_EXIST                           => 1539; # Unknown event '%-.192s'
use constant  ER_EVENT_CANT_ALTER                               => 1540; # Failed to alter event '%-.192s'
use constant  ER_EVENT_DROP_FAILED                              => 1541; # Failed to drop %s
use constant  ER_EVENT_INTERVAL_NOT_POSITIVE_OR_TOO_BIG         => 1542; # INTERVAL is either not positive or too big
use constant  ER_EVENT_ENDS_BEFORE_STARTS                       => 1543; # ENDS is either invalid or before STARTS
use constant  ER_EVENT_EXEC_TIME_IN_THE_PAST                    => 1544; # Event execution time is in the past. Event has been disabled
use constant  ER_EVENT_OPEN_TABLE_FAILED                        => 1545; # Failed to open mysql.event
use constant  ER_EVENT_NEITHER_M_EXPR_NOR_M_AT                  => 1546; # No datetime expression provided
#             ER_UNUSED_2                                       => 1547; # You should never see it
#             ER_UNUSED_3                                       => 1548; # You should never see it
use constant  ER_EVENT_CANNOT_DELETE                            => 1549; # Failed to delete the event from mysql.event
use constant  ER_EVENT_COMPILE_ERROR                            => 1550; # Error during compilation of event's body
use constant  ER_EVENT_SAME_NAME                                => 1551; # Same old and new event name
use constant  ER_EVENT_DATA_TOO_LONG                            => 1552; # Data for column '%s' too long
use constant  ER_DROP_INDEX_FK                                  => 1553; # Cannot drop index '%-.192s': needed in a foreign key constraint
use constant  ER_WARN_DEPRECATED_SYNTAX_WITH_VER                => 1554; # The syntax '%s' is deprecated and will be removed in MariaDB %s. Please use %s instead
use constant  ER_CANT_WRITE_LOCK_LOG_TABLE                      => 1555; # You can't write-lock a log table. Only read access is possible
use constant  ER_CANT_LOCK_LOG_TABLE                            => 1556; # You can't use locks with log tables
#             ER_UNUSED_4                                       => 1557; # You should never see it
use constant  ER_COL_COUNT_DOESNT_MATCH_PLEASE_UPDATE           => 1558; # Column count of mysql.%s is wrong. Expected %d, found %d. Created with MariaDB %d, no<...>
use constant  ER_TEMP_TABLE_PREVENTS_SWITCH_OUT_OF_RBR          => 1559; # Cannot switch out of the row-based binary log format when the session has open temporary tables
use constant  ER_STORED_FUNCTION_PREVENTS_SWITCH_BINLOG_FORMAT  => 1560; # Cannot change the binary logging format inside a stored function or trigger
#             ER_UNUSED_13                                      => 1561; # You should never see it
use constant  ER_PARTITION_NO_TEMPORARY                         => 1562; # Cannot create temporary table with partitions
use constant  ER_PARTITION_CONST_DOMAIN_ERROR                   => 1563; # Partition constant is out of partition function domain
use constant  ER_PARTITION_FUNCTION_IS_NOT_ALLOWED              => 1564; # This partition function is not allowed
use constant  ER_DDL_LOG_ERROR                                  => 1565; # Error in DDL log
use constant  ER_NULL_IN_VALUES_LESS_THAN                       => 1566; # Not allowed to use NULL value in VALUES LESS THAN
use constant  ER_WRONG_PARTITION_NAME                           => 1567; # Incorrect partition name
use constant  ER_CANT_CHANGE_TX_ISOLATION                       => 1568; # Transaction characteristics can't be changed while a transaction is in progress
use constant  ER_DUP_ENTRY_AUTOINCREMENT_CASE                   => 1569; # ALTER TABLE causes auto_increment resequencing, resulting in duplicate entry '%-.192T<...>
use constant  ER_EVENT_MODIFY_QUEUE_ERROR                       => 1570; # Internal scheduler error %d
use constant  ER_EVENT_SET_VAR_ERROR                            => 1571; # Error during starting/stopping of the scheduler. Error code %M
use constant  ER_PARTITION_MERGE_ERROR                          => 1572; # Engine cannot be used in partitioned tables
use constant  ER_CANT_ACTIVATE_LOG                              => 1573; # Cannot activate '%-.64s' log
use constant  ER_RBR_NOT_AVAILABLE                              => 1574; # The server was not built with row-based replication
use constant  ER_BASE64_DECODE_ERROR                            => 1575; # Decoding of base64 string failed
use constant  ER_EVENT_RECURSION_FORBIDDEN                      => 1576; # Recursion of EVENT DDL statements is forbidden when body is present
use constant  ER_EVENTS_DB_ERROR                                => 1577; # Cannot proceed, because event scheduler is disabled
use constant  ER_ONLY_INTEGERS_ALLOWED                          => 1578; # Only integers allowed as number here
use constant  ER_UNSUPORTED_LOG_ENGINE                          => 1579; # Storage engine %s cannot be used for log tables
use constant  ER_BAD_LOG_STATEMENT                              => 1580; # You cannot '%s' a log table if logging is enabled
use constant  ER_CANT_RENAME_LOG_TABLE                          => 1581; # Cannot rename '%s'. When logging enabled, rename to/from log table must rename two ta<...>
use constant  ER_WRONG_PARAMCOUNT_TO_NATIVE_FCT                 => 1582; # Incorrect parameter count in the call to native function '%-.192s'
use constant  ER_WRONG_PARAMETERS_TO_NATIVE_FCT                 => 1583; # Incorrect parameters in the call to native function '%-.192s'
use constant  ER_WRONG_PARAMETERS_TO_STORED_FCT                 => 1584; # Incorrect parameters in the call to stored function '%-.192s'
use constant  ER_NATIVE_FCT_NAME_COLLISION                      => 1585; # This function '%-.192s' has the same name as a native function
use constant  ER_DUP_ENTRY_WITH_KEY_NAME                        => 1586; # Duplicate entry '%-.64T' for key '%-.192s'
use constant  ER_BINLOG_PURGE_EMFILE                            => 1587; # Too many files opened, please execute the command again
use constant  ER_EVENT_CANNOT_CREATE_IN_THE_PAST                => 1588; # Event execution time is in the past and ON COMPLETION NOT PRESERVE is set. The event <...>
use constant  ER_EVENT_CANNOT_ALTER_IN_THE_PAST                 => 1589; # Event execution time is in the past and ON COMPLETION NOT PRESERVE is set. <..>
use constant  ER_SLAVE_INCIDENT                                 => 1590; # The incident %s occurred on the master. Message: %-.64s
use constant  ER_NO_PARTITION_FOR_GIVEN_VALUE_SILENT            => 1591; # Table has no partition for some existing values
use constant  ER_BINLOG_UNSAFE_STATEMENT                        => 1592; # Unsafe statement written to the binary log using statement format since BINLOG_FORMAT<...>
use constant  ER_SLAVE_FATAL_ERROR                              => 1593; # Fatal error: %s
use constant  ER_SLAVE_RELAY_LOG_READ_FAILURE                   => 1594; # Relay log read failure: %s
use constant  ER_SLAVE_RELAY_LOG_WRITE_FAILURE                  => 1595; # Relay log write failure: %s
use constant  ER_SLAVE_CREATE_EVENT_FAILURE                     => 1596; # Failed to create %s
use constant  ER_SLAVE_MASTER_COM_FAILURE                       => 1597; # Master command %s failed: %s
use constant  ER_BINLOG_LOGGING_IMPOSSIBLE                      => 1598; # Binary logging not possible. Message: %s
use constant  ER_VIEW_NO_CREATION_CTX                           => 1599; # View %`s.%`s has no creation context
use constant  ER_VIEW_INVALID_CREATION_CTX                      => 1600; # Creation context of view %`s.%`s is invalid
use constant  ER_SR_INVALID_CREATION_CTX                        => 1601; # Creation context of stored routine %`s.%`s is invalid
use constant  ER_TRG_CORRUPTED_FILE                             => 1602; # Corrupted TRG file for table %`s.%`s
use constant  ER_TRG_NO_CREATION_CTX                            => 1603; # Triggers for table %`s.%`s have no creation context
use constant  ER_TRG_INVALID_CREATION_CTX                       => 1604; # Trigger creation context of table %`s.%`s is invalid
use constant  ER_EVENT_INVALID_CREATION_CTX                     => 1605; # Creation context of event %`s.%`s is invalid
use constant  ER_TRG_CANT_OPEN_TABLE                            => 1606; # Cannot open table for trigger %`s.%`s
use constant  ER_CANT_CREATE_SROUTINE                           => 1607; # Cannot create stored routine %`s. Check warnings
#             ER_UNUSED_11                                      => 1608; # You should never see it
use constant  ER_NO_FORMAT_DESCRIPTION_EVENT_BEFORE_BINLOG_STATEMENT => 1609; # The BINLOG statement of type %s was not preceded by a format description BINLOG statement
use constant  ER_SLAVE_CORRUPT_EVENT                            => 1610; # Corrupted replication event was detected
use constant  ER_LOAD_DATA_INVALID_COLUMN                       => 1611; # Invalid column reference (%-.64s) in LOAD DATA
use constant  ER_LOG_PURGE_NO_FILE                              => 1612; # Being purged log %s was not found
use constant  ER_XA_RBTIMEOUT                                   => 1613; # XA_RBTIMEOUT: Transaction branch was rolled back: took too long
use constant  ER_XA_RBDEADLOCK                                  => 1614; # XA_RBDEADLOCK: Transaction branch was rolled back: deadlock was detected
use constant  ER_NEED_REPREPARE                                 => 1615; # Prepared statement needs to be re-prepared
use constant  ER_DELAYED_NOT_SUPPORTED                          => 1616; # DELAYED option not supported for table '%-.192s'
use constant  WARN_NO_MASTER_INFO                               => 1617; # There is no master connection '%.*s'
use constant  WARN_OPTION_IGNORED                               => 1618; # <%-.64s> option ignored
use constant  ER_PLUGIN_DELETE_BUILTIN                          => 1619; # Built-in plugins cannot be deleted
use constant  WARN_PLUGIN_BUSY                                  => 1620; # Plugin is busy and will be uninstalled on shutdown
use constant  ER_VARIABLE_IS_READONLY                           => 1621; # %s variable '%s' is read-only. Use SET %s to assign the value
use constant  ER_WARN_ENGINE_TRANSACTION_ROLLBACK               => 1622; # Storage engine %s does not support rollback for this statement. Transaction rolled ba<...>
use constant  ER_SLAVE_HEARTBEAT_FAILURE                        => 1623; # Unexpected master's heartbeat data: %s
use constant  ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE             => 1624; # The requested value for the heartbeat period is either negative or exceeds the maximum allowed (%u seconds)
#             ER_UNUSED_14                                      => 1625; # You should never see it
use constant  ER_CONFLICT_FN_PARSE_ERROR                        => 1626; # Error in parsing conflict function. Message: %-.64s
use constant  ER_EXCEPTIONS_WRITE_ERROR                         => 1627; # Write to exceptions table failed. Message: %-.128s"
use constant  ER_TOO_LONG_TABLE_COMMENT                         => 1628; # Comment for table '%-.64s' is too long (max = %u)
use constant  ER_TOO_LONG_FIELD_COMMENT                         => 1629; # Comment for field '%-.64s' is too long (max = %u)
use constant  ER_FUNC_INEXISTENT_NAME_COLLISION                 => 1630; # FUNCTION %s does not exist. Check the 'Function Name Parsing and Resolution' section <...>
use constant  ER_DATABASE_NAME                                  => 1631; # !!! NOT MAPPED !!! # Database
use constant  ER_TABLE_NAME                                     => 1632; # !!! NOT MAPPED !!! # Table
use constant  ER_PARTITION_NAME                                 => 1633; # !!! NOT MAPPED !!! # Partition
use constant  ER_SUBPARTITION_NAME                              => 1634; # !!! NOT MAPPED !!! # Subpartition
use constant  ER_TEMPORARY_NAME                                 => 1635; # !!! NOT MAPPED !!! # Temporary
use constant  ER_RENAMED_NAME                                   => 1636; # !!! NOT MAPPED !!! # Renamed
use constant  ER_TOO_MANY_CONCURRENT_TRXS                       => 1637; # Too many active concurrent transactions
use constant  WARN_NON_ASCII_SEPARATOR_NOT_IMPLEMENTED          => 1638; # Non-ASCII separator arguments are not fully supported
use constant  ER_DEBUG_SYNC_TIMEOUT                             => 1639; # debug sync point wait timed out
use constant  ER_DEBUG_SYNC_HIT_LIMIT                           => 1640; # debug sync point hit limit reached
use constant  ER_DUP_SIGNAL_SET                                 => 1641; # Duplicate condition information item '%s'
use constant  ER_SIGNAL_WARN                                    => 1642; # Unhandled user-defined warning condition
use constant  ER_SIGNAL_NOT_FOUND                               => 1643; # Unhandled user-defined not found condition
use constant  ER_SIGNAL_EXCEPTION                               => 1644; # Unhandled user-defined exception condition
use constant  ER_RESIGNAL_WITHOUT_ACTIVE_HANDLER                => 1645; # RESIGNAL when handler not active
use constant  ER_SIGNAL_BAD_CONDITION_TYPE                      => 1646; # SIGNAL/RESIGNAL can only use a CONDITION defined with SQLSTATE
use constant  WARN_COND_ITEM_TRUNCATED                          => 1647; # Data truncated for condition item '%s'
use constant  ER_COND_ITEM_TOO_LONG                             => 1648; # Data too long for condition item '%s'
use constant  ER_UNKNOWN_LOCALE                                 => 1649; # Unknown locale: '%-.64s'
use constant  ER_SLAVE_IGNORE_SERVER_IDS                        => 1650; # The requested server id %d clashes with the slave startup option --replicate-same-server-id
use constant  ER_QUERY_CACHE_DISABLED                           => 1651; # Query cache is disabled; set query_cache_type to ON or DEMAND to enable it
use constant  ER_SAME_NAME_PARTITION_FIELD                      => 1652; # Duplicate partition field name '%-.192s'
use constant  ER_PARTITION_COLUMN_LIST_ERROR                    => 1653; # Inconsistency in usage of column lists for partitioning
use constant  ER_WRONG_TYPE_COLUMN_VALUE_ERROR                  => 1654; # Partition column values of incorrect type
use constant  ER_TOO_MANY_PARTITION_FUNC_FIELDS_ERROR           => 1655; # Too many fields in '%-.192s'
use constant  ER_MAXVALUE_IN_VALUES_IN                          => 1656; # Cannot use MAXVALUE as value in VALUES IN
use constant  ER_TOO_MANY_VALUES_ERROR                          => 1657; # Cannot have more than one value for this type of %-.64s partitioning
use constant  ER_ROW_SINGLE_PARTITION_FIELD_ERROR               => 1658; # Row expressions in VALUES IN only allowed for multi-field column partitioning
use constant  ER_FIELD_TYPE_NOT_ALLOWED_AS_PARTITION_FIELD      => 1659; # Field '%-.192s' is of a not allowed type for this type of partitioning
use constant  ER_PARTITION_FIELDS_TOO_LONG                      => 1660; # The total length of the partitioning fields is too large
use constant  ER_BINLOG_ROW_ENGINE_AND_STMT_ENGINE              => 1661; # Cannot execute statement: impossible to write to binary log since both row-incapable <...>
use constant  ER_BINLOG_ROW_MODE_AND_STMT_ENGINE                => 1662; # Cannot execute statement: impossible to write to binary log since BINLOG_FORMAT = ROW<...>
use constant  ER_BINLOG_UNSAFE_AND_STMT_ENGINE                  => 1663; # Cannot execute statement: impossible to write to binary log since statement is unsafe<...>
use constant  ER_BINLOG_ROW_INJECTION_AND_STMT_ENGINE           => 1664; # Cannot execute statement: impossible to write to binary log since statement is in row<...>
use constant  ER_BINLOG_STMT_MODE_AND_ROW_ENGINE                => 1665; # Cannot execute statement: impossible to write to binary log since BINLOG_FORMAT = STATEMENT <...>
use constant  ER_BINLOG_ROW_INJECTION_AND_STMT_MODE             => 1666; # Cannot execute statement: impossible to write to binary log since statement is in row<...>
use constant  ER_BINLOG_MULTIPLE_ENGINES_AND_SELF_LOGGING_ENGINE => 1667; # Cannot execute statement: impossible to write to binary log since more than one engin<...>
use constant  ER_BINLOG_UNSAFE_LIMIT                            => 1668; # The statement is unsafe because it uses a LIMIT clause. This is unsafe because the se<...>
use constant  ER_BINLOG_UNSAFE_INSERT_DELAYED                   => 1669; # The statement is unsafe because it uses INSERT DELAYED. This is unsafe because the ti<...>
use constant  ER_BINLOG_UNSAFE_SYSTEM_TABLE                     => 1670; # The statement is unsafe because it uses the general log, slow query log <...>
use constant  ER_BINLOG_UNSAFE_AUTOINC_COLUMNS                  => 1671; # Statement is unsafe because it invokes a trigger or a stored function that inserts in<...>
use constant  ER_BINLOG_UNSAFE_UDF                              => 1672; # Statement is unsafe because it uses a UDF which may not return the same value on the slave
use constant  ER_BINLOG_UNSAFE_SYSTEM_VARIABLE                  => 1673; # Statement is unsafe because it uses a system variable that may have a different value<...>
use constant  ER_BINLOG_UNSAFE_SYSTEM_FUNCTION                  => 1674; # Statement is unsafe because it uses a system function that may return a different val<...>
use constant  ER_BINLOG_UNSAFE_NONTRANS_AFTER_TRANS             => 1675; # Statement is unsafe because it accesses a non-transactional table after accessing a t<...>
use constant  ER_MESSAGE_AND_STATEMENT                          => 1676; # %s Statement: %s
use constant  ER_SLAVE_CONVERSION_FAILED                        => 1677; # Column %d of table '%-.192s.%-.192s' cannot be converted from type '%-.50s' to type '<...>
use constant  ER_SLAVE_CANT_CREATE_CONVERSION                   => 1678; # Can't create conversion table for table '%-.192s.%-.192s'
use constant  ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_BINLOG_FORMAT => 1679; # Cannot modify @@session.binlog_format inside a transaction
use constant  ER_PATH_LENGTH                                    => 1680; # The path specified for %.64T is too long
use constant  ER_WARN_DEPRECATED_SYNTAX_NO_REPLACEMENT          => 1681; # '%s' is deprecated and will be removed in a future release
use constant  ER_WRONG_NATIVE_TABLE_STRUCTURE                   => 1682; # Native table '%-.64s'.'%-.64s' has the wrong structure
use constant  ER_WRONG_PERFSCHEMA_USAGE                         => 1683; # Invalid performance_schema usage
use constant  ER_WARN_I_S_SKIPPED_TABLE                         => 1684; # Table '%s'.'%s' was skipped since its definition is being modified by concurrent DDL <...>
use constant  ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_BINLOG_DIRECT => 1685; # Cannot modify @@session.binlog_direct_non_transactional_updates inside a transaction
use constant  ER_STORED_FUNCTION_PREVENTS_SWITCH_BINLOG_DIRECT  => 1686; # Cannot change the binlog direct flag inside a stored function or trigger
use constant  ER_SPATIAL_MUST_HAVE_GEOM_COL                     => 1687; # A SPATIAL index may only contain a geometrical type column
use constant  ER_TOO_LONG_INDEX_COMMENT                         => 1688; # Comment for index '%-.64s' is too long (max = %lu)
use constant  ER_LOCK_ABORTED                                   => 1689; # Wait on a lock was aborted due to a pending exclusive lock
use constant  ER_DATA_OUT_OF_RANGE                              => 1690; # %s value is out of range in '%s'
use constant  ER_WRONG_SPVAR_TYPE_IN_LIMIT                      => 1691; # A variable of a non-integer based type in LIMIT clause
use constant  ER_BINLOG_UNSAFE_MULTIPLE_ENGINES_AND_SELF_LOGGING_ENGINE => 1692; # Mixing self-logging and non-self-logging engines in a statement is unsafe
use constant  ER_BINLOG_UNSAFE_MIXED_STATEMENT                  => 1693; # Statement accesses nontransactional table as well as transactional or temporary table<...>
use constant  ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_SQL_LOG_BIN => 1694; # Cannot modify @@session.sql_log_bin inside a transaction
use constant  ER_STORED_FUNCTION_PREVENTS_SWITCH_SQL_LOG_BIN    => 1695; # Cannot change the sql_log_bin inside a stored function or trigger
use constant  ER_FAILED_READ_FROM_PAR_FILE                      => 1696; # Failed to read from the .par file
use constant  ER_VALUES_IS_NOT_INT_TYPE_ERROR                   => 1697; # VALUES value for partition '%-.64s' must have type INT
use constant  ER_ACCESS_DENIED_NO_PASSWORD_ERROR                => 1698; # Access denied for user '%s'@'%s'
use constant  ER_SET_PASSWORD_AUTH_PLUGIN                       => 1699; # SET PASSWORD has no significance for users authenticating via plugins
use constant  ER_GRANT_PLUGIN_USER_EXISTS                       => 1700; # GRANT with IDENTIFIED WITH is illegal because the user %-.*s already exists
use constant  ER_TRUNCATE_ILLEGAL_FK                            => 1701; # Cannot truncate a table referenced in a foreign key constraint (%.192s)
use constant  ER_PLUGIN_IS_PERMANENT                            => 1702; # Plugin '%s' is force_plus_permanent and can not be unloaded
use constant  ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MIN         => 1703; # The requested value for the heartbeat period is less than 1 millisecond. The value is<...>
use constant  ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MAX         => 1704; # The requested value for the heartbeat period exceeds the value of `slave_net_timeout'<...>
use constant  ER_STMT_CACHE_FULL                                => 1705; # Multi-row statements required more than 'max_binlog_stmt_cache_size' bytes of storage.
use constant  ER_MULTI_UPDATE_KEY_CONFLICT                      => 1706; # Primary key/partition key update is not allowed since the table is updated both as '%-.192s' and '%-.192s'
use constant  ER_TABLE_NEEDS_REBUILD                            => 1707; # Table rebuild required. Please do "ALTER TABLE %`s FORCE" or dump/reload to fix it!
use constant  WARN_OPTION_BELOW_LIMIT                           => 1708; # The value of '%s' should be no less than the value of '%s'
use constant  ER_INDEX_COLUMN_TOO_LONG                          => 1709; # Index column size too large. The maximum column size is %lu bytes
use constant  ER_ERROR_IN_TRIGGER_BODY                          => 1710; # Trigger '%-.64s' has an error in its body: '%-.256s'
use constant  ER_ERROR_IN_UNKNOWN_TRIGGER_BODY                  => 1711; # Unknown trigger has an error in its body: '%-.256s'
use constant  ER_INDEX_CORRUPT                                  => 1712; # Index %s is corrupted
use constant  ER_UNDO_RECORD_TOO_BIG                            => 1713; # Undo log record is too big
use constant  ER_BINLOG_UNSAFE_INSERT_IGNORE_SELECT             => 1714; # INSERT IGNORE... SELECT is unsafe because the order in which rows are retrieved by th<...>
use constant  ER_BINLOG_UNSAFE_INSERT_SELECT_UPDATE             => 1715; # INSERT... SELECT... ON DUPLICATE KEY UPDATE is unsafe because the order in which rows<...>
use constant  ER_BINLOG_UNSAFE_REPLACE_SELECT                   => 1716; # REPLACE... SELECT is unsafe because the order in which rows are retrieved by the SELE<...>
use constant  ER_BINLOG_UNSAFE_CREATE_IGNORE_SELECT             => 1717; # CREATE... IGNORE SELECT is unsafe because the order in which rows are retrieved by th<...>
use constant  ER_BINLOG_UNSAFE_CREATE_REPLACE_SELECT            => 1718; # CREATE... REPLACE SELECT is unsafe because the order in which rows are retrieved by t<...>
use constant  ER_BINLOG_UNSAFE_UPDATE_IGNORE                    => 1719; # UPDATE IGNORE is unsafe because the order in which rows are updated determines which <...>
#             ER_UNUSED_15                                      => 1720; # You should never see it
#             ER_UNUSED_16                                      => 1721; # You should never see it
use constant  ER_BINLOG_UNSAFE_WRITE_AUTOINC_SELECT             => 1722; # Statements writing to a table with an auto-increment column after selecting from anot<...>
use constant  ER_BINLOG_UNSAFE_CREATE_SELECT_AUTOINC            => 1723; # CREATE TABLE... SELECT...  on a table with an auto-increment column is unsafe because<...>
use constant  ER_BINLOG_UNSAFE_INSERT_TWO_KEYS                  => 1724; # INSERT... ON DUPLICATE KEY UPDATE  on a table with more than one UNIQUE KEY is unsafe
use constant  ER_UNUSED_28                                      => 1725; # You should never see it
use constant  ER_VERS_NOT_ALLOWED                               => 1726; # Not allowed for system-versioned table %`s.%`s
use constant  ER_BINLOG_UNSAFE_AUTOINC_NOT_FIRST                => 1727; # INSERT into autoincrement field which is not the first part in the composed primary k<...>
use constant  ER_CANNOT_LOAD_FROM_TABLE_V2                      => 1728; # Cannot load from %s.%s. The table is probably corrupted
use constant  ER_MASTER_DELAY_VALUE_OUT_OF_RANGE                => 1729; # The requested value %lu for the master delay exceeds the maximum %lu
use constant  ER_ONLY_FD_AND_RBR_EVENTS_ALLOWED_IN_BINLOG_STATEMENT => 1730; # Only Format_description_log_event and row events are allowed in BINLOG statements (bu<...>
use constant  ER_PARTITION_EXCHANGE_DIFFERENT_OPTION            => 1731; # Non matching attribute '%-.64s' between partition and table
use constant  ER_PARTITION_EXCHANGE_PART_TABLE                  => 1732; # Table to exchange with partition is partitioned: '%-.64s'
use constant  ER_PARTITION_EXCHANGE_TEMP_TABLE                  => 1733; # Table to exchange with partition is temporary: '%-.64s'
use constant  ER_PARTITION_INSTEAD_OF_SUBPARTITION              => 1734; # Subpartitioned table, use subpartition instead of partition
use constant  ER_UNKNOWN_PARTITION                              => 1735; # Unknown partition '%-.64s' in table '%-.64s'
use constant  ER_TABLES_DIFFERENT_METADATA                      => 1736; # Tables have different definitions
use constant  ER_ROW_DOES_NOT_MATCH_PARTITION                   => 1737; # Found a row that does not match the partition
use constant  ER_BINLOG_CACHE_SIZE_GREATER_THAN_MAX             => 1738; # Option binlog_cache_size (%lu) is greater than max_binlog_cache_size (%lu); setting b<...>
use constant  ER_WARN_INDEX_NOT_APPLICABLE                      => 1739; # Cannot use %-.64s access on index '%-.64s' due to type or collation conversion on fie<...>
use constant  ER_PARTITION_EXCHANGE_FOREIGN_KEY                 => 1740; # Table to exchange with partition has foreign key references: '%-.64s'
use constant  ER_NO_SUCH_KEY_VALUE                              => 1741; # Key value '%-.192s' was not found in table '%-.192s.%-.192s'
use constant  ER_VALUE_TOO_LONG                                 => 1742; # Too long value for '%s'
use constant  ER_NETWORK_READ_EVENT_CHECKSUM_FAILURE            => 1743; # Replication event checksum verification failed while reading from network
use constant  ER_BINLOG_READ_EVENT_CHECKSUM_FAILURE             => 1744; # Replication event checksum verification failed while reading from a log file
use constant  ER_BINLOG_STMT_CACHE_SIZE_GREATER_THAN_MAX        => 1745; # Option binlog_stmt_cache_size (%lu) is greater than max_binlog_stmt_cache_size (%lu);<...>
use constant  ER_CANT_UPDATE_TABLE_IN_CREATE_TABLE_SELECT       => 1746; # Can't update table '%-.192s' while '%-.192s' is being created
use constant  ER_PARTITION_CLAUSE_ON_NONPARTITIONED             => 1747; # PARTITION () clause on non partitioned table
use constant  ER_ROW_DOES_NOT_MATCH_GIVEN_PARTITION_SET         => 1748; # Found a row not matching the given partition set
#             ER_UNUSED_5                                       => 1749; # You should never see it
use constant  ER_CHANGE_RPL_INFO_REPOSITORY_FAILURE             => 1750; # Failure while changing the type of replication repository: %s
use constant  ER_WARNING_NOT_COMPLETE_ROLLBACK_WITH_CREATED_TEMP_TABLE => 1751; # The creation of some temporary tables could not be rolled back
use constant  ER_WARNING_NOT_COMPLETE_ROLLBACK_WITH_DROPPED_TEMP_TABLE => 1752; # Some temporary tables were dropped, but these operations could not be rolled back
use constant  ER_MTS_FEATURE_IS_NOT_SUPPORTED                   => 1753; # %s is not supported in multi-threaded slave mode. %s
use constant  ER_MTS_UPDATED_DBS_GREATER_MAX                    => 1754; # The number of modified databases exceeds the maximum %d; the database names will not <...>
use constant  ER_MTS_CANT_PARALLEL                              => 1755; # Cannot execute the current event group in the parallel mode. Encountered event %s, re<...>
use constant  ER_MTS_INCONSISTENT_DATA                          => 1756; # %s
use constant  ER_FULLTEXT_NOT_SUPPORTED_WITH_PARTITIONING       => 1757; # FULLTEXT index is not supported for partitioned tables
use constant  ER_DA_INVALID_CONDITION_NUMBER                    => 1758; # Invalid condition number
use constant  ER_INSECURE_PLAIN_TEXT                            => 1759; # Sending passwords in plain text without SSL/TLS is extremely insecure
use constant  ER_INSECURE_CHANGE_MASTER                         => 1760; # Storing MariaDB user name or password information in the master.info repository is no<...>
use constant  ER_FOREIGN_DUPLICATE_KEY_WITH_CHILD_INFO          => 1761; # Foreign key constraint for table '%.192s', record '%-.192s' would lead to a duplicate<...>
use constant  ER_FOREIGN_DUPLICATE_KEY_WITHOUT_CHILD_INFO       => 1762; # Foreign key constraint for table '%.192s', record '%-.192s' would lead to a duplicate<...>
use constant  ER_SQLTHREAD_WITH_SECURE_SLAVE                    => 1763; # Setting authentication options is not possible when only the Slave SQL Thread is bein<...>
use constant  ER_TABLE_HAS_NO_FT                                => 1764; # The table does not have FULLTEXT index to support this query
use constant  ER_VARIABLE_NOT_SETTABLE_IN_SF_OR_TRIGGER         => 1765; # The system variable %.200s cannot be set in stored functions or triggers
use constant  ER_VARIABLE_NOT_SETTABLE_IN_TRANSACTION           => 1766; # The system variable %.200s cannot be set when there is an ongoing transaction
use constant  ER_GTID_NEXT_IS_NOT_IN_GTID_NEXT_LIST             => 1767; # The system variable @@SESSION.GTID_NEXT has the value %.200s, which is not listed in <...>
use constant  ER_CANT_CHANGE_GTID_NEXT_IN_TRANSACTION_WHEN_GTID_NEXT_LIST_IS_NULL => 1768; # When @@SESSION.GTID_NEXT_LIST == NULL, the system variable @@SESSION.GTID_NEXT cannot<...>
use constant  ER_SET_STATEMENT_CANNOT_INVOKE_FUNCTION           => 1769; # The statement 'SET %.200s' cannot invoke a stored function
use constant  ER_GTID_NEXT_CANT_BE_AUTOMATIC_IF_GTID_NEXT_LIST_IS_NON_NULL => 1770; # The system variable @@SESSION.GTID_NEXT cannot be 'AUTOMATIC' when @@SESSION.GTID_NEX<...>
use constant  ER_SKIPPING_LOGGED_TRANSACTION                    => 1771; # Skipping transaction %.200s because it has already been executed and logged
use constant  ER_MALFORMED_GTID_SET_SPECIFICATION               => 1772; # Malformed GTID set specification '%.200s'
use constant  ER_MALFORMED_GTID_SET_ENCODING                    => 1773; # Malformed GTID set encoding
use constant  ER_MALFORMED_GTID_SPECIFICATION                   => 1774; # Malformed GTID specification '%.200s'
use constant  ER_GNO_EXHAUSTED                                  => 1775; # Impossible to generate Global Transaction Identifier: the integer component reached t<...>
use constant  ER_BAD_SLAVE_AUTO_POSITION                        => 1776; # Parameters MASTER_LOG_FILE, MASTER_LOG_POS, RELAY_LOG_FILE and RELAY_LOG_POS cannot b<...>
use constant  ER_AUTO_POSITION_REQUIRES_GTID_MODE_ON            => 1777; # CHANGE MASTER TO MASTER_AUTO_POSITION = 1 can only be executed when GTID_MODE = ON
use constant  ER_CANT_DO_IMPLICIT_COMMIT_IN_TRX_WHEN_GTID_NEXT_IS_SET => 1778; # Cannot execute statements with implicit commit inside a transaction when GTID_NEXT !=<...>
use constant  ER_GTID_MODE_2_OR_3_REQUIRES_ENFORCE_GTID_CONSISTENCY_ON => 1779; # GTID_MODE = ON or GTID_MODE = UPGRADE_STEP_2 requires ENFORCE_GTID_CONSISTENCY = 1
use constant  ER_GTID_MODE_REQUIRES_BINLOG                      => 1780; # GTID_MODE = ON or UPGRADE_STEP_1 or UPGRADE_STEP_2 requires --log-bin and --log-slave<...>
use constant  ER_CANT_SET_GTID_NEXT_TO_GTID_WHEN_GTID_MODE_IS_OFF => 1781; # GTID_NEXT cannot be set to UUID:NUMBER when GTID_MODE = OFF
use constant  ER_CANT_SET_GTID_NEXT_TO_ANONYMOUS_WHEN_GTID_MODE_IS_ON => 1782; # GTID_NEXT cannot be set to ANONYMOUS when GTID_MODE = ON
use constant  ER_CANT_SET_GTID_NEXT_LIST_TO_NON_NULL_WHEN_GTID_MODE_IS_OFF => 1783; # GTID_NEXT_LIST cannot be set to a non-NULL value when GTID_MODE = OFF
use constant  ER_FOUND_GTID_EVENT_WHEN_GTID_MODE_IS_OFF         => 1784; # Found a Gtid_log_event or Previous_gtids_log_event when GTID_MODE = OFF
use constant  ER_GTID_UNSAFE_NON_TRANSACTIONAL_TABLE            => 1785; # When ENFORCE_GTID_CONSISTENCY = 1, updates to non-transactional tables can only be do<...>
use constant  ER_GTID_UNSAFE_CREATE_SELECT                      => 1786; # CREATE TABLE ... SELECT is forbidden when ENFORCE_GTID_CONSISTENCY = 1
use constant  ER_GTID_UNSAFE_CREATE_DROP_TEMPORARY_TABLE_IN_TRANSACTION => 1787; # When ENFORCE_GTID_CONSISTENCY = 1, the statements CREATE TEMPORARY TABLE and DROP TEM<...>
use constant  ER_GTID_MODE_CAN_ONLY_CHANGE_ONE_STEP_AT_A_TIME   => 1788; # The value of GTID_MODE can only change one step at a time: OFF <-> UPGRADE_STEP_1 <-><...>
use constant  ER_MASTER_HAS_PURGED_REQUIRED_GTIDS               => 1789; # The slave is connecting using CHANGE MASTER TO MASTER_AUTO_POSITION = 1, but the mast<...>
use constant  ER_CANT_SET_GTID_NEXT_WHEN_OWNING_GTID            => 1790; # GTID_NEXT cannot be changed by a client that owns a GTID. The client owns %s. Ownersh<...>
use constant  ER_UNKNOWN_EXPLAIN_FORMAT                         => 1791; # Unknown %s format name: '%s'
use constant  ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION          => 1792; # Cannot execute statement in a READ ONLY transaction
use constant  ER_TOO_LONG_TABLE_PARTITION_COMMENT               => 1793; # Comment for table partition '%-.64s' is too long (max = %lu)
use constant  ER_SLAVE_CONFIGURATION                            => 1794; # Slave is not configured or failed to initialize properly. You must at least set --ser<...>
use constant  ER_INNODB_FT_LIMIT                                => 1795; # InnoDB presently supports one FULLTEXT index creation at a time
use constant  ER_INNODB_NO_FT_TEMP_TABLE                        => 1796; # Cannot create FULLTEXT index on temporary InnoDB table
use constant  ER_INNODB_FT_WRONG_DOCID_COLUMN                   => 1797; # Column '%-.192s' is of wrong type for an InnoDB FULLTEXT index
use constant  ER_INNODB_FT_WRONG_DOCID_INDEX                    => 1798; # Index '%-.192s' is of wrong type for an InnoDB FULLTEXT index
use constant  ER_INNODB_ONLINE_LOG_TOO_BIG                      => 1799; # Creating index '%-.192s' required more than 'innodb_online_alter_log_max_size' bytes <...>
use constant  ER_UNKNOWN_ALTER_ALGORITHM                        => 1800; # Unknown ALGORITHM '%s'
use constant  ER_UNKNOWN_ALTER_LOCK                             => 1801; # Unknown LOCK type '%s'
use constant  ER_MTS_CHANGE_MASTER_CANT_RUN_WITH_GAPS           => 1802; # CHANGE MASTER cannot be executed when the slave was stopped with an error or killed i<...>
use constant  ER_MTS_RECOVERY_FAILURE                           => 1803; # Cannot recover after SLAVE errored out in parallel execution mode. Additional error m<...>
use constant  ER_MTS_RESET_WORKERS                              => 1804; # Cannot clean up worker info tables. Additional error messages can be found in the Mar<...>
use constant  ER_COL_COUNT_DOESNT_MATCH_CORRUPTED_V2            => 1805; # Column count of %s.%s is wrong. Expected %d, found %d. The table is probably corrupted
use constant  ER_SLAVE_SILENT_RETRY_TRANSACTION                 => 1806; # Slave must silently retry current transaction
#             ER_UNUSED_22                                      => 1807; # You should never see it
use constant  ER_TABLE_SCHEMA_MISMATCH                          => 1808; # Schema mismatch (%s)
use constant  ER_TABLE_IN_SYSTEM_TABLESPACE                     => 1809; # Table %-.192s in system tablespace
use constant  ER_IO_READ_ERROR                                  => 1810; # IO Read error: (%lu, %s) %s
use constant  ER_IO_WRITE_ERROR                                 => 1811; # IO Write error: (%lu, %s) %s
use constant  ER_TABLESPACE_MISSING                             => 1812; # Tablespace is missing for table '%-.192s'
use constant  ER_TABLESPACE_EXISTS                              => 1813; # Tablespace for table '%-.192s' exists. Please DISCARD the tablespace before IMPORT
use constant  ER_TABLESPACE_DISCARDED                           => 1814; # Tablespace has been discarded for table %`s
use constant  ER_INTERNAL_ERROR                                 => 1815; # Internal error: %-.192s
use constant  ER_INNODB_IMPORT_ERROR                            => 1816; # ALTER TABLE '%-.192s' IMPORT TABLESPACE failed with error %lu : '%s'
use constant  ER_INNODB_INDEX_CORRUPT                           => 1817; # Index corrupt: %s
use constant  ER_INVALID_YEAR_COLUMN_LENGTH                     => 1818; # YEAR(%lu) column type is deprecated. Creating YEAR(4) column instead
use constant  ER_NOT_VALID_PASSWORD                             => 1819; # Your password does not satisfy the current policy requirements
use constant  ER_MUST_CHANGE_PASSWORD                           => 1820; # You must SET PASSWORD before executing this statement
use constant  ER_FK_NO_INDEX_CHILD                              => 1821; # Failed to add the foreign key constaint. Missing index for constraint '%s' in the foreign table '%s'
use constant  ER_FK_NO_INDEX_PARENT                             => 1822; # Failed to add the foreign key constaint. Missing index for constraint '%s' in the referenced table '%s'
use constant  ER_FK_FAIL_ADD_SYSTEM                             => 1823; # Failed to add the foreign key constraint '%s' to system tables
use constant  ER_FK_CANNOT_OPEN_PARENT                          => 1824; # Failed to open the referenced table '%s'
use constant  ER_FK_INCORRECT_OPTION                            => 1825; # Failed to add the foreign key constraint on table '%s'. Incorrect options in FOREIGN <...>
use constant  ER_DUP_CONSTRAINT_NAME                            => 1826; # Duplicate %s constraint name '%s'
use constant  ER_PASSWORD_FORMAT                                => 1827; # The password hash doesn't have the expected format. Check if the correct password alg<...>
use constant  ER_FK_COLUMN_CANNOT_DROP                          => 1828; # Cannot drop column '%-.192s': needed in a foreign key constraint '%-.192s'
use constant  ER_FK_COLUMN_CANNOT_DROP_CHILD                    => 1829; # Cannot drop column '%-.192s': needed in a foreign key constraint '%-.192s' of table %<...>
use constant  ER_FK_COLUMN_NOT_NULL                             => 1830; # Column '%-.192s' cannot be NOT NULL: needed in a foreign key constraint '%-.192s' SET NULL
use constant  ER_DUP_INDEX                                      => 1831; # Duplicate index %`s. This is deprecated and will be disallowed in a future release
use constant  ER_FK_COLUMN_CANNOT_CHANGE                        => 1832; # Cannot change column '%-.192s': used in a foreign key constraint '%-.192s'
use constant  ER_FK_COLUMN_CANNOT_CHANGE_CHILD                  => 1833; # Cannot change column '%-.192s': used in a foreign key constraint '%-.192s' of table '%-.192s'
use constant  ER_FK_CANNOT_DELETE_PARENT                        => 1834; # Cannot delete rows from table which is parent in a foreign key constraint '%-.192s' o<...>
use constant  ER_MALFORMED_PACKET                               => 1835; # Malformed communication packet
use constant  ER_READ_ONLY_MODE                                 => 1836; # Running in read-only mode
use constant  ER_GTID_NEXT_TYPE_UNDEFINED_GROUP                 => 1837; # When GTID_NEXT is set to a GTID, you must explicitly set it again after a COMMIT or R<...>
use constant  ER_VARIABLE_NOT_SETTABLE_IN_SP                    => 1838; # The system variable %.200s cannot be set in stored procedures
use constant  ER_CANT_SET_GTID_PURGED_WHEN_GTID_MODE_IS_OFF     => 1839; # GTID_PURGED can only be set when GTID_MODE = ON
use constant  ER_CANT_SET_GTID_PURGED_WHEN_GTID_EXECUTED_IS_NOT_EMPTY => 1840; # GTID_PURGED can only be set when GTID_EXECUTED is empty
use constant  ER_CANT_SET_GTID_PURGED_WHEN_OWNED_GTIDS_IS_NOT_EMPTY => 1841; # GTID_PURGED can only be set when there are no ongoing transactions (not even in other<...>
use constant  ER_GTID_PURGED_WAS_CHANGED                        => 1842; # GTID_PURGED was changed from '%s' to '%s'
use constant  ER_GTID_EXECUTED_WAS_CHANGED                      => 1843; # GTID_EXECUTED was changed from '%s' to '%s'
use constant  ER_BINLOG_STMT_MODE_AND_NO_REPL_TABLES            => 1844; # Cannot execute statement: impossible to write to binary log since BINLOG_FORMAT = STA<...>
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED                  => 1845; # %s is not supported for this operation. Try %s
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON           => 1846; # %s is not supported. Reason: %s. Try %s
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_COPY      => 1847; # COPY algorithm requires a lock
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_PARTITION => 1848; # Partition specific operations do not yet support LOCK/ALGORITHM
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_FK_RENAME => 1849; # Columns participating in a foreign key are renamed
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_COLUMN_TYPE => 1850; # Cannot change column type
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_FK_CHECK  => 1851; # Adding foreign keys needs foreign_key_checks=OFF
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_IGNORE    => 1852; # Creating unique indexes with IGNORE requires COPY algorithm to remove duplicate rows
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_NOPK      => 1853; # Dropping a primary key is not allowed without also adding a new primary key
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_AUTOINC   => 1854; # Adding an auto-increment column requires a lock
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_HIDDEN_FTS => 1855; # Cannot replace hidden FTS_DOC_ID with a user-visible one
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_CHANGE_FTS => 1856; # Cannot drop or rename FTS_DOC_ID
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_FTS       => 1857; # Fulltext index creation requires a lock
use constant  ER_SQL_SLAVE_SKIP_COUNTER_NOT_SETTABLE_IN_GTID_MODE => 1858; # sql_slave_skip_counter can not be set when the server is running with GTID_MODE = ON.<...>
use constant  ER_DUP_UNKNOWN_IN_INDEX                           => 1859; # Duplicate entry for key '%-.192s'
use constant  ER_IDENT_CAUSES_TOO_LONG_PATH                     => 1860; # Long database name and identifier for object resulted in path length exceeding %d cha<...>
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_NOT_NULL  => 1861; # cannot convert NULL to non-constant DEFAULT
use constant  ER_MUST_CHANGE_PASSWORD_LOGIN                     => 1862; # Your password has expired. To log in you must change it using a client that supports <...>
use constant  ER_ROW_IN_WRONG_PARTITION                         => 1863; # Found a row in wrong partition %s
use constant  ER_MTS_EVENT_BIGGER_PENDING_JOBS_SIZE_MAX         => 1864; # Cannot schedule event %s, relay-log name %s, position %s to Worker thread because its<...>
use constant  ER_INNODB_NO_FT_USES_PARSER                       => 1865; # Cannot CREATE FULLTEXT INDEX WITH PARSER on InnoDB table
use constant  ER_BINLOG_LOGICAL_CORRUPTION                      => 1866; # The binary log file '%s' is logically corrupted: %s
use constant  ER_WARN_PURGE_LOG_IN_USE                          => 1867; # file %s was not purged because it was being read by %d thread(s), purged only %d out <...>
use constant  ER_WARN_PURGE_LOG_IS_ACTIVE                       => 1868; # file %s was not purged because it is the active log file
use constant  ER_AUTO_INCREMENT_CONFLICT                        => 1869; # Auto-increment value in UPDATE conflicts with internally generated values
use constant  WARN_ON_BLOCKHOLE_IN_RBR                          => 1870; # Row events are not logged for %s statements that modify BLACKHOLE tables in row forma<...>
use constant  ER_SLAVE_MI_INIT_REPOSITORY                       => 1871; # Slave failed to initialize master info structure from the repository
use constant  ER_SLAVE_RLI_INIT_REPOSITORY                      => 1872; # Slave failed to initialize relay log info structure from the repository
use constant  ER_ACCESS_DENIED_CHANGE_USER_ERROR                => 1873; # Access denied trying to change to user '%-.48s'@'%-.64s' (using password: %s). Discon<...>
use constant  ER_INNODB_READ_ONLY                               => 1874; # InnoDB is in read only mode
use constant  ER_STOP_SLAVE_SQL_THREAD_TIMEOUT                  => 1875; # STOP SLAVE command execution is incomplete: Slave SQL thread got the stop signal, thr<...>
use constant  ER_STOP_SLAVE_IO_THREAD_TIMEOUT                   => 1876; # STOP SLAVE command execution is incomplete: Slave IO thread got the stop signal, thre<...>
use constant  ER_TABLE_CORRUPT                                  => 1877; # Operation cannot be performed. The table '%-.64s.%-.64s' is missing, corrupt or conta<...>
use constant  ER_TEMP_FILE_WRITE_FAILURE                        => 1878; # Temporary file write failure
use constant  ER_INNODB_FT_AUX_NOT_HEX_ID                       => 1879; # Upgrade index name failed, please use create index(alter table) algorithm copy to reb<...>
#   constant  ER_LAST_MYSQL_ERROR_MESSAGE                       => 1880; # "
#
# As of 2022-07-16, 10.10, 1881..1899 are illegal codes
# ...
#   constant  ER_UNUSED_18                                      => 1900; # "
use constant  ER_VIRTUAL_COLUMN_FUNCTION_IS_NOT_ALLOWED         => 1901; # Function or expression '%s' cannot be used in the %s clause of %`s
#   constant  ER_UNUSED_19                                      => 1902; # "
use constant  ER_PRIMARY_KEY_BASED_ON_GENERATED_COLUMN          => 1903; # Primary key cannot be defined upon a generated column
use constant  ER_KEY_BASED_ON_GENERATED_VIRTUAL_COLUMN          => 1904; # Key/Index cannot be defined on a virtual generated column
use constant  ER_WRONG_FK_OPTION_FOR_GENERATED_COLUMN           => 1905; # Cannot define foreign key with %s clause on a generated column
use constant  ER_WARNING_NON_DEFAULT_VALUE_FOR_GENERATED_COLUMN => 1906; # The value specified for generated column '%s' in table '%s' has been ignored
use constant  ER_UNSUPPORTED_ACTION_ON_GENERATED_COLUMN         => 1907; # This is not yet supported for generated columns
#   constant  ER_UNUSED_20                                      => 1908; #
#   constant  ER_UNUSED_21                                      => 1909; #
use constant  ER_UNSUPPORTED_ENGINE_FOR_GENERATED_COLUMNS       => 1910; # %s storage engine does not support generated columns
use constant  ER_UNKNOWN_OPTION                                 => 1911; # Unknown option '%-.64s'
use constant  ER_BAD_OPTION_VALUE                               => 1912; # Incorrect value '%-.64T' for option '%-.64s'
#   constant  ER_UNUSED_6                                       => 1913; # You should never see it
#   constant  ER_UNUSED_7                                       => 1914; # You should never see it
#   constant  ER_UNUSED_8                                       => 1915; # You should never see it
use constant  ER_DATA_OVERFLOW                                  => 1916; # Got overflow when converting '%-.128s' to %-.32s. Value truncated
use constant  ER_DATA_TRUNCATED                                 => 1917; # Truncated value '%-.128s' when converting to %-.32s
use constant  ER_BAD_DATA                                       => 1918; # Encountered illegal value '%-.128s' when converting to %-.32s
use constant  ER_DYN_COL_WRONG_FORMAT                           => 1919; # Encountered illegal format of dynamic column string
use constant  ER_DYN_COL_IMPLEMENTATION_LIMIT                   => 1920; # Dynamic column implementation limit reached
use constant  ER_DYN_COL_DATA                                   => 1921; # Illegal value used as argument of dynamic column function
use constant  ER_DYN_COL_WRONG_CHARSET                          => 1922; # Dynamic column contains unknown character set
use constant  ER_ILLEGAL_SUBQUERY_OPTIMIZER_SWITCHES            => 1923; # At least one of the 'in_to_exists' or 'materialization' optimizer_switch flags must b<...>
use constant  ER_QUERY_CACHE_IS_DISABLED                        => 1924; # Query cache is disabled (resize or similar command in progress); repeat this command later
use constant  ER_QUERY_CACHE_IS_GLOBALY_DISABLED                => 1925; # Query cache is globally disabled and you can't enable it only for this session
use constant  ER_VIEW_ORDERBY_IGNORED                           => 1926; # View '%-.192s'.'%-.192s' ORDER BY clause ignored because there is other ORDER BY clau<...>
use constant  ER_CONNECTION_KILLED                              => 1927; # Connection was killed
#   constant  ER_UNUSED_12                                      => 1928; # You should never see it
use constant  ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_SKIP_REPLICATION => 1929; # Cannot modify @@session.skip_replication inside a transaction
use constant  ER_STORED_FUNCTION_PREVENTS_SWITCH_SKIP_REPLICATION => 1930; # Cannot modify @@session.skip_replication inside a stored function or trigger
use constant  ER_QUERY_EXCEEDED_ROWS_EXAMINED_LIMIT             => 1931; # Query execution was interrupted. The query examined at least %llu rows, which exceeds<...>
use constant  ER_NO_SUCH_TABLE_IN_ENGINE                        => 1932; # Table '%-.192s.%-.192s' doesn't exist in engine
use constant  ER_TARGET_NOT_EXPLAINABLE                         => 1933; # Target is not running an EXPLAINable command
use constant  ER_CONNECTION_ALREADY_EXISTS                      => 1934; # Connection '%.*s' conflicts with existing connection '%.*s'
use constant  ER_MASTER_LOG_PREFIX                              => 1935; # !!! NOT MAPPED !!! # Master '%.*s':
use constant  ER_CANT_START_STOP_SLAVE                          => 1936; # Can't %s SLAVE '%.*s'
use constant  ER_SLAVE_STARTED                                  => 1937; # SLAVE '%.*s' started
use constant  ER_SLAVE_STOPPED                                  => 1938; # SLAVE '%.*s' stopped
use constant  ER_SQL_DISCOVER_ERROR                             => 1939; # Engine %s failed to discover table %`-.192s.%`-.192s with '%s'
use constant  ER_FAILED_GTID_STATE_INIT                         => 1940; # Failed initializing replication GTID state
use constant  ER_INCORRECT_GTID_STATE                           => 1941; # Could not parse GTID list
use constant  ER_CANNOT_UPDATE_GTID_STATE                       => 1942; # Could not update replication slave gtid state
use constant  ER_DUPLICATE_GTID_DOMAIN                          => 1943; # GTID %u-%u-%llu and %u-%u-%llu conflict (duplicate domain id %u)
use constant  ER_GTID_OPEN_TABLE_FAILED                         => 1944; # Failed to open %s.%s
use constant  ER_GTID_POSITION_NOT_FOUND_IN_BINLOG              => 1945; # Connecting slave requested to start from GTID %u-%u-%llu, which is not in the master'<...>
use constant  ER_CANNOT_LOAD_SLAVE_GTID_STATE                   => 1946; # Failed to load replication slave GTID position from table %s.%s
use constant  ER_MASTER_GTID_POS_CONFLICTS_WITH_BINLOG          => 1947; # Specified GTID %u-%u-%llu conflicts with the binary log which contains a more recent <...>
use constant  ER_MASTER_GTID_POS_MISSING_DOMAIN                 => 1948; # Specified value for @@gtid_slave_pos contains no value for replication domain %u. Thi<...>
use constant  ER_UNTIL_REQUIRES_USING_GTID                      => 1949; # START SLAVE UNTIL master_gtid_pos requires that slave is using GTID
use constant  ER_GTID_STRICT_OUT_OF_ORDER                       => 1950; # An attempt was made to binlog GTID %u-%u-%llu which would create an out-of-order sequ<...>
use constant  ER_GTID_START_FROM_BINLOG_HOLE                    => 1951; # The binlog on the master is missing the GTID %u-%u-%llu requested by the slave (even <...>
use constant  ER_SLAVE_UNEXPECTED_MASTER_SWITCH                 => 1952; # Unexpected GTID received from master after reconnect. This normally indicates that th<...>
use constant  ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_GTID_DOMAIN_ID_SEQ_NO => 1953; # Cannot modify @@session.gtid_domain_id or @@session.gtid_seq_no inside a transaction
use constant  ER_STORED_FUNCTION_PREVENTS_SWITCH_GTID_DOMAIN_ID_SEQ_NO => 1954; # Cannot modify @@session.gtid_domain_id or @@session.gtid_seq_no inside a stored funct<...>
use constant  ER_GTID_POSITION_NOT_FOUND_IN_BINLOG2             => 1955; # Connecting slave requested to start from GTID %u-%u-%llu, which is not in the master'<...>
use constant  ER_BINLOG_MUST_BE_EMPTY                           => 1956; # This operation is not allowed if any GTID has been logged to the binary log. Run RESE<...>
use constant  ER_NO_SUCH_QUERY                                  => 1957; # Unknown query id: %lld
use constant  ER_BAD_BASE64_DATA                                => 1958; # Bad base64 data as position %u
use constant  ER_INVALID_ROLE                                   => 1959; # Invalid role specification %`s
use constant  ER_INVALID_CURRENT_USER                           => 1960; # The current user is invalid
use constant  ER_CANNOT_GRANT_ROLE                              => 1961; # Cannot grant role '%s' to: %s
use constant  ER_CANNOT_REVOKE_ROLE                             => 1962; # Cannot revoke role '%s' from: %s
use constant  ER_CHANGE_SLAVE_PARALLEL_THREADS_ACTIVE           => 1963; # Cannot change @@slave_parallel_threads while another change is in progress
use constant  ER_PRIOR_COMMIT_FAILED                            => 1964; # Commit failed due to failure of an earlier commit on which this one depends
use constant  ER_IT_IS_A_VIEW                                   => 1965; # '%-.192s' is a view
use constant  ER_SLAVE_SKIP_NOT_IN_GTID                         => 1966; # When using parallel replication and GTID with multiple replication domains, @@sql_sla<...>
use constant  ER_TABLE_DEFINITION_TOO_BIG                       => 1967; # The definition for table %`s is too big
use constant  ER_PLUGIN_INSTALLED                               => 1968; # Plugin '%-.192s' already installed
use constant  ER_STATEMENT_TIMEOUT                              => 1969; # Query execution was interrupted (max_statement_time exceeded)
use constant  ER_SUBQUERIES_NOT_SUPPORTED                       => 1970; # %s does not support subqueries or stored functions
use constant  ER_SET_STATEMENT_NOT_SUPPORTED                    => 1971; # The system variable %.200s cannot be set in SET STATEMENT.
#   constant  ER_UNUSED_9                                       => 1972; # You should never see it
use constant  ER_USER_CREATE_EXISTS                             => 1973; # Can't create user '%-.64s'@'%-.64s'; it already exists
use constant  ER_USER_DROP_EXISTS                               => 1974; # Can't drop user '%-.64s'@'%-.64s'; it doesn't exist
use constant  ER_ROLE_CREATE_EXISTS                             => 1975; # Can't create role '%-.64s'; it already exists
use constant  ER_ROLE_DROP_EXISTS                               => 1976; # Can't drop role '%-.64s'; it doesn't exist
use constant  ER_CANNOT_CONVERT_CHARACTER                       => 1977; # Cannot convert '%s' character 0x%-.64s to '%s'
use constant  ER_INVALID_DEFAULT_VALUE_FOR_FIELD                => 1978; # Incorrect default value '%-.128T' for column '%.192s'
use constant  ER_KILL_QUERY_DENIED_ERROR                        => 1979; # You are not owner of query %lu
use constant  ER_NO_EIS_FOR_FIELD                               => 1980; # Engine-independent statistics are not collected for column '%s'
use constant  ER_WARN_AGGFUNC_DEPENDENCE                        => 1981; # Aggregate function '%-.192s)' of SELECT #%d belongs to SELECT #%d
use constant  WARN_INNODB_PARTITION_OPTION_IGNORED              => 1982; # <%-.64s> option ignored for InnoDB partition

# As of 2022-07-16, 10.10, 1983..1999 are illegal codes

# 2xxx are client codes, perror doesn't show them

use constant  ER_CONNECTION_ERROR                               => 2002;
use constant  ER_CONN_HOST_ERROR                                => 2003;
use constant  ER_SERVER_GONE_ERROR                              => 2006;
use constant  ER_SERVER_LOST                                    => 2013;
use constant  CR_COMMANDS_OUT_OF_SYNC                           => 2014;  # Caused by old DBD::mysql
use constant  ER_SERVER_LOST_EXTENDED                           => 2055;

use constant  ER_FILE_CORRUPT                                   => 3000; # File %s is corrupted
use constant  ER_ERROR_ON_MASTER                                => 3001; # Query partially completed on the master (error on master: %d) and was aborted. There <...>
use constant  ER_INCONSISTENT_ERROR                             => 3002; # Query caused different errors on master and slave. Error on master: message (format)=<...>
use constant  ER_STORAGE_ENGINE_NOT_LOADED                      => 3003; # Storage engine for table '%s'.'%s' is not loaded.
use constant  ER_GET_STACKED_DA_WITHOUT_ACTIVE_HANDLER          => 3004; # GET STACKED DIAGNOSTICS when handler not active
use constant  ER_WARN_LEGACY_SYNTAX_CONVERTED                   => 3005; # %s is no longer supported. The statement was converted to %s.
use constant  ER_BINLOG_UNSAFE_FULLTEXT_PLUGIN                  => 3006; # Statement is unsafe because it uses a fulltext parser plugin which may not return the<...>
use constant  ER_CANNOT_DISCARD_TEMPORARY_TABLE                 => 3007; # Cannot DISCARD/IMPORT tablespace associated with temporary table
use constant  ER_FK_DEPTH_EXCEEDED                              => 3008; # Foreign key cascade delete/update exceeds max depth of %d.
use constant  ER_COL_COUNT_DOESNT_MATCH_PLEASE_UPDATE_V2        => 3009; # Column count of %s.%s is wrong. Expected %d, found %d. Created with MariaDB %d, now r<...>
use constant  ER_WARN_TRIGGER_DOESNT_HAVE_CREATED               => 3010; # Trigger %s.%s.%s does not have CREATED attribute.
use constant  ER_REFERENCED_TRG_DOES_NOT_EXIST_MYSQL            => 3011; # Referenced trigger '%s' for the given action time and event type does not exist.
use constant  ER_EXPLAIN_NOT_SUPPORTED                          => 3012; # EXPLAIN FOR CONNECTION command is supported only for SELECT/UPDATE/INSERT/DELETE/REPLACE
use constant  ER_INVALID_FIELD_SIZE                             => 3013; # Invalid size for column '%-.192s'.
use constant  ER_MISSING_HA_CREATE_OPTION                       => 3014; # Table storage engine '%-.64s' found required create option missing
use constant  ER_ENGINE_OUT_OF_MEMORY                           => 3015; # Out of memory in storage engine '%-.64s'.
use constant  ER_PASSWORD_EXPIRE_ANONYMOUS_USER                 => 3016; # The password for anonymous user cannot be expired.
use constant  ER_SLAVE_SQL_THREAD_MUST_STOP                     => 3017; # This operation cannot be performed with a running slave sql thread; run STOP SLAVE SQ<...>
use constant  ER_NO_FT_MATERIALIZED_SUBQUERY                    => 3018; # Cannot create FULLTEXT index on materialized subquery
use constant  ER_INNODB_UNDO_LOG_FULL                           => 3019; # Undo Log error: %s
use constant  ER_INVALID_ARGUMENT_FOR_LOGARITHM                 => 3020; # Invalid argument for logarithm
use constant  ER_SLAVE_CHANNEL_IO_THREAD_MUST_STOP              => 3021; # This operation cannot be performed with a running slave io thread; run STOP SLAVE IO_<...>
use constant  ER_WARN_OPEN_TEMP_TABLES_MUST_BE_ZERO             => 3022; # This operation may not be safe when the slave has temporary tables. The tables will b<...>
use constant  ER_WARN_ONLY_MASTER_LOG_FILE_NO_POS               => 3023; # CHANGE MASTER TO with a MASTER_LOG_FILE clause but no MASTER_LOG_POS clause may not b<...>
use constant  ER_QUERY_TIMEOUT                                  => 3024; # Query execution was interrupted, maximum statement execution time exceeded
use constant  ER_NON_RO_SELECT_DISABLE_TIMER                    => 3025; # Select is not a read only statement, disabling timer
use constant  ER_DUP_LIST_ENTRY                                 => 3026; # Duplicate entry '%-.192s'.
use constant  ER_SQL_MODE_NO_EFFECT                             => 3027; # '%s' mode no longer has any effect. Use STRICT_ALL_TABLES or STRICT_TRANS_TABLES instead.
use constant  ER_AGGREGATE_ORDER_FOR_UNION                      => 3028; # Expression #%u of ORDER BY contains aggregate function and applies to a UNION
use constant  ER_AGGREGATE_ORDER_NON_AGG_QUERY                  => 3029; # Expression #%u of ORDER BY contains aggregate function and applies to the result of a<...>
use constant  ER_SLAVE_WORKER_STOPPED_PREVIOUS_THD_ERROR        => 3030; # Slave worker has stopped after at least one previous worker encountered an error when<...>
use constant  ER_DONT_SUPPORT_SLAVE_PRESERVE_COMMIT_ORDER       => 3031; # slave_preserve_commit_order is not supported %s.
use constant  ER_SERVER_OFFLINE_MODE                            => 3032; # The server is currently in offline mode
use constant  ER_GIS_DIFFERENT_SRIDS                            => 3033; # Binary geometry function %s given two geometries of different srids: %u and %u, which<...>
use constant  ER_GIS_UNSUPPORTED_ARGUMENT                       => 3034; # Calling geometry function %s with unsupported types of arguments.
use constant  ER_GIS_UNKNOWN_ERROR                              => 3035; # Unknown GIS error occurred in function %s.
use constant  ER_GIS_UNKNOWN_EXCEPTION                          => 3036; # Unknown exception caught in GIS function %s.
use constant  ER_GIS_INVALID_DATA                               => 3037; # Invalid GIS data provided to function %s.
use constant  ER_BOOST_GEOMETRY_EMPTY_INPUT_EXCEPTION           => 3038; # The geometry has no data in function %s.
use constant  ER_BOOST_GEOMETRY_CENTROID_EXCEPTION              => 3039; # Unable to calculate centroid because geometry is empty in function %s.
use constant  ER_BOOST_GEOMETRY_OVERLAY_INVALID_INPUT_EXCEPTION => 3040; # Geometry overlay calculation error: geometry data is invalid in function %s.
use constant  ER_BOOST_GEOMETRY_TURN_INFO_EXCEPTION             => 3041; # Geometry turn info calculation error: geometry data is invalid in function %s.
use constant  ER_BOOST_GEOMETRY_SELF_INTERSECTION_POINT_EXCEPTION => 3042; # Analysis procedures of intersection points interrupted unexpectedly in function %s.
use constant  ER_BOOST_GEOMETRY_UNKNOWN_EXCEPTION               => 3043; # Unknown exception thrown in function %s.
use constant  ER_STD_BAD_ALLOC_ERROR                            => 3044; # Memory allocation error: %-.256s in function %s.
use constant  ER_STD_DOMAIN_ERROR                               => 3045; # Domain error: %-.256s in function %s.
use constant  ER_STD_LENGTH_ERROR                               => 3046; # Length error: %-.256s in function %s.
use constant  ER_STD_INVALID_ARGUMENT                           => 3047; # Invalid argument error: %-.256s in function %s.
use constant  ER_STD_OUT_OF_RANGE_ERROR                         => 3048; # Out of range error: %-.256s in function %s.
use constant  ER_STD_OVERFLOW_ERROR                             => 3049; # Overflow error: %-.256s in function %s.
use constant  ER_STD_RANGE_ERROR                                => 3050; # Range error: %-.256s in function %s.
use constant  ER_STD_UNDERFLOW_ERROR                            => 3051; # Underflow error: %-.256s in function %s.
use constant  ER_STD_LOGIC_ERROR                                => 3052; # Logic error: %-.256s in function %s.
use constant  ER_STD_RUNTIME_ERROR                              => 3053; # Runtime error: %-.256s in function %s.
use constant  ER_STD_UNKNOWN_EXCEPTION                          => 3054; # Unknown exception: %-.384s in function %s.
use constant  ER_GIS_DATA_WRONG_ENDIANESS                       => 3055; # Geometry byte string must be little endian.
use constant  ER_CHANGE_MASTER_PASSWORD_LENGTH                  => 3056; # The password provided for the replication user exceeds the maximum length of 32 characters
use constant  ER_USER_LOCK_WRONG_NAME                           => 3057; # Incorrect user-level lock name '%-.192s'.
use constant  ER_USER_LOCK_DEADLOCK                             => 3058; # Deadlock found when trying to get user-level lock; try rolling back transaction/relea<...>
use constant  ER_REPLACE_INACCESSIBLE_ROWS                      => 3059; # REPLACE cannot be executed as it requires deleting rows that are not in the view
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_GIS       => 3060; # Do not support online operation on table with GIS index
# 3061 ... 3099 are MySQL codes, but not MariaDB
#--- Some MySQL 5.7 errors ---
use constant  ER_FIELD_IN_ORDER_NOT_SELECT                      => 3065;
use constant  ER_INVALID_JSON_TEXT                              => 3140;
use constant  ER_INVALID_JSON_TEXT_IN_PARAM                     => 3141;
use constant  ER_INVALID_JSON_BINARY_DATA                       => 3142;
use constant  ER_INVALID_JSON_PATH                              => 3143;
use constant  ER_INVALID_JSON_CHARSET                           => 3144;
use constant  ER_INVALID_JSON_CHARSET_IN_FUNCTION               => 3145;
use constant  ER_INVALID_TYPE_FOR_JSON                          => 3146;
use constant  ER_INVALID_CAST_TO_JSON                           => 3147;
use constant  ER_INVALID_JSON_PATH_CHARSET                      => 3148;
use constant  ER_INVALID_JSON_PATH_WILDCARD                     => 3149;
use constant  ER_JSON_VALUE_TOO_BIG                             => 3150;
use constant  ER_JSON_KEY_TOO_BIG                               => 3151;
use constant  ER_JSON_USED_AS_KEY                               => 3152;
use constant  ER_JSON_VACUOUS_PATH                              => 3153;
use constant  ER_JSON_BAD_ONE_OR_ALL_ARG                        => 3154;
use constant  ER_NUMERIC_JSON_VALUE_OUT_OF_RANGE                => 3155;
use constant  ER_INVALID_JSON_VALUE_FOR_CAST                    => 3156;
use constant  ER_JSON_DOCUMENT_TOO_DEEP                         => 3157;
use constant  ER_JSON_DOCUMENT_NULL_KEY                         => 3158;
#--- end of MySQL 5.7 errors ---
# 3159..3999 are MySQL codes, but not MariaDB

#   constant  ER_UNUSED_26                                      => 4000; # This error never happens
#   constant  ER_UNUSED_27                                      => 4001; # This error never happens
use constant  ER_WITH_COL_WRONG_LIST                            => 4002; # WITH column list and SELECT field list have different column counts
use constant  ER_TOO_MANY_DEFINITIONS_IN_WITH_CLAUSE            => 4003; # Too many WITH elements in WITH clause
use constant  ER_DUP_QUERY_NAME                                 => 4004; # Duplicate query name %`-.64s in WITH clause
use constant  ER_RECURSIVE_WITHOUT_ANCHORS                      => 4005; # No anchors for recursive WITH element '%s'
use constant  ER_UNACCEPTABLE_MUTUAL_RECURSION                  => 4006; # Unacceptable mutual recursion with anchored table '%s'
use constant  ER_REF_TO_RECURSIVE_WITH_TABLE_IN_DERIVED         => 4007; # Reference to recursive WITH table '%s' in materialized derived
use constant  ER_NOT_STANDARD_COMPLIANT_RECURSIVE               => 4008; # Restrictions imposed on recursive definitions are violated for table '%s'
use constant  ER_WRONG_WINDOW_SPEC_NAME                         => 4009; # Window specification with name '%s' is not defined
use constant  ER_DUP_WINDOW_NAME                                => 4010; # Multiple window specifications with the same name '%s'
use constant  ER_PARTITION_LIST_IN_REFERENCING_WINDOW_SPEC      => 4011; # Window specification referencing another one '%s' cannot contain partition list
use constant  ER_ORDER_LIST_IN_REFERENCING_WINDOW_SPEC          => 4012; # Referenced window specification '%s' already contains order list
use constant  ER_WINDOW_FRAME_IN_REFERENCED_WINDOW_SPEC         => 4013; # Referenced window specification '%s' cannot contain window frame
use constant  ER_BAD_COMBINATION_OF_WINDOW_FRAME_BOUND_SPECS    => 4014; # Unacceptable combination of window frame bound specifications
use constant  ER_WRONG_PLACEMENT_OF_WINDOW_FUNCTION             => 4015; # Window function is allowed only in SELECT list and ORDER BY clause
use constant  ER_WINDOW_FUNCTION_IN_WINDOW_SPEC                 => 4016; # Window function is not allowed in window specification
use constant  ER_NOT_ALLOWED_WINDOW_FRAME                       => 4017; # Window frame is not allowed with '%s'
use constant  ER_NO_ORDER_LIST_IN_WINDOW_SPEC                   => 4018; # No order list in window specification for '%s'
use constant  ER_RANGE_FRAME_NEEDS_SIMPLE_ORDERBY               => 4019; # RANGE-type frame requires ORDER BY clause with single sort key
use constant  ER_WRONG_TYPE_FOR_ROWS_FRAME                      => 4020; # Integer is required for ROWS-type frame
use constant  ER_WRONG_TYPE_FOR_RANGE_FRAME                     => 4021; # Numeric datatype is required for RANGE-type frame
use constant  ER_FRAME_EXCLUSION_NOT_SUPPORTED                  => 4022; # Frame exclusion is not supported yet
use constant  ER_WINDOW_FUNCTION_DONT_HAVE_FRAME                => 4023; # This window function may not have a window frame
use constant  ER_INVALID_NTILE_ARGUMENT                         => 4024; # Argument of NTILE must be greater than 0
use constant  ER_CONSTRAINT_FAILED                              => 4025; # CONSTRAINT %`s failed for %`-.192s.%`-.192s
use constant  ER_EXPRESSION_IS_TOO_BIG                          => 4026; # Expression in the %s clause is too big
use constant  ER_ERROR_EVALUATING_EXPRESSION                    => 4027; # Got an error evaluating stored expression %s
use constant  ER_CALCULATING_DEFAULT_VALUE                      => 4028; # Got an error when calculating default value for %`s
use constant  ER_EXPRESSION_REFERS_TO_UNINIT_FIELD              => 4029; # Expression for field %`-.64s is referring to uninitialized field %`s
use constant  ER_PARTITION_DEFAULT_ERROR                        => 4030; # Only one DEFAULT partition allowed
use constant  ER_REFERENCED_TRG_DOES_NOT_EXIST                  => 4031; # Referenced trigger '%s' for the given action time and event type does not exist
use constant  ER_INVALID_DEFAULT_PARAM                          => 4032; # Default/ignore value is not supported for such parameter usage
use constant  ER_BINLOG_NON_SUPPORTED_BULK                      => 4033; # Only row based replication supported for bulk operations
use constant  ER_BINLOG_UNCOMPRESS_ERROR                        => 4034; # Uncompress the compressed binlog failed
use constant  ER_JSON_BAD_CHR                                   => 4035; # Broken JSON string in argument %d to function '%s' at position %d
use constant  ER_JSON_NOT_JSON_CHR                              => 4036; # Character disallowed in JSON in argument %d to function '%s' at position %d
use constant  ER_JSON_EOS                                       => 4037; # Unexpected end of JSON text in argument %d to function '%s'
use constant  ER_JSON_SYNTAX                                    => 4038; # Syntax error in JSON text in argument %d to function '%s' at position %d
use constant  ER_JSON_ESCAPING                                  => 4039; # Incorrect escaping in JSON text in argument %d to function '%s' at position %d
use constant  ER_JSON_DEPTH                                     => 4040; # Limit of %d on JSON nested structures depth is reached in argument %d to function '%s' at position %d
use constant  ER_JSON_PATH_EOS                                  => 4041; # Unexpected end of JSON path in argument %d to function '%s'
use constant  ER_JSON_PATH_SYNTAX                               => 4042; # Syntax error in JSON path in argument %d to function '%s' at position %d
use constant  ER_JSON_PATH_DEPTH                                => 4043; # Limit of %d on JSON path depth is reached in argument %d to function '%s' at position %d
use constant  ER_JSON_PATH_NO_WILDCARD                          => 4044; # Wildcards or range in JSON path not allowed in argument %d to function '%s'
use constant  ER_JSON_PATH_ARRAY                                => 4045; # JSON path should end with an array identifier in argument %d to function '%s'
use constant  ER_JSON_ONE_OR_ALL                                => 4046; # Argument 2 to function '%s' must be "one" or "all"
use constant  ER_UNSUPPORT_COMPRESSED_TEMPORARY_TABLE           => 4047; # InnoDB refuses to write tables with ROW_FORMAT=COMPRESSED or KEY_BLOCK_SIZE
use constant  ER_GEOJSON_INCORRECT                              => 4048; # Incorrect GeoJSON format specified for st_geomfromgeojson function.
use constant  ER_GEOJSON_TOO_FEW_POINTS                         => 4049; # Incorrect GeoJSON format - too few points for linestring specified.
use constant  ER_GEOJSON_NOT_CLOSED                             => 4050; # Incorrect GeoJSON format - polygon not closed.
use constant  ER_JSON_PATH_EMPTY                                => 4051; # Path expression '$' is not allowed in argument %d to function '%s'.
use constant  ER_SLAVE_SAME_ID                                  => 4052; # A slave with the same server_uuid/server_id as this slave has connected to the master
use constant  ER_FLASHBACK_NOT_SUPPORTED                        => 4053; # Flashback does not support %s %s
use constant  ER_KEYS_OUT_OF_ORDER                              => 4054; # Keys are out order during bulk load
use constant  ER_OVERLAPPING_KEYS                               => 4055; # Bulk load rows overlap existing rows
use constant  ER_REQUIRE_ROW_BINLOG_FORMAT                      => 4056; # Can't execute updates on master with binlog_format != ROW.
use constant  ER_ISOLATION_MODE_NOT_SUPPORTED                   => 4057; # MyRocks supports only READ COMMITTED and REPEATABLE READ isolation levels
use constant  ER_ON_DUPLICATE_DISABLED                          => 4058; # When unique checking is disabled in MyRocks, INSERT,UPDATE,LOAD statements with claus<...>
use constant  ER_UPDATES_WITH_CONSISTENT_SNAPSHOT               => 4059; # Can't execute updates when you started a transaction with START TRANSACTION WITH CONS<...>
use constant  ER_ROLLBACK_ONLY                                  => 4060; # This transaction was rolled back and cannot be committed. Only supported operation is<...>
use constant  ER_ROLLBACK_TO_SAVEPOINT                          => 4061; # MyRocks currently does not support ROLLBACK TO SAVEPOINT if modifying rows.
use constant  ER_ISOLATION_LEVEL_WITH_CONSISTENT_SNAPSHOT       => 4062; # Only REPEATABLE READ isolation level is supported for START TRANSACTION WITH CONSISTE<...>
use constant  ER_UNSUPPORTED_COLLATION                          => 4063; # Unsupported collation on string indexed column %s.%s Use binary collation (%s).
use constant  ER_METADATA_INCONSISTENCY                         => 4064; # Table '%s' does not exist, but metadata information exists inside MyRocks. This is a <...>
use constant  ER_CF_DIFFERENT                                   => 4065; # Column family ('%s') flag (%d) is different from an existing flag (%d). Assign a new <...>
use constant  ER_RDB_TTL_DURATION_FORMAT                        => 4066; # TTL duration (%s) in MyRocks must be an unsigned non-null 64-bit integer.
use constant  ER_RDB_STATUS_GENERAL                             => 4067; # Status error %d received from RocksDB: %s
use constant  ER_RDB_STATUS_MSG                                 => 4068; # %s, Status error %d received from RocksDB: %s
use constant  ER_RDB_TTL_UNSUPPORTED                            => 4069; # TTL support is currently disabled when table has a hidden PK.
use constant  ER_RDB_TTL_COL_FORMAT                             => 4070; # TTL column (%s) in MyRocks must be an unsigned non-null 64-bit integer, exist inside <...>
use constant  ER_PER_INDEX_CF_DEPRECATED                        => 4071; # The per-index column family option has been deprecated
use constant  ER_KEY_CREATE_DURING_ALTER                        => 4072; # MyRocks failed creating new key definitions during alter.
use constant  ER_SK_POPULATE_DURING_ALTER                       => 4073; # MyRocks failed populating secondary key during alter.
use constant  ER_SUM_FUNC_WITH_WINDOW_FUNC_AS_ARG               => 4074; # Window functions can not be used as arguments to group functions.
use constant  ER_NET_OK_PACKET_TOO_LARGE                        => 4075; # OK packet too large
use constant  ER_GEOJSON_EMPTY_COORDINATES                      => 4076; # Incorrect GeoJSON format - empty 'coordinates' array.
use constant  ER_MYROCKS_CANT_NOPAD_COLLATION                   => 4077; # MyRocks doesn't currently support collations with "No pad" attribute.
use constant  ER_ILLEGAL_PARAMETER_DATA_TYPES2_FOR_OPERATION    => 4078; # Illegal parameter data types %s and %s for operation '%s'
use constant  ER_ILLEGAL_PARAMETER_DATA_TYPE_FOR_OPERATION      => 4079; # Illegal parameter data type %s for operation '%s'
use constant  ER_WRONG_PARAMCOUNT_TO_CURSOR                     => 4080; # Incorrect parameter count to cursor '%-.192s'
use constant  ER_UNKNOWN_STRUCTURED_VARIABLE                    => 4081; # Unknown structured system variable or ROW routine variable '%-.*s'
use constant  ER_ROW_VARIABLE_DOES_NOT_HAVE_FIELD               => 4082; # Row variable '%-.192s' does not have a field '%-.192s'
use constant  ER_END_IDENTIFIER_DOES_NOT_MATCH                  => 4083; # END identifier '%-.192s' does not match '%-.192s'
use constant  ER_SEQUENCE_RUN_OUT                               => 4084; # Sequence '%-.64s.%-.64s' has run out
use constant  ER_SEQUENCE_INVALID_DATA                          => 4085; # Sequence '%-.64s.%-.64s' has out of range value for options
use constant  ER_SEQUENCE_INVALID_TABLE_STRUCTURE               => 4086; # Sequence '%-.64s.%-.64s' table structure is invalid (%s)
use constant  ER_SEQUENCE_ACCESS_ERROR                          => 4087; # Sequence '%-.64s.%-.64s' access error
use constant  ER_SEQUENCE_BINLOG_FORMAT                         => 4088; # Sequences requires binlog_format mixed or row
use constant  ER_NOT_SEQUENCE                                   => 4089; # '%-.64s.%-.64s' is not a SEQUENCE
use constant  ER_NOT_SEQUENCE2                                  => 4090; # '%-.192s' is not a SEQUENCE
use constant  ER_UNKNOWN_SEQUENCES                              => 4091; # Unknown SEQUENCE: '%-.300s'
use constant  ER_UNKNOWN_VIEW                                   => 4092; # Unknown VIEW: '%-.300s'
use constant  ER_WRONG_INSERT_INTO_SEQUENCE                     => 4093; # Wrong INSERT into a SEQUENCE <...>
use constant  ER_SP_STACK_TRACE                                 => 4094; # At line %u in %s
use constant  ER_PACKAGE_ROUTINE_IN_SPEC_NOT_DEFINED_IN_BODY    => 4095; # Subroutine '%-.192s' is declared in the package specification but is not defined in the package body
use constant  ER_PACKAGE_ROUTINE_FORWARD_DECLARATION_NOT_DEFINED => 4096; # Subroutine '%-.192s' has a forward declaration but is not defined
use constant  ER_COMPRESSED_COLUMN_USED_AS_KEY                  => 4097; # Compressed column '%-.192s' can't be used in key specification
use constant  ER_UNKNOWN_COMPRESSION_METHOD                     => 4098; # Unknown compression method: %s
use constant  ER_WRONG_NUMBER_OF_VALUES_IN_TVC                  => 4099; # The used table value constructor has a different number of values
use constant  ER_FIELD_REFERENCE_IN_TVC                         => 4100; # Field reference '%-.192s' can't be used in table value constructor
use constant  ER_WRONG_TYPE_FOR_PERCENTILE_FUNC                 => 4101; # Numeric datatype is required for %s function
use constant  ER_ARGUMENT_NOT_CONSTANT                          => 4102; # Argument to the %s function is not a constant for a partition
use constant  ER_ARGUMENT_OUT_OF_RANGE                          => 4103; # Argument to the %s function does not belong to the range [0,1]
use constant  ER_WRONG_TYPE_OF_ARGUMENT                         => 4104; # %s function only accepts arguments that can be converted to numerical types
use constant  ER_NOT_AGGREGATE_FUNCTION                         => 4105; # Aggregate specific instruction (FETCH GROUP NEXT ROW) used in a wrong context
use constant  ER_INVALID_AGGREGATE_FUNCTION                     => 4106; # Aggregate specific instruction(FETCH GROUP NEXT ROW) missing from the aggregate function
use constant  ER_INVALID_VALUE_TO_LIMIT                         => 4107; # Limit only accepts integer values
use constant  ER_INVISIBLE_NOT_NULL_WITHOUT_DEFAULT             => 4108; # Invisible column %`s must have a default value
use constant  ER_UPDATE_INFO_WITH_SYSTEM_VERSIONING             => 4109; # !!! NOT MAPPED !!! # Rows matched: %ld  Changed: %ld  Inserted: %ld  Warnings: %ld
use constant  ER_VERS_FIELD_WRONG_TYPE                          => 4110; # %`s must be of type %s for system-versioned table %`s
use constant  ER_VERS_ENGINE_UNSUPPORTED                        => 4111; # Transaction-precise system versioning for %`s is not supported
#   constant  ER_UNUSED_23                                      => 4112; # You should never see it
use constant  ER_PARTITION_WRONG_TYPE                           => 4113; # Wrong partitioning type, expected type: %`s
use constant  WARN_VERS_PART_FULL                               => 4114; # Versioned table %`s.%`s: last HISTORY partition (%`s) is out of %s, need more HISTORY partitions
use constant  WARN_VERS_PARAMETERS                              => 4115; # Maybe missing parameters: %s
use constant  ER_VERS_DROP_PARTITION_INTERVAL                   => 4116; # Can only drop oldest partitions when rotating by INTERVAL
#   constant  ER_UNUSED_25                                      => 4117; # You should never see it
use constant  WARN_VERS_PART_NON_HISTORICAL                     => 4118; # Partition %`s contains non-historical data
use constant  ER_VERS_ALTER_NOT_ALLOWED                         => 4119; # Not allowed for system-versioned %`s.%`s. Change @@system_versioning_alter_history to proceed with ALTER
use constant  ER_VERS_ALTER_ENGINE_PROHIBITED                   => 4120; # Not allowed for system-versioned %`s.%`s. Change to/from native system versioning engine is not supported
use constant  ER_VERS_RANGE_PROHIBITED                          => 4121; # SYSTEM_TIME range selector is not allowed
use constant  ER_CONFLICTING_FOR_SYSTEM_TIME                    => 4122; # Conflicting FOR SYSTEM_TIME clauses in WITH RECURSIVE
use constant  ER_VERS_TABLE_MUST_HAVE_COLUMNS                   => 4123; # Table %`s must have at least one versioned column
use constant  ER_VERS_NOT_VERSIONED                             => 4124; # Table %`s is not system-versioned
use constant  ER_MISSING                                        => 4125; # Wrong parameters for %`s: missing '%s' ### Our note: Missing "with system versioning" or "AS ROW START" / "AS ROW END"
use constant  ER_VERS_PERIOD_COLUMNS                            => 4126; # PERIOD FOR SYSTEM_TIME must use columns %`s and %`s
use constant  ER_PART_WRONG_VALUE                               => 4127; # Wrong parameters for partitioned %`s: wrong value for '%s'
use constant  ER_VERS_WRONG_PARTS                               => 4128; # Wrong partitions for %`s: must have at least one HISTORY and exactly one last CURRENT
use constant  ER_VERS_NO_TRX_ID                                 => 4129; # TRX_ID %llu not found in `mysql.transaction_registry`
use constant  ER_VERS_ALTER_SYSTEM_FIELD                        => 4130; # Can not change system versioning field %`s
use constant  ER_DROP_VERSIONING_SYSTEM_TIME_PARTITION          => 4131; # Can not DROP SYSTEM VERSIONING for table %`s partitioned BY SYSTEM_TIME
use constant  ER_VERS_DB_NOT_SUPPORTED                          => 4132; # System-versioned tables in the %`s database are not supported
use constant  ER_VERS_TRT_IS_DISABLED                           => 4133; # Transaction registry is disabled
use constant  ER_VERS_DUPLICATE_ROW_START_END                   => 4134; # Duplicate ROW %s column %`s
use constant  ER_VERS_ALREADY_VERSIONED                         => 4135; # Table %`s is already system-versioned
#   constant  ER_UNUSED_24                                      => 4136; # You should never see it
use constant  ER_VERS_NOT_SUPPORTED                             => 4137; # System-versioned tables do not support %s
use constant  ER_VERS_TRX_PART_HISTORIC_ROW_NOT_SUPPORTED       => 4138; # Transaction-precise system-versioned tables do not support partitioning by ROW START or ROW END
use constant  ER_INDEX_FILE_FULL                                => 4139; # The index file for table '%-.192s' is full
use constant  ER_UPDATED_COLUMN_ONLY_ONCE                       => 4140; # The column %`s.%`s cannot be changed more than once in a single UPDATE statement
use constant  ER_EMPTY_ROW_IN_TVC                               => 4141; # Row with no elements is not allowed in table value constructor in this context
use constant  ER_VERS_QUERY_IN_PARTITION                        => 4142; # SYSTEM_TIME partitions in table %`s does not support historical query
use constant  ER_KEY_DOESNT_SUPPORT                             => 4143; # %s index %`s does not support this operation
use constant  ER_ALTER_OPERATION_TABLE_OPTIONS_NEED_REBUILD     => 4144; # Changing table options requires the table to be rebuilt
use constant  ER_BACKUP_LOCK_IS_ACTIVE                          => 4145; # Can't execute the command as you have a BACKUP STAGE active
use constant  ER_BACKUP_NOT_RUNNING                             => 4146; # You must start backup with "BACKUP STAGE START"
use constant  ER_BACKUP_WRONG_STAGE                             => 4147; # Backup stage '%s' is same or before current backup stage '%s'
use constant  ER_BACKUP_STAGE_FAILED                            => 4148; # Backup stage '%s' failed
use constant  ER_BACKUP_UNKNOWN_STAGE                           => 4149; # Unknown backup stage: '%s'. Stage should be one of START, FLUSH, BLOCK_DDL, BLOCK_COMMIT or END
use constant  ER_USER_IS_BLOCKED                                => 4150; # User is blocked because of too many credential errors; unblock with 'FLUSH PRIVILEGES'
use constant  ER_ACCOUNT_HAS_BEEN_LOCKED                        => 4151; # Access denied, this account is locked
use constant  ER_PERIOD_TEMPORARY_NOT_ALLOWED                   => 4152; # Application-time period table cannot be temporary
use constant  ER_PERIOD_TYPES_MISMATCH                          => 4153; # Fields of PERIOD FOR %`s have different types
use constant  ER_MORE_THAN_ONE_PERIOD                           => 4154; # Cannot specify more than one application-time period
use constant  ER_PERIOD_FIELD_WRONG_ATTRIBUTES                  => 4155; # Period field %`s cannot be %s
use constant  ER_PERIOD_NOT_FOUND                               => 4156; # Period %`s is not found in table
use constant  ER_PERIOD_COLUMNS_UPDATED                         => 4157; # Column %`s used in period %`s specified in update SET list
use constant  ER_PERIOD_CONSTRAINT_DROP                         => 4158; # Can't DROP CONSTRAINT `%s`. Use DROP PERIOD `%s` for this
use constant  ER_TOO_LONG_KEYPART                               => 4159; # Specified key part was too long; max key part length is %u bytes
use constant  ER_TOO_LONG_DATABASE_COMMENT                      => 4160; # Comment for database '%-.64s' is too long (max = %u)
use constant  ER_UNKNOWN_DATA_TYPE                              => 4161; # Unknown data type: '%-.64s'
use constant  ER_UNKNOWN_OPERATOR                               => 4162; # Operator does not exists: '%-.128s'
use constant  ER_WARN_HISTORY_ROW_START_TIME                    => 4163; # Table `%s.%s` history row start '%s' is later than row end '%s'
use constant  ER_PART_STARTS_BEYOND_INTERVAL                    => 4164; # %`s: STARTS is later than query time, first history partition may exceed INTERVAL value
use constant  ER_GALERA_REPLICATION_NOT_SUPPORTED               => 4165; # Galera replication not supported
use constant  ER_LOAD_INFILE_CAPABILITY_DISABLED                => 4166; # The used command is not allowed because the MariaDB server or client has disabled the<...>
use constant  ER_NO_SECURE_TRANSPORTS_CONFIGURED                => 4167; # No secure transports are configured, unable to set --require_secure_transport=ON
use constant  ER_SLAVE_IGNORED_SHARED_TABLE                     => 4168; # Slave SQL thread ignored the '%s' because table is shared
use constant  ER_NO_AUTOINCREMENT_WITH_UNIQUE                   => 4169; # AUTO_INCREMENT column %`s cannot be used in the UNIQUE index %`s
use constant  ER_KEY_CONTAINS_PERIOD_FIELDS                     => 4170; # Key %`s cannot explicitly include column %`s
use constant  ER_KEY_CANT_HAVE_WITHOUT_OVERLAPS                 => 4171; # Key %`s cannot have WITHOUT OVERLAPS
use constant  ER_NOT_ALLOWED_IN_THIS_CONTEXT                    => 4172; # '%-.128s' is not allowed in this context
use constant  ER_DATA_WAS_COMMITED_UNDER_ROLLBACK               => 4173; # Engine %s does not support rollback. Changes were committed during rollback call
use constant  ER_PK_INDEX_CANT_BE_IGNORED                       => 4174; # A primary key cannot be marked as IGNORE
use constant  ER_BINLOG_UNSAFE_SKIP_LOCKED                      => 4175; # SKIP LOCKED makes this statement unsafe
use constant  ER_JSON_TABLE_ERROR_ON_FIELD                      => 4176; # Field '%s' can't be set for JSON_TABLE '%s'.
use constant  ER_JSON_TABLE_ALIAS_REQUIRED                      => 4177; # Every table function must have an alias.
use constant  ER_JSON_TABLE_SCALAR_EXPECTED                     => 4178; # Can't store an array or an object in the scalar column '%s' of JSON_TABLE '%s'.
use constant  ER_JSON_TABLE_MULTIPLE_MATCHES                    => 4179; # Can't store multiple matches of the path in the column '%s' of JSON_TABLE '%s'.
use constant  ER_WITH_TIES_NEEDS_ORDER                          => 4180; # FETCH ... WITH TIES requires ORDER BY clause to be present
use constant  ER_REMOVED_ORPHAN_TRIGGER                         => 4181; # Dropped orphan trigger '%-.64s', originally created for table: '%-.192s'
use constant  ER_STORAGE_ENGINE_DISABLED                        => 4182; # Storage engine %s is disabled
use constant  WARN_SFORMAT_ERROR                                => 4183; # SFORMAT error: %s
use constant  ER_PARTITION_CONVERT_SUBPARTITIONED               => 4184; # Convert partition is not supported for subpartitioned table
use constant  ER_PROVIDER_NOT_LOADED                            => 4185; # MariaDB tried to use the %s, but its provider plugin is not loaded
use constant  ER_JSON_HISTOGRAM_PARSE_FAILED                    => 4186; # Failed to parse histogram for table %s.%s: %s at offset %d
use constant  ER_SF_OUT_INOUT_ARG_NOT_ALLOWED                   => 4187; # OUT or INOUT argument %d for function %s is not allowed here
use constant  ER_INCONSISTENT_SLAVE_TEMP_TABLE                  => 4188; # Replicated query '%s' table `%s.%s` can not be temporary
# 10.9 and higher
use constant  ER_VERS_HIST_PART_FAILED                          => 4189; # Versioned table %`s.%`s: adding HISTORY partition(s) failed

# Last as of 2022-07-16, 4190 is an illegal code

my %err2type = (

    CR_COMMANDS_OUT_OF_SYNC() => STATUS_ENVIRONMENT_FAILURE,

    ER_ABORTING_CONNECTION()                            => STATUS_RUNTIME_ERROR,
    ER_ACCESS_DENIED_CHANGE_USER_ERROR()                => STATUS_ACL_ERROR,
    ER_ACCESS_DENIED_ERROR()                            => STATUS_ACL_ERROR,
    ER_ACCESS_DENIED_NO_PASSWORD_ERROR()                => STATUS_ACL_ERROR,
    ER_ACCOUNT_HAS_BEEN_LOCKED()                        => STATUS_ACL_ERROR,
    ER_ADD_PARTITION_NO_NEW_PARTITION()                 => STATUS_SEMANTIC_ERROR,
    ER_ADD_PARTITION_SUBPART_ERROR()                    => STATUS_SEMANTIC_ERROR,
    ER_ADMIN_WRONG_MRG_TABLE()                          => STATUS_SEMANTIC_ERROR,
    ER_AGGREGATE_ORDER_FOR_UNION()                      => STATUS_SEMANTIC_ERROR,
    ER_AGGREGATE_ORDER_NON_AGG_QUERY()                  => STATUS_SEMANTIC_ERROR,
    ER_ALTER_FILEGROUP_FAILED()                         => STATUS_RUNTIME_ERROR,
    ER_ALTER_OPERATION_NOT_SUPPORTED()                  => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON()           => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_AUTOINC()   => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_CHANGE_FTS() => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_COLUMN_TYPE() => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_COPY()      => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_FK_CHECK()  => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_FK_RENAME() => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_FTS()       => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_GIS()       => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_HIDDEN_FTS() => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_IGNORE()    => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_NOPK()      => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_NOT_NULL()  => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON_PARTITION() => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_TABLE_OPTIONS_NEED_REBUILD()     => STATUS_RUNTIME_ERROR,
    ER_AMBIGUOUS_FIELD_TERM()                           => STATUS_SEMANTIC_ERROR,
    ER_ARGUMENT_NOT_CONSTANT()                          => STATUS_SEMANTIC_ERROR,
    ER_ARGUMENT_OUT_OF_RANGE()                          => STATUS_SEMANTIC_ERROR,
    ER_AUTOINCREMENT()                                  => STATUS_RUNTIME_ERROR,
    ER_AUTOINC_READ_FAILED()                            => STATUS_IGNORED_ERROR, # See MDEV-533 for "Failed to read auto-increment value from storage engine" on BIGINT UNSIGNED
    ER_AUTO_INCREMENT_CONFLICT()                        => STATUS_RUNTIME_ERROR,
    ER_AUTO_POSITION_REQUIRES_GTID_MODE_ON()            => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_LOCK_IS_ACTIVE()                          => STATUS_RUNTIME_ERROR,
    ER_BACKUP_NOT_RUNNING()                             => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_STAGE_FAILED()                            => STATUS_RUNTIME_ERROR,
    ER_BACKUP_UNKNOWN_STAGE()                           => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_WRONG_STAGE()                             => STATUS_SEMANTIC_ERROR,
    ER_BAD_BASE64_DATA()                                => STATUS_DATABASE_CORRUPTION,
    ER_BAD_COMBINATION_OF_WINDOW_FRAME_BOUND_SPECS()    => STATUS_SEMANTIC_ERROR,
    ER_BAD_DATA()                                       => STATUS_RUNTIME_ERROR,
    ER_BAD_DB_ERROR()                                   => STATUS_SEMANTIC_ERROR,
    ER_BAD_FIELD_ERROR()                                => STATUS_SEMANTIC_ERROR,
    ER_BAD_FT_COLUMN()                                  => STATUS_SEMANTIC_ERROR,
    ER_BAD_HOST_ERROR()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_BAD_LOG_STATEMENT()                              => STATUS_SEMANTIC_ERROR,
    ER_BAD_NULL_ERROR()                                 => STATUS_RUNTIME_ERROR,
    ER_BAD_OPTION_VALUE()                               => STATUS_SEMANTIC_ERROR,
    ER_BAD_SLAVE()                                      => STATUS_CONFIGURATION_ERROR,
    ER_BAD_SLAVE_AUTO_POSITION()                        => STATUS_SEMANTIC_ERROR,
    ER_BAD_SLAVE_UNTIL_COND()                           => STATUS_SEMANTIC_ERROR,
    ER_BAD_TABLE_ERROR()                                => STATUS_SEMANTIC_ERROR,
    ER_BASE64_DECODE_ERROR()                            => STATUS_DATABASE_CORRUPTION,
    ER_BINLOG_CACHE_SIZE_GREATER_THAN_MAX()             => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_CANT_DELETE_GTID_DOMAIN()                 => STATUS_RUNTIME_ERROR,
    ER_BINLOG_CREATE_ROUTINE_NEED_SUPER()               => STATUS_ACL_ERROR,
    ER_BINLOG_LOGICAL_CORRUPTION()                      => STATUS_DATABASE_CORRUPTION,
    ER_BINLOG_LOGGING_IMPOSSIBLE()                      => STATUS_REPLICATION_FAILURE,
    ER_BINLOG_MULTIPLE_ENGINES_AND_SELF_LOGGING_ENGINE() => STATUS_RUNTIME_ERROR,
    ER_BINLOG_MUST_BE_EMPTY()                           => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_NON_SUPPORTED_BULK()                      => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_PURGE_EMFILE()                            => STATUS_RUNTIME_ERROR,
    ER_BINLOG_PURGE_FATAL_ERR()                         => STATUS_REPLICATION_FAILURE,
    ER_BINLOG_PURGE_PROHIBITED()                        => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_READ_EVENT_CHECKSUM_FAILURE()             => STATUS_REPLICATION_FAILURE,
    ER_BINLOG_ROW_ENGINE_AND_STMT_ENGINE()              => STATUS_RUNTIME_ERROR,
    ER_BINLOG_ROW_INJECTION_AND_STMT_ENGINE()           => STATUS_RUNTIME_ERROR,
    ER_BINLOG_ROW_INJECTION_AND_STMT_MODE()             => STATUS_RUNTIME_ERROR,
    ER_BINLOG_ROW_LOGGING_FAILED()                      => STATUS_IGNORED_ERROR, # Downgraded from STATUS_REPLICATION_FAILURE due to MDEV-24959
    ER_BINLOG_ROW_MODE_AND_STMT_ENGINE()                => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_ROW_RBR_TO_SBR()                          => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_ROW_WRONG_TABLE_DEF()                     => STATUS_REPLICATION_FAILURE,
    ER_BINLOG_STMT_CACHE_SIZE_GREATER_THAN_MAX()        => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_STMT_MODE_AND_NO_REPL_TABLES()            => STATUS_RUNTIME_ERROR,
    ER_BINLOG_STMT_MODE_AND_ROW_ENGINE()                => STATUS_RUNTIME_ERROR,
    ER_BINLOG_UNCOMPRESS_ERROR()                        => STATUS_DATABASE_CORRUPTION,
    ER_BINLOG_UNSAFE_AND_STMT_ENGINE()                  => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_AUTOINC_COLUMNS()                  => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_AUTOINC_NOT_FIRST()                => STATUS_RUNTIME_ERROR,
    ER_BINLOG_UNSAFE_CREATE_IGNORE_SELECT()             => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_CREATE_REPLACE_SELECT()            => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_CREATE_SELECT_AUTOINC()            => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_FULLTEXT_PLUGIN()                  => STATUS_CONFIGURATION_ERROR,
    ER_BINLOG_UNSAFE_INSERT_DELAYED()                   => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_INSERT_IGNORE_SELECT()             => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_INSERT_SELECT_UPDATE()             => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_INSERT_TWO_KEYS()                  => STATUS_RUNTIME_ERROR,
    ER_BINLOG_UNSAFE_LIMIT()                            => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_MIXED_STATEMENT()                  => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_MULTIPLE_ENGINES_AND_SELF_LOGGING_ENGINE() => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_NONTRANS_AFTER_TRANS()             => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_REPLACE_SELECT()                   => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_ROUTINE()                          => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_SKIP_LOCKED()                      => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_STATEMENT()                        => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_SYSTEM_FUNCTION()                  => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_SYSTEM_TABLE()                     => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_SYSTEM_VARIABLE()                  => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_UDF()                              => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_UPDATE_IGNORE()                    => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_WRITE_AUTOINC_SELECT()             => STATUS_SEMANTIC_ERROR,
    ER_BLOBS_AND_NO_TERMINATED()                        => STATUS_SEMANTIC_ERROR,
    ER_BLOB_FIELD_IN_PART_FUNC_ERROR()                  => STATUS_SEMANTIC_ERROR,
    ER_BLOB_KEY_WITHOUT_LENGTH()                        => STATUS_SEMANTIC_ERROR,
    ER_BLOB_USED_AS_KEY()                               => STATUS_SEMANTIC_ERROR,
    ER_BOOST_GEOMETRY_CENTROID_EXCEPTION()              => STATUS_RUNTIME_ERROR,
    ER_BOOST_GEOMETRY_EMPTY_INPUT_EXCEPTION()           => STATUS_RUNTIME_ERROR,
    ER_BOOST_GEOMETRY_OVERLAY_INVALID_INPUT_EXCEPTION() => STATUS_RUNTIME_ERROR,
    ER_BOOST_GEOMETRY_SELF_INTERSECTION_POINT_EXCEPTION() => STATUS_RUNTIME_ERROR,
    ER_BOOST_GEOMETRY_TURN_INFO_EXCEPTION()             => STATUS_RUNTIME_ERROR,
    ER_BOOST_GEOMETRY_UNKNOWN_EXCEPTION()               => STATUS_RUNTIME_ERROR,
    ER_CALCULATING_DEFAULT_VALUE()                      => STATUS_RUNTIME_ERROR,
    ER_CANNOT_ADD_FOREIGN()                             => STATUS_RUNTIME_ERROR,
    ER_CANNOT_CONVERT_CHARACTER()                       => STATUS_RUNTIME_ERROR,
    ER_CANNOT_DISCARD_TEMPORARY_TABLE()                 => STATUS_SEMANTIC_ERROR,
    ER_CANNOT_GRANT_ROLE()                              => STATUS_ACL_ERROR,
    ER_CANNOT_LOAD_FROM_TABLE_V2()                      => STATUS_DATABASE_CORRUPTION,
    ER_CANNOT_LOAD_SLAVE_GTID_STATE()                   => STATUS_REPLICATION_FAILURE,
    ER_CANNOT_REVOKE_ROLE()                             => STATUS_ACL_ERROR,
    ER_CANNOT_UPDATE_GTID_STATE()                       => STATUS_REPLICATION_FAILURE,
    ER_CANNOT_USER()                                    => STATUS_SEMANTIC_ERROR,
    ER_CANT_ACTIVATE_LOG()                              => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_AGGREGATE_2COLLATIONS()                     => STATUS_RUNTIME_ERROR,
    ER_CANT_AGGREGATE_3COLLATIONS()                     => STATUS_RUNTIME_ERROR,
    ER_CANT_AGGREGATE_NCOLLATIONS()                     => STATUS_RUNTIME_ERROR,
    ER_CANT_CHANGE_GTID_NEXT_IN_TRANSACTION_WHEN_GTID_NEXT_LIST_IS_NULL() => STATUS_SEMANTIC_ERROR,
    ER_CANT_CHANGE_TX_ISOLATION()                       => STATUS_RUNTIME_ERROR,
    ER_CANT_CREATE_DB()                                 => STATUS_RUNTIME_ERROR,
    ER_CANT_CREATE_FEDERATED_TABLE()                    => STATUS_RUNTIME_ERROR,
    ER_CANT_CREATE_FILE()                               => STATUS_RUNTIME_ERROR,
    ER_CANT_CREATE_GEOMETRY_OBJECT()                    => STATUS_SEMANTIC_ERROR,
    ER_CANT_CREATE_HANDLER_FILE()                       => STATUS_DATABASE_CORRUPTION,
    ER_CANT_CREATE_SROUTINE()                           => STATUS_RUNTIME_ERROR,
    ER_CANT_CREATE_TABLE()                              => STATUS_RUNTIME_ERROR,
    ER_CANT_CREATE_THREAD()                             => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_CREATE_USER_WITH_GRANT()                    => STATUS_ACL_ERROR,
    ER_CANT_DELETE_FILE()                               => STATUS_RUNTIME_ERROR,
    ER_CANT_DO_IMPLICIT_COMMIT_IN_TRX_WHEN_GTID_NEXT_IS_SET() => STATUS_SEMANTIC_ERROR,
    ER_CANT_DO_THIS_DURING_AN_TRANSACTION()             => STATUS_RUNTIME_ERROR,
    ER_CANT_DROP_FIELD_OR_KEY()                         => STATUS_SEMANTIC_ERROR,
    ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION()          => STATUS_RUNTIME_ERROR,
    ER_CANT_FIND_DL_ENTRY()                             => STATUS_DATABASE_CORRUPTION,
    ER_CANT_FIND_SYSTEM_REC()                           => STATUS_DATABASE_CORRUPTION,
    ER_CANT_FIND_UDF()                                  => STATUS_CONFIGURATION_ERROR,
    ER_CANT_GET_STAT()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_GET_WD()                                    => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_INITIALIZE_UDF()                            => STATUS_DATABASE_CORRUPTION,
    ER_CANT_LOCK()                                      => STATUS_RUNTIME_ERROR,
    ER_CANT_LOCK_LOG_TABLE()                            => STATUS_SEMANTIC_ERROR,
    ER_CANT_OPEN_FILE()                                 => STATUS_RUNTIME_ERROR,
    ER_CANT_OPEN_LIBRARY()                              => STATUS_CONFIGURATION_ERROR,
    ER_CANT_READ_DIR()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_REMOVE_ALL_FIELDS()                         => STATUS_SEMANTIC_ERROR,
    ER_CANT_RENAME_LOG_TABLE()                          => STATUS_SEMANTIC_ERROR,
    ER_CANT_REOPEN_TABLE()                              => STATUS_RUNTIME_ERROR,
    ER_CANT_SET_GTID_NEXT_LIST_TO_NON_NULL_WHEN_GTID_MODE_IS_OFF() => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_GTID_NEXT_TO_ANONYMOUS_WHEN_GTID_MODE_IS_ON() => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_GTID_NEXT_TO_GTID_WHEN_GTID_MODE_IS_OFF() => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_GTID_NEXT_WHEN_OWNING_GTID()            => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_GTID_PURGED_WHEN_GTID_EXECUTED_IS_NOT_EMPTY() => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_GTID_PURGED_WHEN_GTID_MODE_IS_OFF()     => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_GTID_PURGED_WHEN_OWNED_GTIDS_IS_NOT_EMPTY() => STATUS_SEMANTIC_ERROR,
    ER_CANT_SET_WD()                                    => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_START_STOP_SLAVE()                          => STATUS_REPLICATION_FAILURE,
    ER_CANT_UPDATE_TABLE_IN_CREATE_TABLE_SELECT()       => STATUS_RUNTIME_ERROR,
    ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG()            => STATUS_SEMANTIC_ERROR,
    ER_CANT_UPDATE_WITH_READLOCK()                      => STATUS_RUNTIME_ERROR,
    ER_CANT_USE_OPTION_HERE()                           => STATUS_SEMANTIC_ERROR,
    ER_CANT_WRITE_LOCK_LOG_TABLE()                      => STATUS_SEMANTIC_ERROR,
    ER_CF_DIFFERENT()                                   => STATUS_DATABASE_CORRUPTION,
    ER_CHANGE_MASTER_PASSWORD_LENGTH()                  => STATUS_SEMANTIC_ERROR,
    ER_CHANGE_RPL_INFO_REPOSITORY_FAILURE()             => STATUS_REPLICATION_FAILURE,
    ER_CHANGE_SLAVE_PARALLEL_THREADS_ACTIVE()           => STATUS_SEMANTIC_ERROR,
    ER_CHECKREAD()                                      => STATUS_RUNTIME_ERROR,
    ER_CHECK_NOT_IMPLEMENTED()                          => STATUS_UNSUPPORTED,
    ER_CHECK_NO_SUCH_TABLE()                            => STATUS_SEMANTIC_ERROR,
    ER_COALESCE_ONLY_ON_HASH_PARTITION()                => STATUS_SEMANTIC_ERROR,
    ER_COALESCE_PARTITION_NO_PARTITION()                => STATUS_SEMANTIC_ERROR,
    ER_COLLATION_CHARSET_MISMATCH()                     => STATUS_SEMANTIC_ERROR,
    ER_COLUMNACCESS_DENIED_ERROR()                      => STATUS_ACL_ERROR,
    ER_COL_COUNT_DOESNT_MATCH_CORRUPTED_V2()            => STATUS_DATABASE_CORRUPTION,
    ER_COL_COUNT_DOESNT_MATCH_PLEASE_UPDATE()           => STATUS_DATABASE_CORRUPTION,
    ER_COL_COUNT_DOESNT_MATCH_PLEASE_UPDATE_V2()        => STATUS_DATABASE_CORRUPTION,
    ER_COMMIT_NOT_ALLOWED_IN_SF_OR_TRG()                => STATUS_SEMANTIC_ERROR,
    ER_COMPRESSED_COLUMN_USED_AS_KEY()                  => STATUS_SEMANTIC_ERROR,
    ER_COND_ITEM_TOO_LONG()                             => STATUS_SEMANTIC_ERROR,
    ER_CONFLICTING_DECLARATIONS()                       => STATUS_SEMANTIC_ERROR,
    ER_CONFLICT_FN_PARSE_ERROR()                        => STATUS_SYNTAX_ERROR,
    ER_CONFLICTING_FOR_SYSTEM_TIME()                    => STATUS_SEMANTIC_ERROR,
    ER_CONNECTION_ALREADY_EXISTS()                      => STATUS_CRITICAL_FAILURE,
    ER_CONNECTION_ERROR()                               => STATUS_SERVER_CRASHED,
    ER_CONNECTION_KILLED()                              => STATUS_RUNTIME_ERROR,
    ER_CONNECT_TO_FOREIGN_DATA_SOURCE()                 => STATUS_RUNTIME_ERROR,
    ER_CONNECT_TO_MASTER()                              => STATUS_REPLICATION_FAILURE,
    ER_CONN_HOST_ERROR()                                => STATUS_SERVER_CRASHED,
    ER_CONSECUTIVE_REORG_PARTITIONS()                   => STATUS_SEMANTIC_ERROR,
    ER_CONSTRAINT_FAILED()                              => STATUS_RUNTIME_ERROR,
    ER_CON_COUNT_ERROR()                                => STATUS_ENVIRONMENT_FAILURE,
    ER_CORRUPT_HELP_DB()                                => STATUS_DATABASE_CORRUPTION,
    ER_CRASHED1()                                       => STATUS_IGNORED_ERROR,
    ER_CRASHED2()                                       => STATUS_IGNORED_ERROR,
    ER_CRASHED_ON_REPAIR()                              => STATUS_DATABASE_CORRUPTION,
    ER_CRASHED_ON_USAGE()                               => STATUS_DATABASE_CORRUPTION,
    ER_CREATE_DB_WITH_READ_LOCK()                       => STATUS_RUNTIME_ERROR,
    ER_CREATE_FILEGROUP_FAILED()                        => STATUS_RUNTIME_ERROR,
    ER_CUT_VALUE_GROUP_CONCAT()                         => STATUS_RUNTIME_ERROR,
    ER_CYCLIC_REFERENCE()                               => STATUS_SEMANTIC_ERROR,
    ER_DATA_OUT_OF_RANGE()                              => STATUS_RUNTIME_ERROR,
    ER_DATA_OVERFLOW()                                  => STATUS_RUNTIME_ERROR,
    ER_DATA_TOO_LONG()                                  => STATUS_RUNTIME_ERROR,
    ER_DATA_TRUNCATED()                                 => STATUS_RUNTIME_ERROR,
    ER_DATA_WAS_COMMITED_UNDER_ROLLBACK()               => STATUS_RUNTIME_ERROR,
    ER_DATETIME_FUNCTION_OVERFLOW()                     => STATUS_RUNTIME_ERROR,
    ER_DA_INVALID_CONDITION_NUMBER()                    => STATUS_SEMANTIC_ERROR,
    ER_DBACCESS_DENIED_ERROR()                          => STATUS_ACL_ERROR,
    ER_DB_CREATE_EXISTS()                               => STATUS_SEMANTIC_ERROR,
    ER_DB_DROP_DELETE()                                 => STATUS_RUNTIME_ERROR,
    ER_DB_DROP_EXISTS()                                 => STATUS_SEMANTIC_ERROR,
    ER_DB_DROP_RMDIR()                                  => STATUS_RUNTIME_ERROR,
    ER_DEBUG_SYNC_HIT_LIMIT()                           => STATUS_CONFIGURATION_ERROR,
    ER_DEBUG_SYNC_TIMEOUT()                             => STATUS_RUNTIME_ERROR,
    ER_DDL_LOG_ERROR()                                  => STATUS_DATABASE_CORRUPTION,
    ER_DELAYED_CANT_CHANGE_LOCK()                       => STATUS_RUNTIME_ERROR,
    ER_DELAYED_INSERT_TABLE_LOCKED()                    => STATUS_RUNTIME_ERROR,
    ER_DELAYED_NOT_SUPPORTED()                          => STATUS_UNSUPPORTED,
    ER_DERIVED_MUST_HAVE_ALIAS()                        => STATUS_SEMANTIC_ERROR,
    ER_DIFF_GROUPS_PROC()                               => STATUS_UNSUPPORTED,
    ER_DISK_FULL()                                      => STATUS_ENVIRONMENT_FAILURE,
    ER_DIVISION_BY_ZERO()                               => STATUS_RUNTIME_ERROR,
    ER_DONT_SUPPORT_SLAVE_PRESERVE_COMMIT_ORDER()       => STATUS_UNSUPPORTED,
    ER_DROP_DB_WITH_READ_LOCK()                         => STATUS_RUNTIME_ERROR,
    ER_DROP_FILEGROUP_FAILED()                          => STATUS_RUNTIME_ERROR,
    ER_DROP_INDEX_FK()                                  => STATUS_RUNTIME_ERROR,
    ER_DROP_LAST_PARTITION()                            => STATUS_SEMANTIC_ERROR,
    ER_DROP_PARTITION_NON_EXISTENT()                    => STATUS_SEMANTIC_ERROR,
    ER_DROP_USER()                                      => STATUS_RUNTIME_ERROR,
    ER_DROP_VERSIONING_SYSTEM_TIME_PARTITION()          => STATUS_SEMANTIC_ERROR,
    ER_DUPLICATE_GTID_DOMAIN()                          => STATUS_REPLICATION_FAILURE,
    ER_DUP_ARGUMENT()                                   => STATUS_SEMANTIC_ERROR,
    ER_DUP_CONSTRAINT_NAME()                            => STATUS_SEMANTIC_ERROR,
    ER_DUP_ENTRY()                                      => STATUS_RUNTIME_ERROR,
    ER_DUP_ENTRY_AUTOINCREMENT_CASE()                   => STATUS_RUNTIME_ERROR,
    ER_DUP_ENTRY_WITH_KEY_NAME()                        => STATUS_RUNTIME_ERROR,
    ER_DUP_FIELDNAME()                                  => STATUS_SEMANTIC_ERROR,
    ER_DUP_INDEX()                                      => STATUS_SEMANTIC_ERROR,
    ER_DUP_KEY()                                        => STATUS_RUNTIME_ERROR,
    ER_DUP_KEYNAME()                                    => STATUS_SEMANTIC_ERROR,
    ER_DUP_LIST_ENTRY()                                 => STATUS_RUNTIME_ERROR,
    ER_DUP_QUERY_NAME()                                 => STATUS_SEMANTIC_ERROR,
    ER_DUP_SIGNAL_SET()                                 => STATUS_SEMANTIC_ERROR,
    ER_DUP_UNIQUE()                                     => STATUS_RUNTIME_ERROR,
    ER_DUP_UNKNOWN_IN_INDEX()                           => STATUS_RUNTIME_ERROR,
    ER_DUP_WINDOW_NAME()                                => STATUS_SEMANTIC_ERROR,
    ER_DYN_COL_DATA()                                   => STATUS_SEMANTIC_ERROR,
    ER_DYN_COL_IMPLEMENTATION_LIMIT()                   => STATUS_RUNTIME_ERROR,
    ER_DYN_COL_WRONG_CHARSET()                          => STATUS_DATABASE_CORRUPTION,
    ER_DYN_COL_WRONG_FORMAT()                           => STATUS_SEMANTIC_ERROR,
    ER_EMPTY_QUERY()                                    => STATUS_SEMANTIC_ERROR,
    ER_EMPTY_ROW_IN_TVC()                               => STATUS_SEMANTIC_ERROR,
    ER_END_IDENTIFIER_DOES_NOT_MATCH()                  => STATUS_SEMANTIC_ERROR,
    ER_ENGINE_OUT_OF_MEMORY()                           => STATUS_ENVIRONMENT_FAILURE,
    ER_ERROR_DURING_CHECKPOINT()                        => STATUS_RUNTIME_ERROR,
    ER_ERROR_DURING_COMMIT()                            => STATUS_RUNTIME_ERROR,
    ER_ERROR_DURING_FLUSH_LOGS()                        => STATUS_RUNTIME_ERROR,
    ER_ERROR_DURING_ROLLBACK()                          => STATUS_RUNTIME_ERROR,
    ER_ERROR_EVALUATING_EXPRESSION()                    => STATUS_RUNTIME_ERROR,
    ER_ERROR_IN_TRIGGER_BODY()                          => STATUS_SYNTAX_ERROR,
    ER_ERROR_IN_UNKNOWN_TRIGGER_BODY()                  => STATUS_DATABASE_CORRUPTION,
    ER_ERROR_ON_CLOSE()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_ERROR_ON_MASTER()                                => STATUS_REPLICATION_FAILURE,
    ER_ERROR_ON_READ()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_ERROR_ON_RENAME()                                => STATUS_RUNTIME_ERROR,
    ER_ERROR_ON_WRITE()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_ERROR_WHEN_EXECUTING_COMMAND()                   => STATUS_RUNTIME_ERROR,
    ER_EVENTS_DB_ERROR()                                => STATUS_DATABASE_CORRUPTION,
    ER_EVENT_ALREADY_EXISTS()                           => STATUS_SEMANTIC_ERROR,
    ER_EVENT_CANNOT_ALTER_IN_THE_PAST()                 => STATUS_SEMANTIC_ERROR,
    ER_EVENT_CANNOT_CREATE_IN_THE_PAST()                => STATUS_SEMANTIC_ERROR,
    ER_EVENT_CANNOT_DELETE()                            => STATUS_RUNTIME_ERROR,
    ER_EVENT_CANT_ALTER()                               => STATUS_RUNTIME_ERROR,
    ER_EVENT_COMPILE_ERROR()                            => STATUS_SEMANTIC_ERROR,
    ER_EVENT_DATA_TOO_LONG()                            => STATUS_RUNTIME_ERROR,
    ER_EVENT_DOES_NOT_EXIST()                           => STATUS_SEMANTIC_ERROR,
    ER_EVENT_DROP_FAILED()                              => STATUS_RUNTIME_ERROR,
    ER_EVENT_ENDS_BEFORE_STARTS()                       => STATUS_SEMANTIC_ERROR,
    ER_EVENT_EXEC_TIME_IN_THE_PAST()                    => STATUS_SEMANTIC_ERROR,
    ER_EVENT_INTERVAL_NOT_POSITIVE_OR_TOO_BIG()         => STATUS_SEMANTIC_ERROR,
    ER_EVENT_INVALID_CREATION_CTX()                     => STATUS_SEMANTIC_ERROR,
    ER_EVENT_MODIFY_QUEUE_ERROR()                       => STATUS_RUNTIME_ERROR,
    ER_EVENT_NEITHER_M_EXPR_NOR_M_AT()                  => STATUS_SEMANTIC_ERROR,
    ER_EVENT_OPEN_TABLE_FAILED()                        => STATUS_DATABASE_CORRUPTION,
    ER_EVENT_RECURSION_FORBIDDEN()                      => STATUS_SEMANTIC_ERROR,
    ER_EVENT_SAME_NAME()                                => STATUS_SEMANTIC_ERROR,
    ER_EVENT_SET_VAR_ERROR()                            => STATUS_CRITICAL_FAILURE,
    ER_EVENT_STORE_FAILED()                             => STATUS_DATABASE_CORRUPTION,
    ER_EXCEPTIONS_WRITE_ERROR()                         => STATUS_RUNTIME_ERROR,
    ER_EXEC_STMT_WITH_OPEN_CURSOR()                     => STATUS_RUNTIME_ERROR,
    ER_EXPLAIN_NOT_SUPPORTED()                          => STATUS_UNSUPPORTED,
    ER_EXPRESSION_IS_TOO_BIG()                          => STATUS_RUNTIME_ERROR,
    ER_EXPRESSION_REFERS_TO_UNINIT_FIELD()              => STATUS_RUNTIME_ERROR,
    ER_FEATURE_DISABLED()                               => STATUS_CONFIGURATION_ERROR,
    ER_FAILED_GTID_STATE_INIT()                         => STATUS_REPLICATION_FAILURE,
    ER_FAILED_READ_FROM_PAR_FILE()                      => STATUS_RUNTIME_ERROR, # Downgraded to runtime error due to MDEV-29566
    ER_FAILED_ROUTINE_BREAK_BINLOG()                    => STATUS_REPLICATION_FAILURE,
    ER_FIELD_IN_ORDER_NOT_SELECT()                      => STATUS_SEMANTIC_ERROR,
    ER_FIELD_NOT_FOUND_PART_ERROR()                     => STATUS_SEMANTIC_ERROR,
    ER_FIELD_REFERENCE_IN_TVC()                         => STATUS_SEMANTIC_ERROR,
    ER_FIELD_TYPE_NOT_ALLOWED_AS_PARTITION_FIELD()      => STATUS_SEMANTIC_ERROR,
    ER_FIELD_SPECIFIED_TWICE()                          => STATUS_SEMANTIC_ERROR,
    ER_FILEGROUP_OPTION_ONLY_ONCE()                     => STATUS_SEMANTIC_ERROR,
    ER_FILE_CORRUPT()                                   => STATUS_DATABASE_CORRUPTION,
    ER_FILE_EXISTS_ERROR()                              => STATUS_SEMANTIC_ERROR,
    ER_FILE_NOT_FOUND()                                 => STATUS_RUNTIME_ERROR,
    ER_FILE_USED()                                      => STATUS_ENVIRONMENT_FAILURE,
    ER_FILSORT_ABORT()                                  => STATUS_RUNTIME_ERROR,
    ER_FK_CANNOT_DELETE_PARENT()                        => STATUS_RUNTIME_ERROR,
    ER_FK_CANNOT_OPEN_PARENT()                          => STATUS_RUNTIME_ERROR,
    ER_FK_COLUMN_CANNOT_CHANGE()                        => STATUS_RUNTIME_ERROR,
    ER_FK_COLUMN_CANNOT_CHANGE_CHILD()                  => STATUS_RUNTIME_ERROR,
    ER_FK_COLUMN_CANNOT_DROP()                          => STATUS_RUNTIME_ERROR,
    ER_FK_COLUMN_CANNOT_DROP_CHILD()                    => STATUS_RUNTIME_ERROR,
    ER_FK_COLUMN_NOT_NULL()                             => STATUS_RUNTIME_ERROR,
    ER_FK_DEPTH_EXCEEDED()                              => STATUS_RUNTIME_ERROR,
    ER_FK_FAIL_ADD_SYSTEM()                             => STATUS_RUNTIME_ERROR,
    ER_FK_INCORRECT_OPTION()                            => STATUS_RUNTIME_ERROR,
    ER_FK_NO_INDEX_CHILD()                              => STATUS_RUNTIME_ERROR,
    ER_FK_NO_INDEX_PARENT()                             => STATUS_RUNTIME_ERROR,
    ER_FLASHBACK_NOT_SUPPORTED()                        => STATUS_UNSUPPORTED,
    ER_FLUSH_MASTER_BINLOG_CLOSED()                     => STATUS_CONFIGURATION_ERROR,
    ER_FOUND_GTID_EVENT_WHEN_GTID_MODE_IS_OFF()         => STATUS_REPLICATION_FAILURE,
    ER_FORCING_CLOSE()                                  => STATUS_RUNTIME_ERROR,
    ER_FORBID_SCHEMA_CHANGE()                           => STATUS_ACL_ERROR,
    ER_FOREIGN_DATA_SOURCE_DOESNT_EXIST()               => STATUS_ENVIRONMENT_FAILURE,
    ER_FOREIGN_DATA_STRING_INVALID()                    => STATUS_SEMANTIC_ERROR,
    ER_FOREIGN_DATA_STRING_INVALID_CANT_CREATE()        => STATUS_SEMANTIC_ERROR,
    ER_FOREIGN_DUPLICATE_KEY_WITHOUT_CHILD_INFO()       => STATUS_RUNTIME_ERROR,
    ER_FOREIGN_DUPLICATE_KEY_WITH_CHILD_INFO()          => STATUS_RUNTIME_ERROR,
    ER_FOREIGN_KEY_ON_PARTITIONED()                     => STATUS_UNSUPPORTED,
    ER_FOREIGN_SERVER_DOESNT_EXIST()                    => STATUS_SEMANTIC_ERROR,
    ER_FOREIGN_SERVER_EXISTS()                          => STATUS_SEMANTIC_ERROR,
    ER_FORM_NOT_FOUND()                                 => STATUS_SEMANTIC_ERROR,
    ER_FPARSER_BAD_HEADER()                             => STATUS_ENVIRONMENT_FAILURE,
    ER_FPARSER_EOF_IN_COMMENT()                         => STATUS_ENVIRONMENT_FAILURE,
    ER_FPARSER_EOF_IN_UNKNOWN_PARAMETER()               => STATUS_ENVIRONMENT_FAILURE,
    ER_FPARSER_ERROR_IN_PARAMETER()                     => STATUS_CONFIGURATION_ERROR,
    ER_FPARSER_TOO_BIG_FILE()                           => STATUS_CONFIGURATION_ERROR,
    ER_FRAME_EXCLUSION_NOT_SUPPORTED()                  => STATUS_UNSUPPORTED,
    ER_FRM_UNKNOWN_TYPE()                               => STATUS_ENVIRONMENT_FAILURE,
    ER_FSEEK_FAIL()                                     => STATUS_ENVIRONMENT_FAILURE,
    ER_FT_MATCHING_KEY_NOT_FOUND()                      => STATUS_SEMANTIC_ERROR,
    ER_FULLTEXT_NOT_SUPPORTED_WITH_PARTITIONING()       => STATUS_UNSUPPORTED,
    ER_FUNCTION_NOT_DEFINED()                           => STATUS_SEMANTIC_ERROR,
    ER_FUNC_INEXISTENT_NAME_COLLISION()                 => STATUS_SEMANTIC_ERROR,
    ER_GALERA_REPLICATION_NOT_SUPPORTED()               => STATUS_CONFIGURATION_ERROR,
    ER_GEOJSON_EMPTY_COORDINATES()                      => STATUS_SEMANTIC_ERROR,
    ER_GEOJSON_INCORRECT()                              => STATUS_SEMANTIC_ERROR,
    ER_GEOJSON_NOT_CLOSED()                             => STATUS_SEMANTIC_ERROR,
    ER_GEOJSON_TOO_FEW_POINTS()                         => STATUS_SEMANTIC_ERROR,
    ER_GET_ERRMSG()                                     => STATUS_RUNTIME_ERROR,
    ER_GET_ERRNO()                                      => STATUS_RUNTIME_ERROR,
    ER_GET_TEMPORARY_ERRMSG()                           => STATUS_RUNTIME_ERROR,
    ER_GET_STACKED_DA_WITHOUT_ACTIVE_HANDLER()          => STATUS_RUNTIME_ERROR,
    ER_GIS_DATA_WRONG_ENDIANESS()                       => STATUS_RUNTIME_ERROR,
    ER_GIS_DIFFERENT_SRIDS()                            => STATUS_SEMANTIC_ERROR,
    ER_GIS_INVALID_DATA()                               => STATUS_RUNTIME_ERROR,
    ER_GIS_UNKNOWN_EXCEPTION()                          => STATUS_RUNTIME_ERROR,
    ER_GIS_UNKNOWN_ERROR()                              => STATUS_RUNTIME_ERROR,
    ER_GIS_UNSUPPORTED_ARGUMENT()                       => STATUS_UNSUPPORTED,
    ER_GLOBAL_VARIABLE()                                => STATUS_SEMANTIC_ERROR,
    ER_GNO_EXHAUSTED()                                  => STATUS_RUNTIME_ERROR,
    ER_GOT_SIGNAL()                                     => STATUS_SERVER_CRASHED,
    ER_GRANT_PLUGIN_USER_EXISTS()                       => STATUS_SEMANTIC_ERROR,
    ER_GRANT_WRONG_HOST_OR_USER()                       => STATUS_SEMANTIC_ERROR,
    ER_GTID_EXECUTED_WAS_CHANGED()                      => STATUS_RUNTIME_ERROR,
    ER_GTID_MODE_2_OR_3_REQUIRES_ENFORCE_GTID_CONSISTENCY_ON() => STATUS_SEMANTIC_ERROR,
    ER_GTID_MODE_CAN_ONLY_CHANGE_ONE_STEP_AT_A_TIME()   => STATUS_SEMANTIC_ERROR,
    ER_GTID_MODE_REQUIRES_BINLOG()                      => STATUS_CONFIGURATION_ERROR,
    ER_GTID_NEXT_CANT_BE_AUTOMATIC_IF_GTID_NEXT_LIST_IS_NON_NULL() => STATUS_SEMANTIC_ERROR,
    ER_GTID_NEXT_IS_NOT_IN_GTID_NEXT_LIST()             => STATUS_REPLICATION_FAILURE,
    ER_GTID_NEXT_TYPE_UNDEFINED_GROUP()                 => STATUS_SEMANTIC_ERROR,
    ER_GTID_OPEN_TABLE_FAILED()                         => STATUS_REPLICATION_FAILURE,
    ER_GTID_POSITION_NOT_FOUND_IN_BINLOG()              => STATUS_REPLICATION_FAILURE,
    ER_GTID_POSITION_NOT_FOUND_IN_BINLOG2()             => STATUS_REPLICATION_FAILURE,
    ER_GTID_PURGED_WAS_CHANGED()                        => STATUS_RUNTIME_ERROR,
    ER_GTID_START_FROM_BINLOG_HOLE()                    => STATUS_REPLICATION_FAILURE,
    ER_GTID_STRICT_OUT_OF_ORDER()                       => STATUS_REPLICATION_FAILURE,
    ER_GTID_UNSAFE_CREATE_DROP_TEMPORARY_TABLE_IN_TRANSACTION() => STATUS_SEMANTIC_ERROR,
    ER_GTID_UNSAFE_CREATE_SELECT()                      => STATUS_SEMANTIC_ERROR,
    ER_GTID_UNSAFE_NON_TRANSACTIONAL_TABLE()            => STATUS_SEMANTIC_ERROR,
    ER_HANDSHAKE_ERROR()                                => STATUS_ENVIRONMENT_FAILURE,
    ER_HOST_IS_BLOCKED()                                => STATUS_ENVIRONMENT_FAILURE,
    ER_HOST_NOT_PRIVILEGED()                            => STATUS_ENVIRONMENT_FAILURE,
    ER_IDENT_CAUSES_TOO_LONG_PATH()                     => STATUS_RUNTIME_ERROR,
    ER_ILLEGAL_GRANT_FOR_TABLE()                        => STATUS_SYNTAX_ERROR,
    ER_ILLEGAL_HA()                                     => STATUS_UNSUPPORTED,
    ER_ILLEGAL_HA_CREATE_OPTION()                       => STATUS_UNSUPPORTED,
    ER_ILLEGAL_PARAMETER_DATA_TYPES2_FOR_OPERATION()    => STATUS_SEMANTIC_ERROR,
    ER_ILLEGAL_PARAMETER_DATA_TYPE_FOR_OPERATION()      => STATUS_SEMANTIC_ERROR,
    ER_ILLEGAL_REFERENCE()                              => STATUS_UNSUPPORTED,
    ER_ILLEGAL_SUBQUERY_OPTIMIZER_SWITCHES()            => STATUS_SEMANTIC_ERROR,
    ER_ILLEGAL_VALUE_FOR_TYPE()                         => STATUS_RUNTIME_ERROR,
    ER_INCOMPATIBLE_FRM()                               => STATUS_DATABASE_CORRUPTION,
    ER_INCONSISTENT_ERROR()                             => STATUS_REPLICATION_FAILURE,
    ER_INCONSISTENT_PARTITION_INFO_ERROR()              => STATUS_DATABASE_CORRUPTION,
    ER_INCONSISTENT_SLAVE_TEMP_TABLE()                  => STATUS_REPLICATION_FAILURE,
    ER_INCONSISTENT_TYPE_OF_FUNCTIONS_ERROR()           => STATUS_SEMANTIC_ERROR,
    ER_INCORRECT_GLOBAL_LOCAL_VAR()                     => STATUS_SEMANTIC_ERROR,
    ER_INCORRECT_GTID_STATE()                           => STATUS_REPLICATION_FAILURE,
    ER_INDEX_COLUMN_TOO_LONG()                          => STATUS_RUNTIME_ERROR,
    ER_INDEX_CORRUPT()                                  => STATUS_RUNTIME_ERROR,
    ER_INDEX_FILE_FULL()                                => STATUS_RUNTIME_ERROR,
    ER_INDEX_REBUILD()                                  => STATUS_DATABASE_CORRUPTION,
    ER_INNODB_FT_AUX_NOT_HEX_ID()                       => STATUS_RUNTIME_ERROR,
    ER_INNODB_FT_LIMIT()                                => STATUS_UNSUPPORTED,
    ER_INNODB_FT_WRONG_DOCID_COLUMN()                   => STATUS_SEMANTIC_ERROR,
    ER_INNODB_FT_WRONG_DOCID_INDEX()                    => STATUS_SEMANTIC_ERROR,
    ER_INNODB_IMPORT_ERROR()                            => STATUS_DATABASE_CORRUPTION,
    ER_INNODB_INDEX_CORRUPT()                           => STATUS_DATABASE_CORRUPTION,
    ER_INNODB_NO_FT_TEMP_TABLE()                        => STATUS_SEMANTIC_ERROR,
    ER_INNODB_NO_FT_USES_PARSER()                       => STATUS_SEMANTIC_ERROR,
    ER_INNODB_ONLINE_LOG_TOO_BIG()                      => STATUS_RUNTIME_ERROR,
    ER_INNODB_READ_ONLY()                               => STATUS_CONFIGURATION_ERROR,
    ER_INNODB_UNDO_LOG_FULL()                           => STATUS_DATABASE_CORRUPTION,
    ER_INSECURE_CHANGE_MASTER()                         => STATUS_SKIP,
    ER_INSECURE_PLAIN_TEXT()                            => STATUS_SKIP,
    ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_BINLOG_DIRECT()         => STATUS_RUNTIME_ERROR,
    ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_BINLOG_FORMAT()         => STATUS_RUNTIME_ERROR,
    ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_GTID_DOMAIN_ID_SEQ_NO() => STATUS_RUNTIME_ERROR,
    ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_SKIP_REPLICATION()      => STATUS_RUNTIME_ERROR,
    ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_SQL_LOG_BIN() => STATUS_RUNTIME_ERROR,
    ER_INTERNAL_ERROR()                                 => STATUS_RUNTIME_ERROR,
    ER_INVALID_AGGREGATE_FUNCTION()                     => STATUS_SYNTAX_ERROR,
    ER_INVALID_ARGUMENT_FOR_LOGARITHM()                 => STATUS_SEMANTIC_ERROR,
    ER_INVALID_CAST_TO_JSON()                           => STATUS_SEMANTIC_ERROR,
    ER_INVALID_CHARACTER_STRING()                       => STATUS_SEMANTIC_ERROR,
    ER_INVALID_CURRENT_USER()                           => STATUS_IGNORED_ERROR, # switch to something critical after MDEV-17943 is fixed
    ER_INVALID_DEFAULT()                                => STATUS_SEMANTIC_ERROR,
    ER_INVALID_DEFAULT_PARAM()                          => STATUS_UNSUPPORTED,
    ER_INVALID_DEFAULT_VALUE_FOR_FIELD()                => STATUS_SEMANTIC_ERROR,
    ER_INVALID_FIELD_SIZE()                             => STATUS_SEMANTIC_ERROR,
    ER_INVALID_GROUP_FUNC_USE()                         => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_BINARY_DATA()                       => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_CHARSET()                           => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_CHARSET_IN_FUNCTION()               => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_PATH()                              => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_PATH_CHARSET()                      => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_PATH_WILDCARD()                     => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_TEXT()                              => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_TEXT_IN_PARAM()                     => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_VALUE_FOR_CAST()                    => STATUS_SEMANTIC_ERROR,
    ER_INVALID_NTILE_ARGUMENT()                         => STATUS_SEMANTIC_ERROR,
    ER_INVALID_ON_UPDATE()                              => STATUS_SEMANTIC_ERROR,
    ER_INVALID_ROLE()                                   => STATUS_SEMANTIC_ERROR,
    ER_INVALID_TYPE_FOR_JSON()                          => STATUS_SEMANTIC_ERROR,
    ER_INVALID_USE_OF_NULL()                            => STATUS_SEMANTIC_ERROR,
    ER_INVALID_VALUE_TO_LIMIT()                         => STATUS_SEMANTIC_ERROR,
    ER_INVALID_YEAR_COLUMN_LENGTH()                     => STATUS_SEMANTIC_ERROR,
    ER_INVISIBLE_NOT_NULL_WITHOUT_DEFAULT()             => STATUS_SEMANTIC_ERROR,
    ER_IO_ERR_LOG_INDEX_READ()                          => STATUS_REPLICATION_FAILURE,
    ER_IO_READ_ERROR()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_IO_WRITE_ERROR()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_IPSOCK_ERROR()                                   => STATUS_RUNTIME_ERROR,
    ER_ISOLATION_LEVEL_WITH_CONSISTENT_SNAPSHOT()       => STATUS_UNSUPPORTED,
    ER_ISOLATION_MODE_NOT_SUPPORTED()                   => STATUS_UNSUPPORTED,
    ER_IT_IS_A_VIEW()                                   => STATUS_SEMANTIC_ERROR,
    ER_JSON_BAD_CHR()                                   => STATUS_SEMANTIC_ERROR,
    ER_JSON_BAD_ONE_OR_ALL_ARG()                        => STATUS_SEMANTIC_ERROR,
    ER_JSON_DEPTH()                                     => STATUS_SEMANTIC_ERROR,
    ER_JSON_DOCUMENT_NULL_KEY()                         => STATUS_SEMANTIC_ERROR,
    ER_JSON_DOCUMENT_TOO_DEEP()                         => STATUS_SEMANTIC_ERROR,
    ER_JSON_EOS()                                       => STATUS_SEMANTIC_ERROR,
    ER_JSON_ESCAPING()                                  => STATUS_SEMANTIC_ERROR,
    ER_JSON_HISTOGRAM_PARSE_FAILED()                    => STATUS_DATABASE_CORRUPTION,
    ER_JSON_KEY_TOO_BIG()                               => STATUS_SEMANTIC_ERROR,
    ER_JSON_NOT_JSON_CHR()                              => STATUS_SEMANTIC_ERROR,
    ER_JSON_ONE_OR_ALL()                                => STATUS_SEMANTIC_ERROR,
    ER_JSON_PATH_ARRAY()                                => STATUS_SEMANTIC_ERROR,
    ER_JSON_PATH_DEPTH()                                => STATUS_SEMANTIC_ERROR,
    ER_JSON_PATH_EMPTY()                                => STATUS_SEMANTIC_ERROR,
    ER_JSON_PATH_EOS()                                  => STATUS_SEMANTIC_ERROR,
    ER_JSON_PATH_NO_WILDCARD()                          => STATUS_SEMANTIC_ERROR,
    ER_JSON_PATH_SYNTAX()                               => STATUS_SEMANTIC_ERROR,
    ER_JSON_SYNTAX()                                    => STATUS_SEMANTIC_ERROR,
    ER_JSON_TABLE_ALIAS_REQUIRED()                      => STATUS_SYNTAX_ERROR,
    ER_JSON_TABLE_ERROR_ON_FIELD()                      => STATUS_RUNTIME_ERROR,
    ER_JSON_TABLE_MULTIPLE_MATCHES()                    => STATUS_RUNTIME_ERROR,
    ER_JSON_TABLE_SCALAR_EXPECTED()                     => STATUS_RUNTIME_ERROR,
    ER_JSON_USED_AS_KEY()                               => STATUS_SEMANTIC_ERROR,
    ER_JSON_VACUOUS_PATH()                              => STATUS_SEMANTIC_ERROR,
    ER_JSON_VALUE_TOO_BIG()                             => STATUS_SEMANTIC_ERROR,
    ER_KEYS_OUT_OF_ORDER()                              => STATUS_RUNTIME_ERROR,
    ER_KEY_BASED_ON_GENERATED_VIRTUAL_COLUMN()          => STATUS_SEMANTIC_ERROR,
    ER_KEY_CANT_HAVE_WITHOUT_OVERLAPS()                 => STATUS_SEMANTIC_ERROR,
    ER_KEY_COLUMN_DOES_NOT_EXIST()                      => STATUS_SEMANTIC_ERROR,
    ER_KEY_CONTAINS_PERIOD_FIELDS()                     => STATUS_SEMANTIC_ERROR,
    ER_KEY_CREATE_DURING_ALTER()                        => STATUS_RUNTIME_ERROR,
    ER_KEY_DOESNT_SUPPORT()                             => STATUS_UNSUPPORTED,
    ER_KEY_DOES_NOT_EXITS()                             => STATUS_SEMANTIC_ERROR,
    ER_KEY_NOT_FOUND()                                  => STATUS_IGNORED_ERROR,
    ER_KEY_PART_0()                                     => STATUS_SEMANTIC_ERROR,
    ER_KEY_REF_DO_NOT_MATCH_TABLE_REF()                 => STATUS_SEMANTIC_ERROR,
    ER_KILL_DENIED_ERROR()                              => STATUS_ACL_ERROR,
    ER_KILL_QUERY_DENIED_ERROR()                        => STATUS_ACL_ERROR,
    ER_LIMITED_PART_RANGE()                             => STATUS_UNSUPPORTED,
    ER_LIST_OF_FIELDS_ONLY_IN_HASH_ERROR()              => STATUS_SEMANTIC_ERROR,
    ER_LOAD_DATA_INVALID_COLUMN()                       => STATUS_SEMANTIC_ERROR,
    ER_LOAD_FROM_FIXED_SIZE_ROWS_TO_VAR()               => STATUS_RUNTIME_ERROR,
    ER_LOAD_INFILE_CAPABILITY_DISABLED()                => STATUS_CONFIGURATION_ERROR,
    ER_LOCAL_VARIABLE()                                 => STATUS_SEMANTIC_ERROR,
    ER_LOCK_ABORTED()                                   => STATUS_RUNTIME_ERROR,
    ER_LOCK_DEADLOCK()                                  => STATUS_RUNTIME_ERROR,
    ER_LOCK_OR_ACTIVE_TRANSACTION()                     => STATUS_SEMANTIC_ERROR,
    ER_LOCK_TABLE_FULL()                                => STATUS_RUNTIME_ERROR,
    ER_LOCK_WAIT_TIMEOUT()                              => STATUS_RUNTIME_ERROR,
    ER_LOGGING_PROHIBIT_CHANGING_OF()                   => STATUS_CONFIGURATION_ERROR,
    ER_LOG_IN_USE()                                     => STATUS_RUNTIME_ERROR,
    ER_LOG_PURGE_NO_FILE()                              => STATUS_SEMANTIC_ERROR,
    ER_LOG_PURGE_UNKNOWN_ERR()                          => STATUS_REPLICATION_FAILURE,
    ER_MALFORMED_DEFINER()                              => STATUS_SEMANTIC_ERROR,
    ER_MALFORMED_GTID_SET_ENCODING()                    => STATUS_SYNTAX_ERROR,
    ER_MALFORMED_GTID_SET_SPECIFICATION()               => STATUS_SYNTAX_ERROR,
    ER_MALFORMED_GTID_SPECIFICATION()                   => STATUS_SYNTAX_ERROR,
    ER_MALFORMED_PACKET()                               => STATUS_CRITICAL_FAILURE,
    ER_MASTER()                                         => STATUS_REPLICATION_FAILURE,
    ER_MASTER_DELAY_VALUE_OUT_OF_RANGE()                => STATUS_SEMANTIC_ERROR,
    ER_MASTER_FATAL_ERROR_READING_BINLOG()              => STATUS_REPLICATION_FAILURE,
    ER_MASTER_GTID_POS_CONFLICTS_WITH_BINLOG()          => STATUS_REPLICATION_FAILURE,
    ER_MASTER_GTID_POS_MISSING_DOMAIN()                 => STATUS_SEMANTIC_ERROR,
    ER_MASTER_HAS_PURGED_REQUIRED_GTIDS()               => STATUS_REPLICATION_FAILURE,
    ER_MASTER_INFO()                                    => STATUS_REPLICATION_FAILURE,
    ER_MASTER_NET_READ()                                => STATUS_REPLICATION_FAILURE,
    ER_MASTER_NET_WRITE()                               => STATUS_REPLICATION_FAILURE,
    ER_MAXVALUE_IN_VALUES_IN()                          => STATUS_SEMANTIC_ERROR,
    ER_MAX_PREPARED_STMT_COUNT_REACHED()                => STATUS_CONFIGURATION_ERROR,
    ER_METADATA_INCONSISTENCY()                         => STATUS_DATABASE_CORRUPTION,
    ER_MISSING()                                        => STATUS_SEMANTIC_ERROR,
    ER_MISSING_HA_CREATE_OPTION()                       => STATUS_DATABASE_CORRUPTION,
    ER_MISSING_SKIP_SLAVE()                             => STATUS_CONFIGURATION_ERROR,
    ER_MIXING_NOT_ALLOWED()                             => STATUS_CONFIGURATION_ERROR,
    ER_MIX_HANDLER_ERROR()                              => STATUS_UNSUPPORTED,
    ER_MIX_OF_GROUP_FUNC_AND_FIELDS()                   => STATUS_SEMANTIC_ERROR,
    ER_MORE_THAN_ONE_PERIOD()                           => STATUS_SEMANTIC_ERROR,
    ER_MTS_CANT_PARALLEL()                              => STATUS_RUNTIME_ERROR,
    ER_MTS_CHANGE_MASTER_CANT_RUN_WITH_GAPS()           => STATUS_REPLICATION_FAILURE,
    ER_MTS_EVENT_BIGGER_PENDING_JOBS_SIZE_MAX()         => STATUS_CONFIGURATION_ERROR,
    ER_MTS_FEATURE_IS_NOT_SUPPORTED()                   => STATUS_UNSUPPORTED,
    ER_MTS_INCONSISTENT_DATA()                          => STATUS_RUNTIME_ERROR,
    ER_MTS_RECOVERY_FAILURE()                           => STATUS_REPLICATION_FAILURE,
    ER_MTS_RESET_WORKERS()                              => STATUS_REPLICATION_FAILURE,
    ER_MTS_UPDATED_DBS_GREATER_MAX()                    => STATUS_RUNTIME_ERROR,
    ER_MULTIPLE_DEF_CONST_IN_LIST_PART_ERROR()          => STATUS_SEMANTIC_ERROR,
    ER_MULTIPLE_PRI_KEY()                               => STATUS_SEMANTIC_ERROR,
    ER_MULTI_UPDATE_KEY_CONFLICT()                      => STATUS_RUNTIME_ERROR,
    ER_MUST_CHANGE_PASSWORD()                           => STATUS_ACL_ERROR,
    ER_MUST_CHANGE_PASSWORD_LOGIN()                     => STATUS_ACL_ERROR,
    ER_MYROCKS_CANT_NOPAD_COLLATION()                   => STATUS_UNSUPPORTED,
    ER_M_BIGGER_THAN_D()                                => STATUS_SEMANTIC_ERROR,
    ER_NAME_BECOMES_EMPTY()                             => STATUS_SEMANTIC_ERROR,
    ER_NATIVE_FCT_NAME_COLLISION()                      => STATUS_SEMANTIC_ERROR,
    ER_NEED_REPREPARE()                                 => STATUS_RUNTIME_ERROR,
    ER_NETWORK_READ_EVENT_CHECKSUM_FAILURE()            => STATUS_REPLICATION_FAILURE,
    ER_NET_ERROR_ON_WRITE()                             => STATUS_ENVIRONMENT_FAILURE,
    ER_NET_FCNTL_ERROR()                                => STATUS_ENVIRONMENT_FAILURE,
    ER_NET_OK_PACKET_TOO_LARGE()                        => STATUS_ALARM,
    ER_NET_PACKETS_OUT_OF_ORDER()                       => STATUS_ALARM,
    ER_NET_PACKET_TOO_LARGE()                           => STATUS_CONFIGURATION_ERROR,
    ER_NET_READ_ERROR()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_NET_READ_ERROR_FROM_PIPE()                       => STATUS_CONFIGURATION_ERROR,
    ER_NET_READ_INTERRUPTED()                           => STATUS_RUNTIME_ERROR,
    ER_NET_UNCOMPRESS_ERROR()                           => STATUS_ENVIRONMENT_FAILURE,
    ER_NET_WRITE_INTERRUPTED()                          => STATUS_RUNTIME_ERROR,
    ER_NEW_ABORTING_CONNECTION()                        => STATUS_RUNTIME_ERROR,
    ER_NONEXISTING_GRANT()                              => STATUS_SEMANTIC_ERROR,
    ER_NONEXISTING_PROC_GRANT()                         => STATUS_SEMANTIC_ERROR,
    ER_NONEXISTING_TABLE_GRANT()                        => STATUS_SEMANTIC_ERROR,
    ER_NONUNIQ_TABLE()                                  => STATUS_SEMANTIC_ERROR,
    ER_NONUPDATEABLE_COLUMN()                           => STATUS_RUNTIME_ERROR,
    ER_NON_GROUPING_FIELD_USED()                        => STATUS_SEMANTIC_ERROR,
    ER_NON_INSERTABLE_TABLE()                           => STATUS_SEMANTIC_ERROR,
    ER_NON_RO_SELECT_DISABLE_TIMER()                    => STATUS_RUNTIME_ERROR,
    ER_NON_UNIQ_ERROR()                                 => STATUS_SEMANTIC_ERROR,
    ER_NON_UPDATABLE_TABLE()                            => STATUS_SEMANTIC_ERROR,
    ER_NORMAL_SHUTDOWN()                                => STATUS_SERVER_KILLED,
    ER_NOT_AGGREGATE_FUNCTION()                         => STATUS_SEMANTIC_ERROR,
    ER_NOT_ALLOWED_COMMAND()                            => STATUS_UNSUPPORTED,
    ER_NOT_ALLOWED_IN_THIS_CONTEXT()                    => STATUS_SEMANTIC_ERROR,
    ER_NOT_ALLOWED_WINDOW_FRAME()                       => STATUS_SEMANTIC_ERROR,
    ER_NOT_CONSTANT_EXPRESSION()                        => STATUS_SEMANTIC_ERROR,
    ER_NOT_FORM_FILE()                                  => STATUS_DATABASE_CORRUPTION,
    ER_NOT_KEYFILE()                                    => STATUS_IGNORED_ERROR,
    ER_NOT_SEQUENCE()                                   => STATUS_SEMANTIC_ERROR,
    ER_NOT_SEQUENCE2()                                  => STATUS_SEMANTIC_ERROR,
    ER_NOT_STANDARD_COMPLIANT_RECURSIVE()               => STATUS_SEMANTIC_ERROR,
    ER_NOT_SUPPORTED_AUTH_MODE()                        => STATUS_ENVIRONMENT_FAILURE,
    ER_NOT_SUPPORTED_YET()                              => STATUS_UNSUPPORTED,
    ER_NOT_VALID_PASSWORD()                             => STATUS_ACL_ERROR,
    ER_NO_AUTOINCREMENT_WITH_UNIQUE()                   => STATUS_SEMANTIC_ERROR,
    ER_NO_BINARY_LOGGING()                              => STATUS_CONFIGURATION_ERROR,
    ER_NO_BINLOG_ERROR()                                => STATUS_SEMANTIC_ERROR,
    ER_NO_DB_ERROR()                                    => STATUS_SEMANTIC_ERROR,
    ER_NO_DEFAULT()                                     => STATUS_SEMANTIC_ERROR,
    ER_NO_DEFAULT_FOR_FIELD()                           => STATUS_SEMANTIC_ERROR,
    ER_NO_DEFAULT_FOR_VIEW_FIELD()                      => STATUS_RUNTIME_ERROR,
    ER_NO_EIS_FOR_FIELD()                               => STATUS_RUNTIME_ERROR,
    ER_NO_FILE_MAPPING()                                => STATUS_ENVIRONMENT_FAILURE,
    ER_NO_FORMAT_DESCRIPTION_EVENT_BEFORE_BINLOG_STATEMENT() => STATUS_REPLICATION_FAILURE,
    ER_NO_FT_MATERIALIZED_SUBQUERY()                    => STATUS_RUNTIME_ERROR,
    ER_NO_GROUP_FOR_PROC()                              => STATUS_SEMANTIC_ERROR,
    ER_NO_ORDER_LIST_IN_WINDOW_SPEC()                   => STATUS_SEMANTIC_ERROR,
    ER_NO_PARTITION_FOR_GIVEN_VALUE()                   => STATUS_RUNTIME_ERROR,
    ER_NO_PARTITION_FOR_GIVEN_VALUE_SILENT()            => STATUS_RUNTIME_ERROR,
    ER_NO_PARTS_ERROR()                                 => STATUS_SEMANTIC_ERROR,
    ER_NO_PERMISSION_TO_CREATE_USER()                   => STATUS_ACL_ERROR,
    ER_NO_RAID_COMPILED()                               => STATUS_UNSUPPORTED,
    ER_NO_REFERENCED_ROW()                              => STATUS_RUNTIME_ERROR,
    ER_NO_REFERENCED_ROW_2()                            => STATUS_RUNTIME_ERROR,
    ER_NO_SECURE_TRANSPORTS_CONFIGURED()                => STATUS_CONFIGURATION_ERROR,
    ER_NO_SUCH_INDEX()                                  => STATUS_DATABASE_CORRUPTION,
    ER_NO_SUCH_KEY_VALUE()                              => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_TABLE()                                  => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_TABLE_IN_ENGINE()                        => STATUS_DATABASE_CORRUPTION,
    ER_NO_SUCH_THREAD()                                 => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_QUERY()                                  => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_USER()                                   => STATUS_SEMANTIC_ERROR,
    ER_NO_TABLES_USED()                                 => STATUS_SEMANTIC_ERROR,
    ER_NO_TRIGGERS_ON_SYSTEM_SCHEMA()                   => STATUS_SEMANTIC_ERROR,
    ER_NO_UNIQUE_LOGFILE()                              => STATUS_ENVIRONMENT_FAILURE,
    ER_NULL_COLUMN_IN_INDEX()                           => STATUS_UNSUPPORTED,
    ER_NULL_IN_VALUES_LESS_THAN()                       => STATUS_SEMANTIC_ERROR,
    ER_NUMERIC_JSON_VALUE_OUT_OF_RANGE()                => STATUS_SEMANTIC_ERROR,
    ER_OLD_FILE_FORMAT()                                => STATUS_DATABASE_CORRUPTION,
    ER_ONLY_FD_AND_RBR_EVENTS_ALLOWED_IN_BINLOG_STATEMENT() => STATUS_SEMANTIC_ERROR,
    ER_ONLY_INTEGERS_ALLOWED()                          => STATUS_SEMANTIC_ERROR,
    ER_ONLY_ON_RANGE_LIST_PARTITION()                   => STATUS_SEMANTIC_ERROR,
    ER_ON_DUPLICATE_DISABLED()                          => STATUS_UNSUPPORTED,
    ER_OPEN_AS_READONLY()                               => STATUS_RUNTIME_ERROR,
    ER_OPERAND_COLUMNS()                                => STATUS_SEMANTIC_ERROR,
    ER_OPTION_PREVENTS_STATEMENT()                      => STATUS_CONFIGURATION_ERROR,
    ER_ORDER_LIST_IN_REFERENCING_WINDOW_SPEC()          => STATUS_SEMANTIC_ERROR,
    ER_ORDER_WITH_PROC()                                => STATUS_SEMANTIC_ERROR,
    ER_OUTOFMEMORY()                                    => STATUS_ENVIRONMENT_FAILURE,
    ER_OUTOFMEMORY2()                                   => STATUS_ENVIRONMENT_FAILURE,
    ER_OUT_OF_RESOURCES()                               => STATUS_DATABASE_CORRUPTION, # Demoted to non-critical due to MDEV-29157
    ER_OUT_OF_SORTMEMORY()                              => STATUS_CONFIGURATION_ERROR,
    ER_OVERLAPPING_KEYS()                               => STATUS_RUNTIME_ERROR,
    ER_PACKAGE_ROUTINE_FORWARD_DECLARATION_NOT_DEFINED() => STATUS_SEMANTIC_ERROR,
    ER_PACKAGE_ROUTINE_IN_SPEC_NOT_DEFINED_IN_BODY()    => STATUS_SEMANTIC_ERROR,
    ER_PARSE_ERROR()                                    => STATUS_SYNTAX_ERROR,
    ER_PARTITIONS_MUST_BE_DEFINED_ERROR()               => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_CLAUSE_ON_NONPARTITIONED()             => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_COLUMN_LIST_ERROR()                    => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_CONST_DOMAIN_ERROR()                   => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_CONVERT_SUBPARTITIONED()               => STATUS_UNSUPPORTED,
    ER_PARTITION_DEFAULT_ERROR()                        => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_ENTRY_ERROR()                          => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_EXCHANGE_DIFFERENT_OPTION()            => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_EXCHANGE_FOREIGN_KEY()                 => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_EXCHANGE_PART_TABLE()                  => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_EXCHANGE_TEMP_TABLE()                  => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_FIELDS_TOO_LONG()                      => STATUS_RUNTIME_ERROR,
    ER_PARTITION_FUNCTION_FAILURE()                     => STATUS_UNSUPPORTED,
    ER_PARTITION_FUNCTION_IS_NOT_ALLOWED()              => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_FUNC_NOT_ALLOWED_ERROR()               => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_INSTEAD_OF_SUBPARTITION()              => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_LIST_IN_REFERENCING_WINDOW_SPEC()      => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_MAXVALUE_ERROR()                       => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_MERGE_ERROR()                          => STATUS_UNSUPPORTED,
    ER_PARTITION_MGMT_ON_NONPARTITIONED()               => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_NOT_DEFINED_ERROR()                    => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_NO_TEMPORARY()                         => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_REQUIRES_VALUES_ERROR()                => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_SUBPARTITION_ERROR()                   => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_SUBPART_MIX_ERROR()                    => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_WRONG_NO_PART_ERROR()                  => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_WRONG_NO_SUBPART_ERROR()               => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_WRONG_TYPE()                           => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_WRONG_VALUES_ERROR()                   => STATUS_SEMANTIC_ERROR,
    ER_PART_STARTS_BEYOND_INTERVAL()                    => STATUS_SEMANTIC_ERROR,
    ER_PART_STATE_ERROR()                               => STATUS_SEMANTIC_ERROR,
    ER_PART_WRONG_VALUE()                               => STATUS_SEMANTIC_ERROR,
    ER_PASSWD_LENGTH()                                  => STATUS_SEMANTIC_ERROR,
    ER_PASSWORD_ANONYMOUS_USER()                        => STATUS_ACL_ERROR,
    ER_PASSWORD_EXPIRE_ANONYMOUS_USER()                 => STATUS_ACL_ERROR,
    ER_PASSWORD_FORMAT()                                => STATUS_SEMANTIC_ERROR,
    ER_PASSWORD_NOT_ALLOWED()                           => STATUS_ACL_ERROR,
    ER_PASSWORD_NO_MATCH()                              => STATUS_SEMANTIC_ERROR,
    ER_PATH_LENGTH()                                    => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_COLUMNS_UPDATED()                         => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_CONSTRAINT_DROP()                         => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_FIELD_WRONG_ATTRIBUTES()                  => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_NOT_FOUND()                               => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_TEMPORARY_NOT_ALLOWED()                   => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_TYPES_MISMATCH()                          => STATUS_SEMANTIC_ERROR,
    ER_PER_INDEX_CF_DEPRECATED()                        => STATUS_SEMANTIC_ERROR,
    ER_PK_INDEX_CANT_BE_IGNORED                         => STATUS_SEMANTIC_ERROR,
    ER_PLUGIN_DELETE_BUILTIN()                          => STATUS_CONFIGURATION_ERROR,
    ER_PLUGIN_INSTALLED()                               => STATUS_CONFIGURATION_ERROR,
    ER_PLUGIN_IS_NOT_LOADED()                           => STATUS_CONFIGURATION_ERROR,
    ER_PLUGIN_IS_PERMANENT()                            => STATUS_CONFIGURATION_ERROR,
    ER_PRIMARY_CANT_HAVE_NULL()                         => STATUS_SEMANTIC_ERROR,
    ER_PRIMARY_KEY_BASED_ON_GENERATED_COLUMN()          => STATUS_SEMANTIC_ERROR,
    ER_PRIOR_COMMIT_FAILED()                            => STATUS_RUNTIME_ERROR,
    ER_PROCACCESS_DENIED_ERROR()                        => STATUS_ACL_ERROR,
    ER_PROC_AUTO_GRANT_FAIL()                           => STATUS_RUNTIME_ERROR,
    ER_PROC_AUTO_REVOKE_FAIL()                          => STATUS_RUNTIME_ERROR,
    ER_PROVIDER_NOT_LOADED()                            => STATUS_CONFIGURATION_ERROR,
    ER_PS_MANY_PARAM()                                  => STATUS_SEMANTIC_ERROR,
    ER_PS_NO_RECURSION()                                => STATUS_SEMANTIC_ERROR,
    ER_QUERY_CACHE_DISABLED()                           => STATUS_CONFIGURATION_ERROR,
    ER_QUERY_CACHE_IS_DISABLED()                        => STATUS_RUNTIME_ERROR,
    ER_QUERY_CACHE_IS_GLOBALY_DISABLED()                => STATUS_SEMANTIC_ERROR,
    ER_QUERY_EXCEEDED_ROWS_EXAMINED_LIMIT()             => STATUS_SKIP,
    ER_QUERY_INTERRUPTED()                              => STATUS_SKIP,
    ER_QUERY_ON_FOREIGN_DATA_SOURCE()                   => STATUS_RUNTIME_ERROR,
    ER_QUERY_ON_MASTER()                                => STATUS_REPLICATION_FAILURE,
    ER_QUERY_TIMEOUT()                                  => STATUS_SKIP,
    ER_RANGE_FRAME_NEEDS_SIMPLE_ORDERBY()               => STATUS_SEMANTIC_ERROR,
    ER_RANGE_NOT_INCREASING_ERROR()                     => STATUS_SEMANTIC_ERROR,
    ER_RBR_NOT_AVAILABLE()                              => STATUS_CONFIGURATION_ERROR,
    ER_RDB_STATUS_GENERAL()                             => STATUS_RUNTIME_ERROR,
    ER_RDB_STATUS_MSG()                                 => STATUS_RUNTIME_ERROR,
    ER_RDB_TTL_COL_FORMAT()                             => STATUS_SEMANTIC_ERROR,
    ER_RDB_TTL_DURATION_FORMAT()                        => STATUS_CONFIGURATION_ERROR,
    ER_RDB_TTL_UNSUPPORTED()                            => STATUS_UNSUPPORTED,
    ER_READ_ONLY_MODE()                                 => STATUS_CONFIGURATION_ERROR,
    ER_READ_ONLY_TRANSACTION()                          => STATUS_RUNTIME_ERROR,
    ER_RECORD_FILE_FULL()                               => STATUS_RUNTIME_ERROR,
    ER_RECURSIVE_WITHOUT_ANCHORS()                      => STATUS_SEMANTIC_ERROR,
    ER_REFERENCED_TRG_DOES_NOT_EXIST()                  => STATUS_SEMANTIC_ERROR,
    ER_REFERENCED_TRG_DOES_NOT_EXIST_MYSQL()            => STATUS_SEMANTIC_ERROR,
    ER_REGEXP_ERROR()                                   => STATUS_RUNTIME_ERROR,
    ER_REF_TO_RECURSIVE_WITH_TABLE_IN_DERIVED()         => STATUS_RUNTIME_ERROR,
    ER_RELAY_LOG_FAIL()                                 => STATUS_REPLICATION_FAILURE,
    ER_RELAY_LOG_INIT()                                 => STATUS_REPLICATION_FAILURE,
    ER_REMOVED_ORPHAN_TRIGGER()                         => STATUS_RUNTIME_ERROR,
    ER_REORG_HASH_ONLY_ON_SAME_NO()                     => STATUS_SEMANTIC_ERROR,
    ER_REORG_NO_PARAM_ERROR()                           => STATUS_SEMANTIC_ERROR,
    ER_REORG_OUTSIDE_RANGE()                            => STATUS_SEMANTIC_ERROR,
    ER_REORG_PARTITION_NOT_EXIST()                      => STATUS_SEMANTIC_ERROR,
    ER_REPLACE_INACCESSIBLE_ROWS()                      => STATUS_RUNTIME_ERROR,
    ER_REQUIRES_PRIMARY_KEY()                           => STATUS_SEMANTIC_ERROR,
    ER_REQUIRE_ROW_BINLOG_FORMAT()                      => STATUS_CONFIGURATION_ERROR,
    ER_RESERVED_SYNTAX()                                => STATUS_SYNTAX_ERROR,
    ER_RESIGNAL_WITHOUT_ACTIVE_HANDLER()                => STATUS_SEMANTIC_ERROR,
    ER_REVOKE_GRANTS()                                  => STATUS_RUNTIME_ERROR,
    ER_ROLE_CREATE_EXISTS()                             => STATUS_SEMANTIC_ERROR,
    ER_ROLE_DROP_EXISTS()                               => STATUS_SEMANTIC_ERROR,
    ER_ROLLBACK_ONLY()                                  => STATUS_UNSUPPORTED,
    ER_ROLLBACK_TO_SAVEPOINT()                          => STATUS_UNSUPPORTED,
    ER_ROW_DOES_NOT_MATCH_GIVEN_PARTITION_SET()         => STATUS_RUNTIME_ERROR,
    ER_ROW_DOES_NOT_MATCH_PARTITION()                   => STATUS_RUNTIME_ERROR,
    ER_ROW_IN_WRONG_PARTITION()                         => STATUS_DATABASE_CORRUPTION,
    ER_ROW_IS_REFERENCED()                              => STATUS_RUNTIME_ERROR,
    ER_ROW_IS_REFERENCED_2()                            => STATUS_RUNTIME_ERROR,
    ER_ROW_SINGLE_PARTITION_FIELD_ERROR()               => STATUS_SEMANTIC_ERROR,
    ER_ROW_VARIABLE_DOES_NOT_HAVE_FIELD()               => STATUS_SEMANTIC_ERROR,
    ER_SAME_NAME_PARTITION()                            => STATUS_SEMANTIC_ERROR,
    ER_SAME_NAME_PARTITION_FIELD()                      => STATUS_SEMANTIC_ERROR,
    ER_SEQUENCE_ACCESS_ERROR()                          => STATUS_ACL_ERROR,
    ER_SEQUENCE_BINLOG_FORMAT()                         => STATUS_CONFIGURATION_ERROR,
    ER_SEQUENCE_INVALID_DATA()                          => STATUS_SEMANTIC_ERROR,
    ER_SEQUENCE_INVALID_TABLE_STRUCTURE()               => STATUS_SEMANTIC_ERROR,
    ER_SEQUENCE_RUN_OUT()                               => STATUS_RUNTIME_ERROR,
    ER_SERVER_GONE_ERROR()                              => STATUS_SEMANTIC_ERROR,
    ER_SERVER_IS_IN_SECURE_AUTH_MODE()                  => STATUS_CONFIGURATION_ERROR,
    ER_SERVER_LOST()                                    => STATUS_SERVER_CRASHED,
    ER_SERVER_LOST_EXTENDED()                           => STATUS_SERVER_CRASHED,
    ER_SERVER_OFFLINE_MODE()                            => STATUS_CONFIGURATION_ERROR,
    ER_SERVER_SHUTDOWN()                                => STATUS_SERVER_KILLED,
    ER_SET_CONSTANTS_ONLY()                             => STATUS_SEMANTIC_ERROR,
    ER_SET_PASSWORD_AUTH_PLUGIN()                       => STATUS_ACL_ERROR,
    ER_SET_STATEMENT_CANNOT_INVOKE_FUNCTION()           => STATUS_SEMANTIC_ERROR,
    ER_SET_STATEMENT_NOT_SUPPORTED()                    => STATUS_UNSUPPORTED,
    ER_SF_OUT_INOUT_ARG_NOT_ALLOWED()                   => STATUS_SYNTAX_ERROR,
    ER_SHUTDOWN_COMPLETE()                              => STATUS_SERVER_KILLED,
    ER_SIGNAL_BAD_CONDITION_TYPE()                      => STATUS_SEMANTIC_ERROR,
    ER_SIGNAL_EXCEPTION()                               => STATUS_RUNTIME_ERROR,
    ER_SIGNAL_NOT_FOUND()                               => STATUS_RUNTIME_ERROR,
    ER_SIGNAL_WARN()                                    => STATUS_RUNTIME_ERROR,
    ER_SIZE_OVERFLOW_ERROR()                            => STATUS_UNSUPPORTED,
    ER_SKIPPING_LOGGED_TRANSACTION()                    => STATUS_RUNTIME_ERROR,
    ER_SK_POPULATE_DURING_ALTER()                       => STATUS_RUNTIME_ERROR,
    ER_SLAVE_CANT_CREATE_CONVERSION()                   => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_CHANNEL_IO_THREAD_MUST_STOP()              => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_CONFIGURATION()                            => STATUS_CONFIGURATION_ERROR,
    ER_SLAVE_CONVERSION_FAILED()                        => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_CORRUPT_EVENT()                            => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_CREATE_EVENT_FAILURE()                     => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_FATAL_ERROR()                              => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_HEARTBEAT_FAILURE()                        => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE()             => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MAX()         => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MIN()         => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_IGNORED_SHARED_TABLE()                     => STATUS_RUNTIME_ERROR,
    ER_SLAVE_IGNORED_SSL_PARAMS()                       => STATUS_CONFIGURATION_ERROR,
    ER_SLAVE_IGNORED_TABLE()                            => STATUS_RUNTIME_ERROR,
    ER_SLAVE_IGNORE_SERVER_IDS()                        => STATUS_CONFIGURATION_ERROR,
    ER_SLAVE_INCIDENT()                                 => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_MASTER_COM_FAILURE()                       => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_MI_INIT_REPOSITORY()                       => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_MUST_STOP()                                => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_NOT_RUNNING()                              => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_RELAY_LOG_READ_FAILURE()                   => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_RELAY_LOG_WRITE_FAILURE()                  => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_RLI_INIT_REPOSITORY()                      => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_SAME_ID()                                  => STATUS_CONFIGURATION_ERROR,
    ER_SLAVE_SILENT_RETRY_TRANSACTION()                 => STATUS_RUNTIME_ERROR,
    ER_SLAVE_SKIP_NOT_IN_GTID()                         => STATUS_CONFIGURATION_ERROR,
    ER_SLAVE_SQL_THREAD_MUST_STOP()                     => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_STARTED()                                  => STATUS_RUNTIME_ERROR,
    ER_SLAVE_STOPPED()                                  => STATUS_RUNTIME_ERROR,
    ER_SLAVE_THREAD()                                   => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_UNEXPECTED_MASTER_SWITCH()                 => STATUS_REPLICATION_FAILURE,
    ER_SLAVE_WAS_NOT_RUNNING()                          => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_WAS_RUNNING()                              => STATUS_SEMANTIC_ERROR,
    ER_SLAVE_WORKER_STOPPED_PREVIOUS_THD_ERROR()        => STATUS_REPLICATION_FAILURE,
    ER_SPATIAL_CANT_HAVE_NULL()                         => STATUS_SEMANTIC_ERROR,
    ER_SPATIAL_MUST_HAVE_GEOM_COL()                     => STATUS_SEMANTIC_ERROR,
    ER_SPECIFIC_ACCESS_DENIED_ERROR()                   => STATUS_ACL_ERROR,
    ER_SP_ALREADY_EXISTS()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_BADRETURN()                                   => STATUS_SEMANTIC_ERROR,
    ER_SP_BADSELECT()                                   => STATUS_SEMANTIC_ERROR,
    ER_SP_BADSTATEMENT()                                => STATUS_SEMANTIC_ERROR,
    ER_SP_BAD_CURSOR_QUERY()                            => STATUS_SYNTAX_ERROR,
    ER_SP_BAD_CURSOR_SELECT()                           => STATUS_SYNTAX_ERROR,
    ER_SP_BAD_SQLSTATE()                                => STATUS_SYNTAX_ERROR,
    ER_SP_BAD_VAR_SHADOW()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_CANT_ALTER()                                  => STATUS_RUNTIME_ERROR,
    ER_SP_CANT_SET_AUTOCOMMIT()                         => STATUS_SEMANTIC_ERROR,
    ER_SP_CASE_NOT_FOUND()                              => STATUS_RUNTIME_ERROR,
    ER_SP_COND_MISMATCH()                               => STATUS_SEMANTIC_ERROR,
    ER_SP_CURSOR_ALREADY_OPEN()                         => STATUS_SEMANTIC_ERROR,
    ER_SP_CURSOR_AFTER_HANDLER()                        => STATUS_SEMANTIC_ERROR,
    ER_SP_CURSOR_MISMATCH()                             => STATUS_SEMANTIC_ERROR,
    ER_SP_CURSOR_NOT_OPEN()                             => STATUS_SEMANTIC_ERROR,
    ER_SP_DOES_NOT_EXIST()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_DROP_FAILED()                                 => STATUS_RUNTIME_ERROR,
    ER_SP_DUP_COND()                                    => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_CURS()                                    => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_HANDLER()                                 => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_PARAM()                                   => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_VAR()                                     => STATUS_SEMANTIC_ERROR,
    ER_SP_FETCH_NO_DATA()                               => STATUS_RUNTIME_ERROR,
    ER_SP_GOTO_IN_HNDLR()                               => STATUS_SYNTAX_ERROR,
    ER_SP_LABEL_MISMATCH()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_LABEL_REDEFINE()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_LILABEL_MISMATCH()                            => STATUS_SEMANTIC_ERROR,
    ER_SP_NORETURN()                                    => STATUS_SYNTAX_ERROR,
    ER_SP_NORETURNEND()                                 => STATUS_RUNTIME_ERROR,
    ER_SP_NOT_VAR_ARG()                                 => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_AGGREGATE()                                => STATUS_UNSUPPORTED,
    ER_SP_NO_DROP_SP()                                  => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_RECURSION()                                => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_RECURSIVE_CREATE()                         => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_RETSET()                                   => STATUS_SEMANTIC_ERROR,
    ER_SP_PROC_TABLE_CORRUPT()                          => STATUS_DATABASE_CORRUPTION,
    ER_SP_RECURSION_LIMIT()                             => STATUS_CONFIGURATION_ERROR,
    ER_SP_STACK_TRACE()                                 => STATUS_RUNTIME_ERROR,
    ER_SP_STORE_FAILED()                                => STATUS_RUNTIME_ERROR,
    ER_SP_SUBSELECT_NYI()                               => STATUS_UNSUPPORTED,
    ER_SP_UNDECLARED_VAR()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_UNINIT_VAR()                                  => STATUS_SEMANTIC_ERROR,
    ER_SP_VARCOND_AFTER_CURSHNDLR()                     => STATUS_SEMANTIC_ERROR,
    ER_SP_WRONG_NAME()                                  => STATUS_SEMANTIC_ERROR,
    ER_SP_WRONG_NO_OF_ARGS()                            => STATUS_SEMANTIC_ERROR,
    ER_SP_WRONG_NO_OF_FETCH_ARGS()                      => STATUS_SEMANTIC_ERROR,
    ER_SQLTHREAD_WITH_SECURE_SLAVE()                    => STATUS_SEMANTIC_ERROR,
    ER_SQL_DISCOVER_ERROR()                             => STATUS_DATABASE_CORRUPTION,
    ER_SQL_SLAVE_SKIP_COUNTER_NOT_SETTABLE_IN_GTID_MODE() => STATUS_SEMANTIC_ERROR,
    ER_SQL_MODE_NO_EFFECT()                             => STATUS_CONFIGURATION_ERROR,
    ER_SR_INVALID_CREATION_CTX()                        => STATUS_SEMANTIC_ERROR,
    ER_STACK_OVERRUN()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_STACK_OVERRUN_NEED_MORE()                        => STATUS_ENVIRONMENT_FAILURE,
    ER_STATEMENT_TIMEOUT()                              => STATUS_SKIP,
    ER_STD_BAD_ALLOC_ERROR()                            => STATUS_ENVIRONMENT_FAILURE,
    ER_STD_DOMAIN_ERROR()                               => STATUS_RUNTIME_ERROR,
    ER_STD_INVALID_ARGUMENT()                           => STATUS_RUNTIME_ERROR,
    ER_STD_LENGTH_ERROR()                               => STATUS_RUNTIME_ERROR,
    ER_STD_LOGIC_ERROR()                                => STATUS_RUNTIME_ERROR,
    ER_STD_OUT_OF_RANGE_ERROR()                         => STATUS_RUNTIME_ERROR,
    ER_STD_OVERFLOW_ERROR()                             => STATUS_RUNTIME_ERROR,
    ER_STD_RANGE_ERROR()                                => STATUS_RUNTIME_ERROR,
    ER_STD_RUNTIME_ERROR()                              => STATUS_RUNTIME_ERROR,
    ER_STD_UNDERFLOW_ERROR()                            => STATUS_RUNTIME_ERROR,
    ER_STD_UNKNOWN_EXCEPTION()                          => STATUS_RUNTIME_ERROR,
    ER_STMT_CACHE_FULL()                                => STATUS_RUNTIME_ERROR,
    ER_STMT_HAS_NO_OPEN_CURSOR()                        => STATUS_RUNTIME_ERROR,
    ER_STMT_NOT_ALLOWED_IN_SF_OR_TRG()                  => STATUS_SYNTAX_ERROR,
    ER_STOP_SLAVE_IO_THREAD_TIMEOUT()                   => STATUS_REPLICATION_FAILURE,
    ER_STOP_SLAVE_SQL_THREAD_TIMEOUT()                  => STATUS_REPLICATION_FAILURE,
    ER_STORAGE_ENGINE_DISABLED()                        => STATUS_ENVIRONMENT_FAILURE,
    ER_STORAGE_ENGINE_NOT_LOADED()                      => STATUS_CONFIGURATION_ERROR,
    ER_STORED_FUNCTION_PREVENTS_SWITCH_BINLOG_DIRECT()  => STATUS_SEMANTIC_ERROR,
    ER_STORED_FUNCTION_PREVENTS_SWITCH_BINLOG_FORMAT()  => STATUS_SEMANTIC_ERROR,
    ER_STORED_FUNCTION_PREVENTS_SWITCH_GTID_DOMAIN_ID_SEQ_NO() => STATUS_SEMANTIC_ERROR,
    ER_STORED_FUNCTION_PREVENTS_SWITCH_SKIP_REPLICATION() => STATUS_SEMANTIC_ERROR,
    ER_STORED_FUNCTION_PREVENTS_SWITCH_SQL_LOG_BIN()    => STATUS_SEMANTIC_ERROR,
    ER_SUBPARTITION_ERROR()                             => STATUS_SEMANTIC_ERROR,
    ER_SUBQUERIES_NOT_SUPPORTED()                       => STATUS_UNSUPPORTED,
    ER_SUBQUERY_NO_1_ROW()                              => STATUS_RUNTIME_ERROR,
    ER_SUM_FUNC_WITH_WINDOW_FUNC_AS_ARG()               => STATUS_SEMANTIC_ERROR,
    ER_SYNTAX_ERROR()                                   => STATUS_SYNTAX_ERROR,
    ER_TABLEACCESS_DENIED_ERROR()                       => STATUS_ACL_ERROR,
    ER_TABLENAME_NOT_ALLOWED_HERE()                     => STATUS_SEMANTIC_ERROR,
    ER_TABLESPACE_AUTO_EXTEND_ERROR()                   => STATUS_UNSUPPORTED,
    ER_TABLESPACE_DISCARDED()                           => STATUS_RUNTIME_ERROR,
    ER_TABLESPACE_EXISTS()                              => STATUS_RUNTIME_ERROR,
    ER_TABLESPACE_MISSING()                             => STATUS_DATABASE_CORRUPTION,
    ER_TABLES_DIFFERENT_METADATA()                      => STATUS_SEMANTIC_ERROR,
#    ER_TABLESPACE_EXIST()                               => STATUS_SEMANTIC_ERROR,
    ER_TABLE_CANT_HANDLE_AUTO_INCREMENT()               => STATUS_UNSUPPORTED,
    ER_TABLE_CANT_HANDLE_BLOB()                         => STATUS_UNSUPPORTED,
    ER_TABLE_CANT_HANDLE_FT()                           => STATUS_UNSUPPORTED,
    ER_TABLE_CANT_HANDLE_SPKEYS()                       => STATUS_UNSUPPORTED,
    ER_TABLE_CORRUPT()                                  => STATUS_DATABASE_CORRUPTION,
    ER_TABLE_DEFINITION_TOO_BIG()                       => STATUS_SEMANTIC_ERROR,
    ER_TABLE_DEF_CHANGED()                              => STATUS_RUNTIME_ERROR,
    ER_TABLE_EXISTS_ERROR()                             => STATUS_SEMANTIC_ERROR,
    ER_TABLE_HAS_NO_FT()                                => STATUS_SEMANTIC_ERROR,
    ER_TABLE_IN_SYSTEM_TABLESPACE()                     => STATUS_RUNTIME_ERROR,
    ER_TABLE_MUST_HAVE_COLUMNS()                        => STATUS_SEMANTIC_ERROR,
    ER_TABLE_NEEDS_REBUILD()                            => STATUS_DATABASE_CORRUPTION,
    ER_TABLE_NEEDS_UPGRADE()                            => STATUS_DATABASE_CORRUPTION,
    ER_TABLE_NOT_LOCKED()                               => STATUS_SEMANTIC_ERROR,
    ER_TABLE_NOT_LOCKED_FOR_WRITE()                     => STATUS_SEMANTIC_ERROR,
    ER_TABLE_SCHEMA_MISMATCH()                          => STATUS_DATABASE_CORRUPTION,
    ER_TARGET_NOT_EXPLAINABLE()                         => STATUS_RUNTIME_ERROR,
    ER_TEMP_TABLE_PREVENTS_SWITCH_OUT_OF_RBR()          => STATUS_RUNTIME_ERROR,
    ER_TEMP_FILE_WRITE_FAILURE()                        => STATUS_ENVIRONMENT_FAILURE,
    ER_TEXTFILE_NOT_READABLE()                          => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_DISPLAYWIDTH()                           => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_FIELDLENGTH()                            => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_FOR_UNCOMPRESS()                         => STATUS_RUNTIME_ERROR,
    ER_TOO_BIG_PRECISION()                              => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_ROWSIZE()                                => STATUS_RUNTIME_ERROR,
    ER_TOO_BIG_SCALE()                                  => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_SELECT()                                 => STATUS_RUNTIME_ERROR,
    ER_TOO_BIG_SET()                                    => STATUS_SEMANTIC_ERROR,
    ER_TOO_HIGH_LEVEL_OF_NESTING_FOR_SELECT()           => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_BODY()                                  => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_DATABASE_COMMENT()                      => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_FIELD_COMMENT()                         => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_IDENT()                                 => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_INDEX_COMMENT()                         => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_KEY()                                   => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_KEYPART()                               => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_STRING()                                => STATUS_CONFIGURATION_ERROR,
    ER_TOO_LONG_TABLE_COMMENT()                         => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_TABLE_PARTITION_COMMENT()               => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_CONCURRENT_TRXS()                       => STATUS_RUNTIME_ERROR,
    ER_TOO_MANY_DEFINITIONS_IN_WITH_CLAUSE()            => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_DELAYED_THREADS()                       => STATUS_RUNTIME_ERROR,
    ER_TOO_MANY_FIELDS()                                => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_KEYS()                                  => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_KEY_PARTS()                             => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_PARTITIONS_ERROR()                      => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_PARTITION_FUNC_FIELDS_ERROR()           => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_ROWS()                                  => STATUS_RUNTIME_ERROR,
    ER_TOO_MANY_TABLES()                                => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_USER_CONNECTIONS()                      => STATUS_CONFIGURATION_ERROR,
    ER_TOO_MANY_VALUES_ERROR()                          => STATUS_SEMANTIC_ERROR,
    ER_TOO_MUCH_AUTO_TIMESTAMP_COLS()                   => STATUS_SEMANTIC_ERROR,
    ER_TRANS_CACHE_FULL()                               => STATUS_CONFIGURATION_ERROR,
    ER_TRG_ALREADY_EXISTS()                             => STATUS_SEMANTIC_ERROR,
    ER_TRG_CANT_CHANGE_ROW()                            => STATUS_RUNTIME_ERROR,
    ER_TRG_CANT_OPEN_TABLE()                            => STATUS_ENVIRONMENT_FAILURE,
    ER_TRG_CORRUPTED_FILE()                             => STATUS_DATABASE_CORRUPTION,
    ER_TRG_DOES_NOT_EXIST()                             => STATUS_SEMANTIC_ERROR,
    ER_TRG_INVALID_CREATION_CTX()                       => STATUS_SEMANTIC_ERROR,
    ER_TRG_IN_WRONG_SCHEMA()                            => STATUS_SEMANTIC_ERROR,
    ER_TRG_NO_CREATION_CTX()                            => STATUS_SEMANTIC_ERROR,
    ER_TRG_NO_DEFINER()                                 => STATUS_DATABASE_CORRUPTION,
    ER_TRG_NO_SUCH_ROW_IN_TRG()                         => STATUS_RUNTIME_ERROR,
    ER_TRG_ON_VIEW_OR_TEMP_TABLE()                      => STATUS_SEMANTIC_ERROR,
    ER_TRUNCATED_WRONG_VALUE()                          => STATUS_RUNTIME_ERROR,
    ER_TRUNCATED_WRONG_VALUE_FOR_FIELD()                => STATUS_RUNTIME_ERROR,
    ER_TRUNCATE_ILLEGAL_FK()                            => STATUS_RUNTIME_ERROR,
    ER_UDF_EXISTS()                                     => STATUS_SEMANTIC_ERROR,
    ER_UDF_NO_PATHS()                                   => STATUS_SEMANTIC_ERROR,
    ER_UNACCEPTABLE_MUTUAL_RECURSION()                  => STATUS_SEMANTIC_ERROR,
    ER_UNDO_RECORD_TOO_BIG()                            => STATUS_RUNTIME_ERROR,
    ER_UNEXPECTED_EOF()                                 => STATUS_DATABASE_CORRUPTION,
    ER_UNION_TABLES_IN_DIFFERENT_DIR()                  => STATUS_SEMANTIC_ERROR,
    ER_UNIQUE_KEY_NEED_ALL_FIELDS_IN_PF()               => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_ALTER_ALGORITHM()                        => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_ALTER_LOCK()                             => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_CHARACTER_SET()                          => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_COLLATION()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_COMPRESSION_METHOD()                     => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_COM_ERROR()                              => STATUS_SYNTAX_ERROR,
    ER_UNKNOWN_DATA_TYPE()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_ERROR()                                  => STATUS_RUNTIME_ERROR,
    ER_UNKNOWN_EXPLAIN_FORMAT()                         => STATUS_SYNTAX_ERROR,
    ER_UNKNOWN_KEY_CACHE()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_LOCALE()                                 => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_OPERATOR()                               => STATUS_ENVIRONMENT_FAILURE,
    ER_UNKNOWN_OPTION()                                 => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_PARTITION()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_PROCEDURE()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_SEQUENCES()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_STMT_HANDLER()                           => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_STORAGE_ENGINE()                         => STATUS_CONFIGURATION_ERROR,
    ER_UNKNOWN_STRUCTURED_VARIABLE()                    => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_SYSTEM_VARIABLE()                        => STATUS_SYNTAX_ERROR,
    ER_UNKNOWN_TABLE()                                  => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_TARGET_BINLOG()                          => STATUS_REPLICATION_FAILURE,
    ER_UNKNOWN_TIME_ZONE()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_VIEW()                                   => STATUS_SEMANTIC_ERROR,
    ER_UNSUPPORTED_ACTION_ON_GENERATED_COLUMN()         => STATUS_UNSUPPORTED,
    ER_UNSUPPORTED_COLLATION()                          => STATUS_UNSUPPORTED,
    ER_UNSUPPORTED_ENGINE_FOR_GENERATED_COLUMNS()       => STATUS_UNSUPPORTED,
    ER_UNSUPPORTED_EXTENSION()                          => STATUS_UNSUPPORTED,
    ER_UNSUPPORTED_PS()                                 => STATUS_UNSUPPORTED,
    ER_UNSUPPORT_COMPRESSED_TEMPORARY_TABLE()           => STATUS_UNSUPPORTED,
    ER_UNSUPORTED_LOG_ENGINE()                          => STATUS_UNSUPPORTED,
    ER_UNTIL_COND_IGNORED()                             => STATUS_CONFIGURATION_ERROR,
    ER_UNTIL_REQUIRES_USING_GTID()                      => STATUS_SEMANTIC_ERROR,
    ER_UPDATED_COLUMN_ONLY_ONCE()                       => STATUS_SEMANTIC_ERROR,
    ER_UPDATES_WITH_CONSISTENT_SNAPSHOT()               => STATUS_SEMANTIC_ERROR,
    ER_UPDATE_LOG_DEPRECATED_IGNORED()                  => STATUS_CONFIGURATION_ERROR,
    ER_UPDATE_LOG_DEPRECATED_TRANSLATED()               => STATUS_CONFIGURATION_ERROR,
    ER_UPDATE_TABLE_USED()                              => STATUS_SEMANTIC_ERROR,
    ER_UPDATE_WITHOUT_KEY_IN_SAFE_MODE()                => STATUS_RUNTIME_ERROR,
    ER_USER_CREATE_EXISTS()                             => STATUS_SEMANTIC_ERROR,
    ER_USER_DROP_EXISTS()                               => STATUS_SEMANTIC_ERROR,
    ER_USER_IS_BLOCKED()                                => STATUS_ACL_ERROR,
    ER_USER_LIMIT_REACHED()                             => STATUS_CONFIGURATION_ERROR,
    ER_USER_LOCK_DEADLOCK()                             => STATUS_RUNTIME_ERROR,
    ER_USER_LOCK_WRONG_NAME()                           => STATUS_SEMANTIC_ERROR,
    ER_VALUES_IS_NOT_INT_TYPE_ERROR()                   => STATUS_SEMANTIC_ERROR,
    ER_VALUE_TOO_LONG()                                 => STATUS_RUNTIME_ERROR,
    ER_VARIABLE_IS_NOT_STRUCT()                         => STATUS_SEMANTIC_ERROR,
    ER_VARIABLE_IS_READONLY()                           => STATUS_SEMANTIC_ERROR,
    ER_VARIABLE_NOT_SETTABLE_IN_SF_OR_TRIGGER()         => STATUS_SEMANTIC_ERROR,
    ER_VARIABLE_NOT_SETTABLE_IN_SP()                    => STATUS_SEMANTIC_ERROR,
    ER_VARIABLE_NOT_SETTABLE_IN_TRANSACTION()           => STATUS_SEMANTIC_ERROR,
    ER_VAR_CANT_BE_READ()                               => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALREADY_VERSIONED()                         => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALTER_ENGINE_PROHIBITED()                   => STATUS_UNSUPPORTED,
    ER_VERS_ALTER_NOT_ALLOWED()                         => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALTER_SYSTEM_FIELD()                        => STATUS_SEMANTIC_ERROR,
    ER_VERS_DB_NOT_SUPPORTED()                          => STATUS_UNSUPPORTED,
    ER_VERS_DROP_PARTITION_INTERVAL()                   => STATUS_SEMANTIC_ERROR,
    ER_VERS_DUPLICATE_ROW_START_END()                   => STATUS_SEMANTIC_ERROR,
    ER_VERS_ENGINE_UNSUPPORTED()                        => STATUS_UNSUPPORTED,
    ER_VERS_FIELD_WRONG_TYPE()                          => STATUS_SEMANTIC_ERROR,
    ER_VERS_HIST_PART_FAILED()                          => STATUS_RUNTIME_ERROR,
    ER_VERS_NOT_ALLOWED()                               => STATUS_SEMANTIC_ERROR,
    ER_VERS_NOT_SUPPORTED()                             => STATUS_UNSUPPORTED,
    ER_VERS_NOT_VERSIONED()                             => STATUS_SEMANTIC_ERROR,
    ER_VERS_NO_TRX_ID()                                 => STATUS_SEMANTIC_ERROR,
    ER_VERS_PERIOD_COLUMNS()                            => STATUS_SEMANTIC_ERROR,
    ER_VERS_QUERY_IN_PARTITION()                        => STATUS_UNSUPPORTED,
    ER_VERS_RANGE_PROHIBITED()                          => STATUS_SEMANTIC_ERROR,
    ER_VERS_TABLE_MUST_HAVE_COLUMNS()                   => STATUS_SEMANTIC_ERROR,
    ER_VERS_TRT_IS_DISABLED()                           => STATUS_CONFIGURATION_ERROR,
    ER_VERS_TRX_PART_HISTORIC_ROW_NOT_SUPPORTED()       => STATUS_UNSUPPORTED,
    ER_VERS_WRONG_PARTS()                               => STATUS_SEMANTIC_ERROR,
    ER_VIEW_CHECKSUM()                                  => STATUS_DATABASE_CORRUPTION,
    ER_VIEW_CHECK_FAILED()                              => STATUS_RUNTIME_ERROR,
    ER_VIEW_DELETE_MERGE_VIEW()                         => STATUS_SEMANTIC_ERROR,
    ER_VIEW_FRM_NO_USER()                               => STATUS_DATABASE_CORRUPTION,
    ER_VIEW_INVALID()                                   => STATUS_RUNTIME_ERROR,
    ER_VIEW_INVALID_CREATION_CTX()                      => STATUS_SEMANTIC_ERROR,
    ER_VIEW_MULTIUPDATE()                               => STATUS_SEMANTIC_ERROR,
    ER_VIEW_NONUPD_CHECK()                              => STATUS_SEMANTIC_ERROR,
    ER_VIEW_NO_CREATION_CTX()                           => STATUS_SEMANTIC_ERROR,
    ER_VIEW_NO_EXPLAIN()                                => STATUS_ACL_ERROR,
    ER_VIEW_NO_INSERT_FIELD_LIST()                      => STATUS_SEMANTIC_ERROR,
    ER_VIEW_OTHER_USER()                                => STATUS_ACL_ERROR,
    ER_VIEW_ORDERBY_IGNORED()                           => STATUS_RUNTIME_ERROR,
    ER_VIEW_PREVENT_UPDATE()                            => STATUS_SEMANTIC_ERROR,
    ER_VIEW_RECURSIVE()                                 => STATUS_SEMANTIC_ERROR,
    ER_VIEW_SELECT_CLAUSE()                             => STATUS_SEMANTIC_ERROR,
    ER_VIEW_SELECT_DERIVED()                            => STATUS_SYNTAX_ERROR,
    ER_VIEW_SELECT_TMPTABLE()                           => STATUS_SEMANTIC_ERROR,
    ER_VIEW_SELECT_VARIABLE()                           => STATUS_SYNTAX_ERROR,
    ER_VIEW_WRONG_LIST()                                => STATUS_SEMANTIC_ERROR,
    ER_VIRTUAL_COLUMN_FUNCTION_IS_NOT_ALLOWED()         => STATUS_SEMANTIC_ERROR,
    ER_WARNING_NON_DEFAULT_VALUE_FOR_GENERATED_COLUMN() => STATUS_RUNTIME_ERROR,
    ER_WARNING_NOT_COMPLETE_ROLLBACK()                  => STATUS_RUNTIME_ERROR,
    ER_WARNING_NOT_COMPLETE_ROLLBACK_WITH_CREATED_TEMP_TABLE() => STATUS_RUNTIME_ERROR,
    ER_WARNING_NOT_COMPLETE_ROLLBACK_WITH_DROPPED_TEMP_TABLE() => STATUS_RUNTIME_ERROR,
    ER_WARN_AGGFUNC_DEPENDENCE()                        => STATUS_RUNTIME_ERROR,
    ER_WARN_ALLOWED_PACKET_OVERFLOWED()                 => STATUS_RUNTIME_ERROR,
    ER_WARN_CANT_DROP_DEFAULT_KEYCACHE()                => STATUS_SEMANTIC_ERROR,
    ER_WARN_DATA_OUT_OF_RANGE()                         => STATUS_RUNTIME_ERROR,
    ER_WARN_DEPRECATED_SYNTAX()                         => STATUS_SEMANTIC_ERROR,
    ER_WARN_DEPRECATED_SYNTAX_NO_REPLACEMENT()          => STATUS_SEMANTIC_ERROR,
    ER_WARN_DEPRECATED_SYNTAX_WITH_VER()                => STATUS_SEMANTIC_ERROR,
    ER_WARN_ENGINE_TRANSACTION_ROLLBACK()               => STATUS_RUNTIME_ERROR,
    ER_WARN_INDEX_NOT_APPLICABLE()                      => STATUS_RUNTIME_ERROR,
    ER_WARN_INVALID_TIMESTAMP()                         => STATUS_SEMANTIC_ERROR,
    ER_WARN_I_S_SKIPPED_TABLE()                         => STATUS_RUNTIME_ERROR,
    ER_WARN_HISTORY_ROW_START_TIME()                    => STATUS_RUNTIME_ERROR,
    ER_WARN_HOSTNAME_WONT_WORK()                        => STATUS_CONFIGURATION_ERROR,
    ER_WARN_LEGACY_SYNTAX_CONVERTED()                   => STATUS_UNSUPPORTED,
    ER_WARN_NULL_TO_NOTNULL()                           => STATUS_RUNTIME_ERROR,
    ER_WARN_ONLY_MASTER_LOG_FILE_NO_POS()               => STATUS_SEMANTIC_ERROR,
    ER_WARN_OPEN_TEMP_TABLES_MUST_BE_ZERO()             => STATUS_RUNTIME_ERROR,
    ER_WARN_PURGE_LOG_IN_USE()                          => STATUS_RUNTIME_ERROR,
    ER_WARN_PURGE_LOG_IS_ACTIVE()                       => STATUS_RUNTIME_ERROR,
    ER_WARN_QC_RESIZE()                                 => STATUS_CONFIGURATION_ERROR,
    ER_WARN_TOO_FEW_RECORDS()                           => STATUS_SEMANTIC_ERROR,
    ER_WARN_TOO_MANY_RECORDS()                          => STATUS_SEMANTIC_ERROR,
    ER_WARN_TRIGGER_DOESNT_HAVE_CREATED()               => STATUS_RUNTIME_ERROR,
    ER_WARN_USING_OTHER_HANDLER()                       => STATUS_RUNTIME_ERROR,
    ER_WARN_VIEW_MERGE()                                => STATUS_SEMANTIC_ERROR,
    ER_WARN_VIEW_WITHOUT_KEY()                          => STATUS_RUNTIME_ERROR,
    ER_WINDOW_FRAME_IN_REFERENCED_WINDOW_SPEC()         => STATUS_SEMANTIC_ERROR,
    ER_WINDOW_FUNCTION_DONT_HAVE_FRAME()                => STATUS_SEMANTIC_ERROR,
    ER_WINDOW_FUNCTION_IN_WINDOW_SPEC()                 => STATUS_SEMANTIC_ERROR,
    ER_WITH_COL_WRONG_LIST()                            => STATUS_SEMANTIC_ERROR,
    ER_WITH_TIES_NEEDS_ORDER()                          => STATUS_SYNTAX_ERROR,
    ER_WRONG_ARGUMENTS()                                => STATUS_SEMANTIC_ERROR,
    ER_WRONG_AUTO_KEY()                                 => STATUS_SEMANTIC_ERROR,
    ER_WRONG_COLUMN_NAME()                              => STATUS_SEMANTIC_ERROR,
    ER_WRONG_DB_NAME()                                  => STATUS_SYNTAX_ERROR,
    ER_WRONG_EXPR_IN_PARTITION_FUNC_ERROR()             => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FIELD_SPEC()                               => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FIELD_TERMINATORS()                        => STATUS_SYNTAX_ERROR,
    ER_WRONG_FIELD_WITH_GROUP()                         => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FK_DEF()                                   => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FK_OPTION_FOR_GENERATED_COLUMN()           => STATUS_SEMANTIC_ERROR,
    ER_WRONG_GROUP_FIELD()                              => STATUS_RUNTIME_ERROR,
    ER_WRONG_INSERT_INTO_SEQUENCE()                     => STATUS_SEMANTIC_ERROR,
    ER_WRONG_KEY_COLUMN()                               => STATUS_SEMANTIC_ERROR,
    ER_WRONG_LOCK_OF_SYSTEM_TABLE()                     => STATUS_RUNTIME_ERROR,
    ER_WRONG_MAGIC()                                    => STATUS_ENVIRONMENT_FAILURE,
    ER_WRONG_MRG_TABLE()                                => STATUS_RUNTIME_ERROR,
    ER_WRONG_NAME_FOR_CATALOG()                         => STATUS_SEMANTIC_ERROR,
    ER_WRONG_NAME_FOR_INDEX()                           => STATUS_SEMANTIC_ERROR,
    ER_WRONG_NATIVE_TABLE_STRUCTURE()                   => STATUS_DATABASE_CORRUPTION,
    ER_WRONG_NUMBER_OF_COLUMNS_IN_SELECT()              => STATUS_SEMANTIC_ERROR,
    ER_WRONG_NUMBER_OF_VALUES_IN_TVC()                  => STATUS_SEMANTIC_ERROR,
    ER_WRONG_OBJECT()                                   => STATUS_SEMANTIC_ERROR,
    ER_WRONG_OUTER_JOIN()                               => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARAMCOUNT_TO_CURSOR()                     => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARAMCOUNT_TO_NATIVE_FCT()                 => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARAMCOUNT_TO_PROCEDURE()                  => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARAMETERS_TO_NATIVE_FCT()                 => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARAMETERS_TO_PROCEDURE()                  => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARAMETERS_TO_STORED_FCT()                 => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARTITION_NAME()                           => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PERFSCHEMA_USAGE()                         => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PLACEMENT_OF_WINDOW_FUNCTION()             => STATUS_SEMANTIC_ERROR,
    ER_WRONG_SIZE_NUMBER()                              => STATUS_SEMANTIC_ERROR,
    ER_WRONG_SPVAR_TYPE_IN_LIMIT()                      => STATUS_SEMANTIC_ERROR,
    ER_WRONG_STRING_LENGTH()                            => STATUS_RUNTIME_ERROR,
    ER_WRONG_SUB_KEY()                                  => STATUS_SEMANTIC_ERROR,
    ER_WRONG_SUM_SELECT()                               => STATUS_SEMANTIC_ERROR,
    ER_WRONG_TABLE_NAME()                               => STATUS_SYNTAX_ERROR,
    ER_WRONG_TYPE_COLUMN_VALUE_ERROR()                  => STATUS_SEMANTIC_ERROR,
    ER_WRONG_TYPE_FOR_PERCENTILE_FUNC()                 => STATUS_SEMANTIC_ERROR,
    ER_WRONG_TYPE_FOR_RANGE_FRAME()                     => STATUS_SEMANTIC_ERROR,
    ER_WRONG_TYPE_FOR_ROWS_FRAME()                      => STATUS_SEMANTIC_ERROR,
    ER_WRONG_TYPE_FOR_VAR()                             => STATUS_SEMANTIC_ERROR,
    ER_WRONG_TYPE_OF_ARGUMENT()                         => STATUS_SEMANTIC_ERROR,
    ER_WRONG_USAGE()                                    => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE()                                    => STATUS_RUNTIME_ERROR,
    ER_WRONG_VALUE_COUNT()                              => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE_COUNT_ON_ROW()                       => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE_FOR_TYPE()                           => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE_FOR_VAR()                            => STATUS_SEMANTIC_ERROR,
    ER_WRONG_WINDOW_SPEC_NAME()                         => STATUS_SEMANTIC_ERROR,
    ER_WSAS_FAILED()                                    => STATUS_ENVIRONMENT_FAILURE,
    ER_XAER_DUPID()                                     => STATUS_SEMANTIC_ERROR,
    ER_XAER_INVAL()                                     => STATUS_UNSUPPORTED,
    ER_XAER_NOTA()                                      => STATUS_SEMANTIC_ERROR,
    ER_XAER_OUTSIDE()                                   => STATUS_RUNTIME_ERROR,
    ER_XAER_RMERR()                                     => STATUS_RUNTIME_ERROR,
    ER_XAER_RMFAIL()                                    => STATUS_SEMANTIC_ERROR,
    ER_XA_RBDEADLOCK()                                  => STATUS_RUNTIME_ERROR,
    ER_XA_RBROLLBACK()                                  => STATUS_RUNTIME_ERROR,
    ER_XA_RBTIMEOUT()                                   => STATUS_RUNTIME_ERROR,
    ER_ZLIB_Z_BUF_ERROR()                               => STATUS_ENVIRONMENT_FAILURE,
    ER_ZLIB_Z_DATA_ERROR()                              => STATUS_IGNORED_ERROR, # MDEV-16698, MDEV-16699
    ER_ZLIB_Z_MEM_ERROR()                               => STATUS_ENVIRONMENT_FAILURE,

    HA_ERR_TABLE_DEF_CHANGED()                          => STATUS_RUNTIME_ERROR,

    WARN_COND_ITEM_TRUNCATED()                          => STATUS_RUNTIME_ERROR,
    WARN_DATA_TRUNCATED()                               => STATUS_RUNTIME_ERROR,
    WARN_INNODB_PARTITION_OPTION_IGNORED()              => STATUS_RUNTIME_ERROR,
    WARN_NON_ASCII_SEPARATOR_NOT_IMPLEMENTED()          => STATUS_UNSUPPORTED,
    WARN_NO_MASTER_INFO()                               => STATUS_SEMANTIC_ERROR,
    WARN_ON_BLOCKHOLE_IN_RBR()                          => STATUS_CONFIGURATION_ERROR,
    WARN_OPTION_BELOW_LIMIT()                           => STATUS_SEMANTIC_ERROR,
    WARN_OPTION_IGNORED()                               => STATUS_CONFIGURATION_ERROR,
    WARN_PLUGIN_BUSY()                                  => STATUS_SEMANTIC_ERROR,
    WARN_SFORMAT_ERROR()                                => STATUS_RUNTIME_ERROR,
    WARN_VERS_PARAMETERS()                              => STATUS_SEMANTIC_ERROR,
    WARN_VERS_PART_FULL()                               => STATUS_RUNTIME_ERROR,
    WARN_VERS_PART_NON_HISTORICAL()                     => STATUS_RUNTIME_ERROR,
);

# Sub-error numbers (<nr>) from storage engine failures (ER_GET_ERRNO);
# "1030 Got error <nr> from storage engine", which should not lead to
# STATUS_DATABASE_CORRUPTION, as they are acceptable runtime errors.

my %acceptable_se_errors = (
        139                     => "TOO_BIG_ROW"
);

my $query_no = 0;


sub init {
    my $executor = shift;
    my $dbh = DBI->connect($executor->dsn(), undef, undef, {
        PrintError => 0,
        RaiseError => 0,
        AutoCommit => 1,
        mysql_multi_statements => 1,
        mysql_auto_reconnect => 1
    } );

    if (not defined $dbh) {
        sayError("connect() to dsn ".$executor->dsn()." failed: ".$DBI::errstr);
        return STATUS_ENVIRONMENT_FAILURE;
    }

    $executor->setDbh($dbh);

    my $service_dbh = DBI->connect($executor->dsn(), undef, undef, {
        PrintError => 0,
        RaiseError => 0,
        AutoCommit => 1,
        mysql_multi_statements => 1,
        mysql_auto_reconnect => 1
    } );

    if (not defined $service_dbh) {
        sayError("connect() to dsn ".$executor->dsn()." (service connection) failed: ".$DBI::errstr);
        return STATUS_ENVIRONMENT_FAILURE;
    }

    $executor->setServiceDbh($service_dbh);

    my ($host) = $executor->dsn() =~ m/:host=([^:]+):/;
    $executor->setHost($host);
    my ($port) = $executor->dsn() =~ m/:port=([^:]+):/;
    $executor->setPort($port);

    $executor->version();
    $executor->serverVariables();

    #
    # Hack around bug 35676, optiimzer_switch must be set sesson-wide in order to have effect
    # So we read it from the GLOBAL_VARIABLE table and set it locally to the session
    # Please leave this statement on a single line, which allows easier correct parsing from general log.
    #

    $dbh->do("SET optimizer_switch=(SELECT variable_value FROM INFORMATION_SCHEMA.GLOBAL_VARIABLES WHERE VARIABLE_NAME='optimizer_switch')");
#    $dbh->do("SET TIMESTAMP=".Time::HiRes::time());

    $executor->defaultSchema($executor->currentSchema());

    if (
        ($executor->fetchMethod() == FETCH_METHOD_AUTO) ||
        ($executor->fetchMethod() == FETCH_METHOD_USE_RESULT)
    ) {
        say("Setting mysql_use_result to 1, so mysql_use_result() will be used.") if rqg_debug();
#        $dbh->{'mysql_use_result'} = 1;
    } elsif ($executor->fetchMethod() == FETCH_METHOD_STORE_RESULT) {
        say("Setting mysql_use_result to 0, so mysql_store_result() will be used.") if rqg_debug();
#        $dbh->{'mysql_use_result'} = 0;
    }

    my $cidref= $dbh->selectrow_arrayref("SELECT CONNECTION_ID()");
    if ($dbh->err) {
        sayError("Couldn't get connection ID: " . $dbh->err() . " (" . $dbh->errstr() .")");
    }

    $executor->setConnectionId($cidref->[0]);
    $executor->setCurrentUser($dbh->selectrow_arrayref("SELECT CURRENT_USER()")->[0]);
    $dbh->do('SELECT '.GenTest::Random::dataLocation().' AS DATA_LOCATION');

    say("Executor initialized. id: ".$executor->id()."; default schema: ".$executor->defaultSchema()."; connection ID: ".$executor->connectionId()) if rqg_debug();

    return STATUS_OK;
}

sub reportError {
    my ($self, $query, $err, $errstr, $execution_flags) = @_;

    my $msg = [$query,$err,$errstr];

    if (not ($execution_flags & EXECUTOR_FLAG_SILENT)) {
      if (defined $self->channel) {
          $self->sendError($msg);
      } elsif (not defined $reported_errors{$errstr}) {
          my $query_for_print= shorten_message($query);
          say("Executor: Query: $query_for_print failed: $err $errstr (" . status2text(errorType($err)) . "). Further errors of this kind will be suppressed.");
          $reported_errors{$errstr}++;
      }
    }
}

sub execute {
    my ($executor, $query, $execution_flags) = @_;
    $execution_flags= 0 unless defined $execution_flags;

    if (!rqg_debug() && $query =~ s/\/\*\s*EXECUTOR_FLAG_SILENT\s*\*\///g) {
        $execution_flags |= EXECUTOR_FLAG_SILENT;
    }

    # It turns out that MySQL fails with a syntax error upon executable comments of the kind /*!100101 ... */
    # (with 6 digits for the version), so we have to process them here as well.
    # To avoid complicated logic, we'll replace such executable comments with plain ones
    # but only when the server vesion is 5xxxx

    if ($executor->versionNumeric() =~ /^05\d{4}$/) {
      while ($query =~ s/\/\*\!1\d{5}/\/\*/g) {};
    }

    # Filter out any /*executor */ comments that do not pertain to this particular Executor/DBI
    if (index($query, 'executor') > -1) {
        my $executor_id = $executor->id();
        $query =~ s{/\*executor$executor_id (.*?) \*/}{$1}sg;
        $query =~ s{/\*executor.*?\*/}{}sgo;
    }

    # Due to use of empty rules in stored procedure bodies and alike,
    # the query can have a sequence of semicolons "; ;" or "BEGIN ; ..."
    # which will cause syntax error. We'll clean them up
    while ($query =~ s/^\s*;//gs) {}
    while ($query =~ s/;\s*;/;/gs) {}
    while ($query =~ s/(PROCEDURE.*)BEGIN\s*;/${1}BEGIN /g) {}
    # Or occasionaly "x AS alias1 AS alias2"
    while ($query =~ s/AS\s+\w+\s+(AS\s+\w+)/$1/g) {}

    my $qno_comment= 'QNO ' . $query_no . ' CON_ID ' . $executor->connectionId();
    $query_no++ if $executor->id == 1;
    # If a query starts with an executable comment, we'll put QNO right after the executable comment
    if ($query =~ s/^\s*(\/\*\!.*?\*\/)/$1 \/\* $qno_comment \*\//) {}
    # If a query starts with a non-executable comment, we'll put QNO into this comment
    elsif ($query =~ s/^\s*\/\*(.*?)\*\//\/\* $qno_comment $1 \*\//) {}
    # Otherwise we'll put QNO comment after the first token (it should be a keyword specifying the operation)
    elsif ($query =~ s/^\s*(\w+)/$1 \/\* $qno_comment \*\//) {}
    # Finally, if it's something else that we didn't expect, we'll add QNO at the end of the query
    else { $query .= " /* $qno_comment */" };

    # Check for execution flags in query comments. They can, for example,
    # indicate that a query is intentionally invalid, and the error
    # doesn't need to be reported.
    # The format for it is /* EXECUTOR_FLAG_SILENT */, currently only this flag is supported in queries

    # Add global flags if any are set
    $execution_flags = $execution_flags | $executor->flags();

    my $dbh = $executor->dbh();

    return GenTest::Result->new( query => $query, status => STATUS_UNKNOWN_ERROR ) if not defined $dbh;

    if (
        (not defined $executor->[EXECUTOR_MYSQL_AUTOCOMMIT]) &&
        ($query =~ m{^\s*(start\s+transaction|begin|commit|rollback)}io)
    ) {
        $dbh->do("SET AUTOCOMMIT=OFF");
        $executor->[EXECUTOR_MYSQL_AUTOCOMMIT] = 0;

        if ($executor->fetchMethod() == FETCH_METHOD_AUTO) {
            say("Transactions detected. Setting mysql_use_result to 0, so mysql_store_result() will be used.") if rqg_debug();
            $dbh->{'mysql_use_result'} = 0;
        }
    }

    my $trace_query;
    my $trace_me = 0;


    # Write query to log before execution so it's sure to get there
    if ($executor->sqltrace) {
        if ($query =~ m{(procedure|function)}sgio) {
            $trace_query = "DELIMITER |\n$query|\nDELIMITER ";
        } else {
            $trace_query = $query;
        }
        # MarkErrors logging can only be done post-execution
        if ($executor->sqltrace eq 'MarkErrors') {
            $trace_me = 1;   # Defer logging
        } else {
            print "$trace_query;\n";
        }
    }

    my $start_time = Time::HiRes::time();
    # Combination of mysql_server_prepare and mysql_multi_statements
    # still causes troubles (syntax errors), both with mysql and MariaDB drivers
    my $sth = (index($query,";") == -1) ? $dbh->prepare($query) : $dbh->prepare($query, { mysql_server_prepare => 0 });

    if (not defined $sth) {            # Error on PREPARE
        #my $errstr_prepare = $executor->normalizeError($dbh->errstr());
        $executor->[EXECUTOR_ERROR_COUNTS]->{$dbh->err}++;
        return GenTest::Result->new(
            query        => $query,
            status        => errorType($dbh->err()),
            err        => $dbh->err(),
            errstr         => $dbh->errstr(),
            sqlstate    => $dbh->state(),
            start_time    => $start_time,
            end_time    => Time::HiRes::time()
        );
    }

    my $affected_rows = $sth->execute();
    my $end_time = Time::HiRes::time();
    my $execution_time = $end_time - $start_time;

    my $err = $sth->err();
    my $errstr = $executor->normalizeError($sth->errstr()) if defined $sth->errstr();
    my $err_type = STATUS_OK;
    if (defined $err) {
      $err_type= errorType($err);
      if ($err == ER_GET_ERRNO) {
          my ($se_err) = $sth->errstr() =~ m{^Got error\s+(\d+)\s+from storage engine}sgio;
          $err_type = STATUS_OK if (defined $se_err and defined $acceptable_se_errors{$se_err});
      }
    }
    $executor->[EXECUTOR_STATUS_COUNTS]->{$err_type}++;
    my $mysql_info = $dbh->{'mysql_info'};
    $mysql_info= '' unless defined $mysql_info;
    my ($matched_rows, $changed_rows) = $mysql_info =~ m{^Rows matched:\s+(\d+)\s+Changed:\s+(\d+)}sgio;

    my $column_names = $sth->{NAME} if $sth and $sth->{NUM_OF_FIELDS};
    my $column_types = $sth->{mysql_type_name} if $sth and $sth->{NUM_OF_FIELDS};

    if ($trace_me eq 1) {
        if (defined $err) {
                # Mark invalid queries in the trace by prefixing each line.
                # We need to prefix all lines of multi-line statements also.
                $trace_query =~ s/\n/\n# [sqltrace]    /g;
                print "# [$$] [sqltrace] ERROR ".$err.": $trace_query;\n";
        } else {
            print "[$$] $trace_query;\n";
        }
    }

    my $result;
    if (defined $err)
    {  # Error on EXECUTE
        $executor->[EXECUTOR_ERROR_COUNTS]->{$err}++;
        if ($execution_flags & EXECUTOR_FLAG_SILENT) {
          $executor->[EXECUTOR_SILENT_ERRORS_COUNT] = $executor->[EXECUTOR_SILENT_ERRORS_COUNT] ? $executor->[EXECUTOR_SILENT_ERRORS_COUNT] + 1 : 1;
        }
        if (
            ($err_type == STATUS_SKIP) ||
            ($err_type == STATUS_UNSUPPORTED) ||
            ($err_type == STATUS_SEMANTIC_ERROR) ||
            ($err_type == STATUS_CONFIGURATION_ERROR) ||
            ($err_type == STATUS_ACL_ERROR) ||
            ($err_type == STATUS_RUNTIME_ERROR)
        ) {
            $executor->reportError($query, $err, $errstr, $execution_flags);
        } elsif (
            ($err_type == STATUS_SERVER_CRASHED) ||
            ($err_type == STATUS_SERVER_KILLED)
        ) {
            $dbh = DBI->connect($executor->dsn(), undef, undef, {
                PrintError => 0,
                RaiseError => 0,
                AutoCommit => 1,
                mysql_multi_statements => 1,
                mysql_auto_reconnect => 1
            } );

            # If server is still connectable, it is not a real crash, but most likely a KILL query

            if (defined $dbh) {
                say("Executor::MariaDB::execute: Successfully reconnected after getting " . status2text($err_type));
                $err_type = STATUS_SEMANTIC_ERROR;
                $executor->setDbh($dbh);
            } else {
                sayError("Executor::MariaDB::execute: Failed to reconnect after getting " . status2text($err_type));
            }

            my $query_for_print= shorten_message($query);
            if (not ($execution_flags & EXECUTOR_FLAG_SILENT)) {
              say("Executor::MariaDB::execute: Query: $query_for_print failed: $err ".$sth->errstr().($err_type?" (".status2text($err_type).")":""));
            }
        } elsif (not ($execution_flags & EXECUTOR_FLAG_SILENT)) {
            # Always print syntax and uncategorized errors, unless specifically asked not to
            my $query_for_print= shorten_message($query);
            say("Executor::MariaDB::execute: Query: $query_for_print failed: $err ".$sth->errstr().($err_type?" (".status2text($err_type).")":""));
        }

        $result = GenTest::Result->new(
            query        => $query,
            status        => $err_type || STATUS_UNKNOWN_ERROR,
            err        => $err,
            errstr        => $errstr,
            sqlstate    => $sth->state(),
            start_time    => $start_time,
            end_time    => $end_time,
        );
    } elsif ((not defined $sth->{NUM_OF_FIELDS}) || ($sth->{NUM_OF_FIELDS} == 0)) {
        $result = GenTest::Result->new(
            query        => $query,
            status        => STATUS_OK,
            affected_rows    => $affected_rows,
            matched_rows    => $matched_rows,
            changed_rows    => $changed_rows,
            info        => $mysql_info,
            start_time    => $start_time,
            end_time    => $end_time,
        );
        $executor->[EXECUTOR_ERROR_COUNTS]->{'(no error)'}++;
    } else {
        my @data;
        my %data_hash;
        my $row_count = 0;
        my $result_status = STATUS_OK;

        while (my @row = $sth->fetchrow_array()) {
            $row_count++;
            push @data, \@row;
            last if ($row_count > MAX_ROWS_THRESHOLD);
        }

        # Do one extra check to catch 'query execution was interrupted' error
        if (defined $sth->err()) {
            $result_status = errorType($sth->err());
            @data = ();
        } elsif ($row_count > MAX_ROWS_THRESHOLD) {
            my $query_for_print= shorten_message($query);
            say("Query: $query_for_print returned more than MAX_ROWS_THRESHOLD (".MAX_ROWS_THRESHOLD().") rows. Killing it ...");
            $executor->[EXECUTOR_RETURNED_ROW_COUNTS]->{'>MAX_ROWS_THRESHOLD'}++;

            my $kill_dbh = DBI->connect($executor->dsn(), undef, undef, { PrintError => 1 });
            $kill_dbh->do("KILL QUERY ".$executor->connectionId());
            $kill_dbh->disconnect();
            $sth->finish();
            $dbh->do("SELECT 1 FROM DUAL /* Guard query so that the KILL QUERY we just issued does not affect future queries */;");
            @data = ();
            $result_status = STATUS_SKIP;
        }

        $result = GenTest::Result->new(
            query        => $query,
            status        => $result_status,
            affected_rows     => $affected_rows,
            data        => \@data,
            start_time    => $start_time,
            end_time    => $end_time,
            column_names    => $column_names,
            column_types    => $column_types,
        );

        $executor->[EXECUTOR_ERROR_COUNTS]->{'(no error)'}++;
    }

    $sth->finish();

    if (defined $err or $sth->{mysql_warning_count} > 0) {
        eval {
            my $warnings = $dbh->selectall_arrayref("SHOW WARNINGS");
            $result->setWarnings($warnings);
        }
    }

    if (rqg_debug() && (! ($execution_flags & EXECUTOR_FLAG_SILENT))) {
        if ($query =~ m{^\s*(?:select|insert|replace|delete|update)}is) {
            $executor->explain($query);

            if ($result->status() != STATUS_SKIP) {
                my $row_group = ((not defined $result->rows()) ? 'undef' : ($result->rows() > 100 ? '>100' : ($result->rows() > 10 ? ">10" : sprintf("%5d",$sth->rows()))));
                $executor->[EXECUTOR_RETURNED_ROW_COUNTS]->{$row_group}++;
            }
            if ($query =~ m{^\s*(update|delete|insert|replace)}is) {
                my $row_group = ((not defined $affected_rows) ? 'undef' : ($affected_rows > 100 ? '>100' : ($affected_rows > 10 ? ">10" : sprintf("%5d",$affected_rows))));
                $executor->[EXECUTOR_AFFECTED_ROW_COUNTS]->{$row_group}++;
            }
        }
    }

    return $result;
}

sub serverVariables {
    my $executor= shift;
    if (not keys %{$executor->[EXECUTOR_MYSQL_SERVER_VARIABLES]}) {
        my $sth = $executor->dbh()->prepare("SHOW VARIABLES");
        $sth->execute();
        my %vars = ();
        while (my $array_ref = $sth->fetchrow_arrayref()) {
            $vars{$array_ref->[0]} = $array_ref->[1];
        }
        $sth->finish();
        $executor->[EXECUTOR_MYSQL_SERVER_VARIABLES] = \%vars;
    }
    return $executor->[EXECUTOR_MYSQL_SERVER_VARIABLES];
}

sub serverVariable {
    my ($executor, $variable_name)= @_;
    return $executor->dbh()->selectrow_array('SELECT @@'.$variable_name);
}

sub version {
    my $executor = shift;
    my $ver= $executor->serverVersion;
    unless ($ver) {
        $ver= $executor->dbh()->selectrow_array("SELECT VERSION()");
        $executor->setServerVersion($ver);
        $ver =~ /([0-9]+)\.([0-9]+)\.([0-9]+)/;
        $ver =~ /^(\d+\.\d+)/;
        $executor->setServerMajorVersion($1);
    }
    return $ver;
}

sub versionNumeric {
    return versionN6($_[0]->serverVersion);
}

sub serverName {
    return ($_[0]->serverVersion =~ /mariadb/i ? 'MariaDB' : 'MySQL');
}

sub slaveInfo {
    my $executor = shift;
    my $slave_info = $executor->dbh()->selectrow_arrayref("SHOW SLAVE HOSTS");
    return ($slave_info->[SLAVE_INFO_HOST], $slave_info->[SLAVE_INFO_PORT]);
}

sub masterStatus {
    my $executor = shift;
    return $executor->dbh()->selectrow_array("SHOW MASTER STATUS");
}

#
# Run EXPLAIN on the query in question, recording all notes in the EXPLAIN's Extra field into the statistics
#

sub explain {
    my ($executor, $query) = @_;

    return unless is_query_explainable($executor,$query);

    my $sth_output = $executor->dbh()->prepare("EXPLAIN /*!50100 PARTITIONS */ $query");

    $sth_output->execute();

    my @explain_fragments;

    while (my $explain_row = $sth_output->fetchrow_hashref()) {

        push @explain_fragments, "select_type: ".($explain_row->{select_type} || '(empty)');
        push @explain_fragments, "type: ".($explain_row->{type} || '(empty)');
        push @explain_fragments, "partitions: ".$explain_row->{table}.":".$explain_row->{partitions} if defined $explain_row->{partitions};
        push @explain_fragments, "possible_keys: ".(defined $explain_row->{possible_keys} ? $explain_row->{possible_keys} : '');
        push @explain_fragments, "key: ".(defined $explain_row->{key} ? $explain_row->{key} : '');
        push @explain_fragments, "ref: ".(defined $explain_row->{ref} ? $explain_row->{ref} : '');

        foreach my $extra_item (split('; ', ($explain_row->{Extra} || '(empty)')) ) {
            $extra_item =~ s{0x.*?\)}{%d\)}sgio;
            $extra_item =~ s{PRIMARY|[a-z_]+_key|i_l_[a-z_]+}{%s}sgio;
            push @explain_fragments, "extra: ".$extra_item;
        }
    }

    $executor->dbh()->do("EXPLAIN EXTENDED $query");
    my $explain_extended = $executor->dbh()->selectrow_arrayref("SHOW WARNINGS");
    if (defined $explain_extended) {
        push @explain_fragments, $explain_extended->[2] =~ m{<[a-z_0-9\-]*?>}sgo;
    }

    foreach my $explain_fragment (@explain_fragments) {
        $executor->[EXECUTOR_EXPLAIN_COUNTS]->{$explain_fragment}++;
        if ($executor->[EXECUTOR_EXPLAIN_COUNTS]->{$explain_fragment} > RARE_QUERY_THRESHOLD) {
            delete $executor->[EXECUTOR_EXPLAIN_QUERIES]->{$explain_fragment};
        } else {
            push @{$executor->[EXECUTOR_EXPLAIN_QUERIES]->{$explain_fragment}}, $query;
        }
    }

}

# If Oracle ever issues 5.10.x, this logic will stop working.
# Until then it should be fine
sub is_query_explainable {
    my ($executor, $query) = @_;
    if ( $executor->serverMajorVersion > 5.5 ) {
        return $query =~ /^\s*(?:SELECT|UPDATE|DELETE|INSERT)/i;
    } else {
        return $query =~ /^\s*SELECT/;
    }
}

sub disconnect {
    my $executor = shift;
    $executor->dbh()->disconnect() if defined $executor->dbh();
    $executor->setDbh(undef);
}

sub DESTROY {
    my $executor = shift;
    $executor->disconnect();

    say("-----------------------");
    say("Statistics for Executor ".$executor->dsn());
    if (
        (rqg_debug()) &&
        (defined $executor->[EXECUTOR_STATUS_COUNTS])
    ) {
        use Data::Dumper;
        $Data::Dumper::Sortkeys = 1;
        say("Rows returned:");
        print Dumper $executor->[EXECUTOR_RETURNED_ROW_COUNTS];
        say("Rows affected:");
        print Dumper $executor->[EXECUTOR_AFFECTED_ROW_COUNTS];
        say("Explain items:");
        print Dumper $executor->[EXECUTOR_EXPLAIN_COUNTS];
        say("Errors:");
        print Dumper $executor->[EXECUTOR_ERROR_COUNTS];
        if ($executor->[EXECUTOR_SILENT_ERRORS_COUNT]) {
          say("Out of the above, ".$executor->[EXECUTOR_SILENT_ERRORS_COUNT]." errors had SILENT flag");
        }
#        say("Rare EXPLAIN items:");
#        print Dumper $executor->[EXECUTOR_EXPLAIN_QUERIES];
    }
    say("Statuses: ".join(', ', map { status2text($_).": ".$executor->[EXECUTOR_STATUS_COUNTS]->{$_}." queries" } sort keys %{$executor->[EXECUTOR_STATUS_COUNTS]}));
    say("-----------------------");
}

sub currentSchema {
    my ($executor,$schema) = @_;

    return undef if not defined $executor->dbh();

    if (defined $schema) {
        $executor->execute("USE $schema");
    }

    return $executor->dbh()->selectrow_array("SELECT DATABASE()");
}

sub errorType {
    return undef if not defined $_[0];
    return STATUS_OK if $_[0] == 0;
    return $err2type{$_[0]} || STATUS_UNKNOWN_ERROR ;
}

sub normalizeError {
    my ($executor, $errstr) = @_;

    foreach my $i (0..$#errors) {
        last if $errstr =~ s{$patterns[$i]}{$errors[$i]}s;
    }

    $errstr =~ s{\d+}{%d}sgio if $errstr !~ m{from storage engine}is; # Make all errors involving numbers the same, e.g. duplicate key errors

    $errstr =~ s{\.\*\?}{%s}sgio;

    return $errstr;
}


sub getSchemaMetaData {
    ## Return the result from a query with the following columns:
    ## 1. Schema (aka database) name
    ## 2. Table name
    ## 3. TABLE for tables VIEW for views and MISC for other stuff
    ## 4. Column name
    ## 5. PRIMARY for primary key, INDEXED for indexed column and "ORDINARY" for all other columns
    ## 6. generalized data type (INT, FLOAT, BLOB, etc.)
    ## 7. real data type
    my ($self, $redo) = @_;

    # TODO: recognize SEQUENCE as a separate type with separate logic

    # Unset max_statement_time in case it was set in test configuration
    $self->dbh()->do('/*!100108 SET @@max_statement_time= 0 */');
    my $query =
        "SELECT DISTINCT ".
                "CASE WHEN table_schema = 'information_schema' ".
                     "THEN 'INFORMATION_SCHEMA' ".  ## Hack due to
                                                    ## weird MySQL
                                                    ## behaviour on
                                                    ## schema names
                                                    ## (See Bug#49708)
                     "ELSE table_schema END AS table_schema, ".
               "table_name, ".
               "CASE WHEN table_type = 'BASE TABLE' THEN 'table' ".
                    "WHEN table_type = 'SYSTEM VERSIONED' THEN 'versioned' ".
                    "WHEN table_type = 'SEQUENCE' THEN 'sequence' ".
                    "WHEN table_type = 'VIEW' THEN 'view' ".
                    "WHEN table_type = 'SYSTEM VIEW' then 'view' ".
                    "ELSE 'misc' END AS table_type, ".
               "column_name, ".
               "CASE WHEN column_key = 'PRI' THEN 'primary' ".
                    "WHEN column_key IN ('MUL','UNI') THEN 'indexed' ".
                    "ELSE 'ordinary' END AS column_key, ".
               "CASE WHEN data_type IN ('bit','tinyint','smallint','mediumint','int','bigint') THEN 'int' ".
                    "WHEN data_type IN ('float','double') THEN 'float' ".
                    "WHEN data_type IN ('decimal') THEN 'decimal' ".
                    "WHEN data_type IN ('datetime','timestamp') THEN 'timestamp' ".
                    "WHEN data_type IN ('char','varchar','binary','varbinary') THEN 'char' ".
                    "WHEN data_type IN ('tinyblob','blob','mediumblob','longblob') THEN 'blob' ".
                    "WHEN data_type IN ('tinytext','text','mediumtext','longtext') THEN 'blob' ".
                    "ELSE data_type END AS data_type_normalized, ".
               "data_type, ".
               "character_maximum_length, ".
               "table_rows ".
         "FROM information_schema.tables INNER JOIN ".
              "information_schema.columns USING(table_schema,table_name) ";
    # Do not reload metadata for system tables
    if ($redo) {
      $query.= " AND table_schema NOT IN ('performance_schema','information_schema','mysql')";
    }

    my $res = $self->dbh()->selectall_arrayref($query);
    if ($res) {
        say("Finished reading metadata from the database: $#$res entries");
    } else {
        sayError("Failed to retrieve schema metadata: " . $self->dbh()->err . " " . $self->dbh()->errstr);
    }
    $self->dbh()->do('/*!100108 SET @@max_statement_time= @@global.max_statement_time */');

    return $res;
}

sub getCollationMetaData {
    ## Return the result from a query with the following columns:
    ## 1. Collation name
    ## 2. Character set
    my ($self) = @_;
    my $query =
        "SELECT collation_name,character_set_name FROM information_schema.collations";

    return $self->dbh()->selectall_arrayref($query);
}

sub read_only {
    my $executor = shift;
    my $dbh = $executor->dbh();
    my ($grant_command) = $dbh->selectrow_array("SHOW GRANTS FOR CURRENT_USER()");
    my ($grants) = $grant_command =~ m{^grant (.*?) on}is;
    if (uc($grants) eq 'SELECT') {
        return 1;
    } else {
        return 0;
    }
}

sub loadMetaData {
  # Type can be 'system' or 'non-system'
  my ($self, $metadata_type)= @_;
  my $system_schemata= "'mysql','information_schema','performance_schema','sys'";
  my $exempt_schemata= "'transforms'";
  my $clause;
  if ($metadata_type eq 'system') {
    $clause= "table_schema IN ($system_schemata)"
  } elsif ($metadata_type eq 'non-system') {
    $clause= "table_schema NOT IN ($system_schemata,$exempt_schemata) and table_schema NOT LIKE 'private_%'"
  } else {
    sayError("Unknown metadata type requested: $metadata_type");
    return undef;
  }

  my $table_query=
      "SELECT table_schema, table_name, table_type ".
      "FROM information_schema.tables WHERE $clause";
  my $column_query=
      "SELECT table_schema, table_name, column_name, column_key, ".
             "data_type, character_maximum_length ".
      "FROM information_schema.columns WHERE $clause";
  my $index_query=
      "SELECT table_schema, table_name, index_name, non_unique XOR 1 ".
      "FROM information_schema.statistics WHERE $clause";

  sayDebug("Metadata reload: Starting reading $metadata_type metadata with condition \"$clause\"");

  my ($table_metadata, $column_metadata, $index_metadata);
  my $dbh= $self->serviceDbh();
  $table_metadata= $dbh->selectall_arrayref($table_query);
  if (not $dbh->err and $table_metadata) {
    $column_metadata= $dbh->selectall_arrayref($column_query);
    if (not $dbh->err) {
      $index_metadata= $dbh->selectall_arrayref($index_query);
    }
  }
  if ($dbh->err or not $table_metadata or not $column_metadata) {
    sayError("MetadataReload: Failed to retrieve metadata with condition \"$clause\": " . $dbh->err . " " . $dbh->errstr);
    return undef;
  } else {
    say("MetadataReload: Finished reading $metadata_type metadata: ".scalar(@$table_metadata)." tables, ".scalar(@$column_metadata)." columns, ".scalar(@$index_metadata)." indexes");
  }

  my $meta= {};
  my %tabletype= ();

  foreach my $row (@$table_metadata) {
    my ($schema, $table, $type) = @$row;
    if    ($type eq 'BASE TABLE') { $type= 'table' }
    elsif ($type eq 'SYSTEM VERSIONED') { $type = 'versioned' }
    elsif ($type eq 'SEQUENCE') { $type = 'sequence' }
    elsif (
      $type eq 'VIEW' or
      $type eq 'SYSTEM VIEW'
    ) { $type= 'view' }
    else { $type= 'misc' };
    if (lc($schema) eq 'information_schema') {
      $meta->{information_schema}={} if not exists $meta->{information_schema};
      $meta->{information_schema}->{$type}={} if not exists $meta->{information_schema}->{$type};
      $meta->{information_schema}->{$type}->{$table}={} if not exists $meta->{information_schema}->{$type}->{$table};
      $meta->{information_schema}->{$type}->{$table}->{col}={} if not exists $meta->{information_schema}->{$type}->{$table}->{col};
      $meta->{information_schema}->{$type}->{$table}->{key}={} if not exists $meta->{information_schema}->{$type}->{$table}->{key};
      $tabletype{'information_schema.'.$table}= $type;
      $meta->{INFORMATION_SCHEMA}={} if not exists $meta->{INFORMATION_SCHEMA};
      $meta->{INFORMATION_SCHEMA}->{$type}={} if not exists $meta->{INFORMATION_SCHEMA}->{$type};
      $meta->{INFORMATION_SCHEMA}->{$type}->{$table}={} if not exists $meta->{INFORMATION_SCHEMA}->{$type}->{$table};
      $meta->{INFORMATION_SCHEMA}->{$type}->{$table}->{col}={} if not exists $meta->{INFORMATION_SCHEMA}->{$type}->{$table}->{col};
      $meta->{INFORMATION_SCHEMA}->{$type}->{$table}->{key}={} if not exists $meta->{INFORMATION_SCHEMA}->{$type}->{$table}->{key};
      $tabletype{'INFORMATION_SCHEMA.'.$table}= $type;
    } else {
      $meta->{$schema}={} if not exists $meta->{$schema};
      $meta->{$schema}->{$type}={} if not exists $meta->{$schema}->{$type};
      $meta->{$schema}->{$type}->{$table}={} if not exists $meta->{$schema}->{$type}->{$table};
      $meta->{$schema}->{$type}->{$table}->{col}={} if not exists $meta->{$schema}->{$type}->{$table}->{col};
      $meta->{$schema}->{$type}->{$table}->{key}={} if not exists $meta->{$schema}->{$type}->{$table}->{key};
      $tabletype{$schema.'.'.$table}= $type;
    }
  }

  foreach my $row (@$column_metadata) {
    my ($schema, $table, $col, $key, $realtype, $maxlength) = @$row;
    my $metatype= lc($realtype);
    if (
      $metatype eq 'bit' or
      $metatype eq 'tinyint' or
      $metatype eq 'smallint' or
      $metatype eq 'mediumint' or
      $metatype eq 'bigint'
    ) { $metatype= 'int' }
    elsif (
      $metatype eq 'double'
    ) { $metatype= 'float' }
    elsif (
      $metatype eq 'datetime'
    ) { $metatype= 'timestamp' }
    elsif (
      $metatype eq 'varchar' or
      $metatype eq 'binary' or
      $metatype eq 'varbinary'
    ) { $metatype= 'char' }
    elsif (
      $metatype eq 'tinyblob' or
      $metatype eq 'mediumblob' or
      $metatype eq 'longblob' or
      $metatype eq 'blob' or
      $metatype eq 'tinytext' or
      $metatype eq 'mediumtext' or
      $metatype eq 'longtext' or
      $metatype eq 'text'
    ) { $metatype= 'blob' };

    if ($key eq 'PRI') { $key= 'primary' }
    elsif ($key eq 'MUL' or $key eq 'UNI') { $key= 'indexed' }
    else { $key= 'ordinary' };
    my $type= $tabletype{$schema.'.'.$table};
    if (lc($schema) eq 'information_schema') {
      $meta->{information_schema}->{$type}->{$table}->{col}->{$col}= [$key,$metatype,$realtype,$maxlength];
      $meta->{INFORMATION_SCHEMA}->{$type}->{$table}->{col}->{$col}= [$key,$metatype,$realtype,$maxlength];
    } else {
      $meta->{$schema}->{$type}->{$table}->{col}->{$col}= [$key,$metatype,$realtype,$maxlength];
    }
  }

  foreach my $row (@$index_metadata) {
    my ($schema, $table, $ind, $unique) = @$row;

    my $type= $tabletype{$schema.'.'.$table};
    if (lc($schema) eq 'information_schema') {
      $meta->{information_schema}->{$type}->{$table}->{key}->{$ind}= [$unique];
      $meta->{INFORMATION_SCHEMA}->{$type}->{$table}->{key}->{$ind}= [$unique];
    } else {
      $meta->{$schema}->{$type}->{$table}->{key}->{$ind}= [$unique];
    }
  }

  return $meta;
}

1;