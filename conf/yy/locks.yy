#  Copyright (c) 2018, 2022, MariaDB
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

#include <conf/rr/basics.rr>

query:
  ==FACTOR:0.05== locks_query ;

locks_query:
  locks_lock_tables |
  locks_flush |
  locks_locking_select_optional_trx |
  ==FACTOR:15== locks_unlock_tables
;

locks_locking_select_optional_trx:
  START TRANSACTION ; locks_locking_select ; __commit_x_rollback |
  locks_locking_select
;

locks_locking_select:
  SELECT * FROM _table __for_update_x_lock_in_share_mode locks_optional_wait_or_skip ;

locks_lock_tables:
  LOCK locks_table_or_tables locks_locking_list _basics_wait_nowait
;

locks_flush:
  FLUSH TABLES WITH READ LOCK |
  FLUSH TABLES locks_table_list WITH READ LOCK |
  FLUSH TABLES locks_table_list FOR EXPORT
;

locks_table_or_tables:
  TABLE | TABLES
;

locks_optional_wait_or_skip:
  | | _basics_wait_nowait | /*!100600 SKIP LOCKED */
;

locks_table_list:
  _table | _table, locks_table_list
;

locks_locking_list:
  locks_one_table | locks_one_table, locks_locking_list
;

locks_one_table:
  _table locks_optional_alias locks_lock_type
;

locks_optional_alias:
  | | locks_optional_as _letter
;

locks_optional_as:
  | | AS
;

locks_lock_type:
  READ locks_optional_local |
  locks_optional_low_priority WRITE |
  WRITE CONCURRENT
;

locks_optional_local:
  | | LOCAL
;

locks_optional_low_priority:
  | | LOW_PRIORITY
;

locks_unlock_tables:
  UNLOCK TABLES
;