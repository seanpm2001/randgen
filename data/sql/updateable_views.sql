DROP DATABASE IF EXISTS updateable_views_db;
CREATE DATABASE updateable_views_db;
USE updateable_views_db;

# multipart keys
CREATE TABLE IF NOT EXISTS table_multipart (field1 INTEGER NOT NULL AUTO_INCREMENT, field2 INTEGER, field3 INTEGER , field4 INTEGER, PRIMARY KEY (field1, field2, field3), KEY (field2,field3, field4), UNIQUE(field3, field4));

# partitoning
CREATE TABLE IF NOT EXISTS table_partitioned (field1 INTEGER, field2 INTEGER, field3 INTEGER, field4 INTEGER) PARTITION BY RANGE( field1 ) SUBPARTITION BY HASH( field2 ) SUBPARTITIONS 2 ( PARTITION p0 VALUES LESS THAN (1),  PARTITION p1 VALUES LESS THAN (128), PARTITION p2 VALUES LESS THAN MAXVALUE );

# Standard table (also used for table_merge, so it needs to be MyISAM)
SET STATEMENT enforce_storage_engine=NULL FOR CREATE TABLE IF NOT EXISTS table_standard (field1 INTEGER NOT NULL AUTO_INCREMENT, field2 INTEGER, field3 INTEGER, field4 INTEGER, PRIMARY KEY (field1), KEY(field2) ) ENGINE=MyISAM;

# Merge
# Cannot use SET STATEMENT because of MDEV-17711
SET @enforce.save= @@enforce_storage_engine;
SET enforce_storage_engine= NULL;
CREATE TABLE IF NOT EXISTS table_merge_child (field1 INTEGER NOT NULL AUTO_INCREMENT, field2 INTEGER , field3 INTEGER , field4 INTEGER, PRIMARY KEY (field1), KEY(field2)) ENGINE=MyISAM;
CREATE TABLE IF NOT EXISTS table_merge (field1 INTEGER NOT NULL AUTO_INCREMENT, field2 INTEGER , field3 INTEGER , field4 INTEGER, PRIMARY KEY (field1), KEY(field2)) ENGINE=MERGE UNION = (table_standard, table_merge_child) INSERT_METHOD=FIRST;
SET enforce_storage_engine= @enforce.save;

CREATE TABLE IF NOT EXISTS table_virtual (field1 INTEGER, field2 INTEGER AS (field1 / 2) PERSISTENT , field3 INTEGER AS (field1 * 2) VIRTUAL , field4 INTEGER AS (field1 mod 128) PERSISTENT, KEY (field2), KEY(field4));