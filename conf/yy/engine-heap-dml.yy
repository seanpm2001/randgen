# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2022, MariaDB
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

########################################################################
# The goal of this grammar is to stress test the operation of the HEAP storage engine by:
#
# * Creating a small set of tables and executing various operations over those tables
#
# * Employ TEMPORARY tables in as many DML contexts as possible
#
# This grammar goes together with the respective mysqld --init file that creates the tables
########################################################################

query_init:
  # This is to prevent other grammars from altering the schema
  GRANT INSERT, UPDATE, DELETE, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, SHOW VIEW ON heap_dml.* TO CURRENT_USER;

query:
  { $saved_database= ($last_database ? $last_database : $executors->[0]->currentSchema()); $last_database= 'heap_dml'; 'USE heap_dml' }
  ;; heap_query
  ;; { $last_database= $saved_database; ($saved_database ? "USE $saved_database" : '') }
;

heap_query:
  insert | insert | insert |
  select | delete | update ;

select:
  SELECT select_list FROM table_name any_where |
  SELECT select_list FROM table_name restrictive_where order_by |
  SELECT select_list FROM table_name restrictive_where full_order_by LIMIT _digit |
  SELECT field_name FROM table_name any_where ORDER BY field_name DESC ;

select_list:
  field_name |
  field_name , select_list ;

delete:
  DELETE FROM table_name restrictive_where |
  DELETE FROM table_name restrictive_where |
  DELETE FROM table_name restrictive_where |
  DELETE FROM table_name restrictive_where |
  DELETE FROM table_name any_where full_order_by LIMIT _digit |
  TRUNCATE TABLE table_name ;

update:
  UPDATE table_name SET update_list restrictive_where |
  UPDATE table_name SET update_list restrictive_where |
  UPDATE table_name SET update_list restrictive_where |
  UPDATE table_name SET update_list restrictive_where |
  UPDATE table_name SET update_list any_where full_order_by LIMIT _digit ;

any_where:
  permissive_where | restrictive_where;

restrictive_where:
  WHERE field_name LIKE(CONCAT( _varchar(2), '%')) |
  WHERE field_name = _varchar(2) |
  WHERE field_name LIKE(CONCAT( _varchar(1), '%')) AND field_name LIKE(CONCAT( _varchar(1), '%')) |
  WHERE field_name BETWEEN _varchar(2) AND _varchar(2) ;

permissive_where:
  WHERE field_name comp_op value |
  WHERE field_name comp_op value OR field_name comp_op value ;

comp_op:
  > | < | >= | <= | <> | != | <=> ;

update_list:
  field_name = value |
  field_name = value , update_list ;

insert:
  insert_single | insert_select |
  insert_multi | insert_multi | insert_multi ;

insert_single:
  INSERT IGNORE INTO table_name VALUES ( value , value , value , value ) ;

insert_multi:
  INSERT IGNORE INTO table_name VALUES value_list ;

insert_select:
  INSERT IGNORE INTO table_name SELECT * FROM table_name restrictive_where full_order_by LIMIT _tinyint_unsigned ;

order_by:
  | ORDER BY field_name ;

full_order_by:
  ORDER BY f1 , f2 , f3 , f4 ;

value_list:
  ( value , value, value , value ) |
  ( value , value, value , value ) , value_list |
  ( value , value, value , value ) , value_list ;

value:
  small_value | large_value ;

small_value:
  _digit | _varchar(1) | _varchar(2) | _varchar(32) | NULL ;

large_value:
  _varchar(32) | _varchar(1024) | _data | NULL ;


field_name:
  f1 | f2 | f3 | f4 ;


table_name:
  heap_complex_indexes |
  heap_complex_indexes_hash |
  heap_large_block |
  heap_noindexes_large |
  heap_noindexes_small |
  heap_oversize_pk |
  heap_small_block |
  heap_standard |
  heap_blobs |
  heap_char |
  heap_other_types |
  heap_fixed ;