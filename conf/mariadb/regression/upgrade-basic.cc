$combinations = [
  [
  '
  --threads=4
  --no-mask
  --seed=time
  --grammar=conf/mariadb/oltp-transactional.yy
  --gendata=conf/mariadb/innodb_upgrade.zz
  --gendata-advanced
  --reporters=Backtrace,ErrorLog,Deadlock
  --mysqld=--server-id=111
  --mysqld=--log_output=FILE
  --mysqld=--loose-max-statement-time=20
  --mysqld=--lock-wait-timeout=10
  --mysqld=--innodb-lock-wait-timeout=5
  --scenario-grammar2=conf/mariadb/oltp_and_ddl.yy
  '],
  [
    '--scenario=NormalUpgrade --duration=180',
    '--scenario=UndoLogUpgrade --duration=300',
  ],
];