# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, 2022, MariaDB
# Use is subject to license terms.
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

package DBServer::MariaDB;

@ISA = qw(DBServer);

use DBI;
use DBServer;
use GenUtil;
use if osWindows(), Win32::Process;
use Time::HiRes;
use POSIX ":sys_wait_h";
use Carp;
use Data::Dumper;
use File::Basename qw(dirname);
use File::Path qw(mkpath rmtree);
use File::Copy qw(move);

use strict;

use constant MYSQLD_BASEDIR => 0;
use constant MYSQLD_VARDIR => 1;
use constant MYSQLD_DATADIR => 2;
use constant MYSQLD_PORT => 3;
use constant MYSQLD_MYSQLD => 4;
use constant MYSQLD_LIBMYSQL => 5;
use constant MYSQLD_BOOT_SQL => 6;
use constant MYSQLD_STDOPTS => 7;
use constant MYSQLD_MESSAGES => 8;
use constant MYSQLD_CHARSETS => 9;
use constant MYSQLD_SERVER_OPTIONS => 10;
use constant MYSQLD_AUXPID => 11;
use constant MYSQLD_SERVERPID => 12;
use constant MYSQLD_WINDOWS_PROCESS => 13;
use constant MYSQLD_DBH => 14;
use constant MYSQLD_START_DIRTY => 15;
use constant MYSQLD_VALGRIND => 16;
use constant MYSQLD_VERSION => 18;
use constant MYSQLD_DUMPER => 19;
use constant MYSQLD_SOURCEDIR => 20;
use constant MYSQLD_GENERAL_LOG => 21;
use constant MYSQLD_WINDOWS_PROCESS_EXITCODE => 22;
use constant MYSQLD_SERVER_TYPE => 23;
use constant MYSQLD_VALGRIND_SUPPRESSION_FILE => 24;
use constant MYSQLD_TMPDIR => 25;
use constant MYSQLD_CONFIG_FILE => 27;
use constant MYSQLD_USER => 28;
use constant MYSQLD_MAJOR_VERSION => 29;
use constant MYSQLD_CLIENT_BINDIR => 30;
use constant MYSLQD_SERVER_VARIABLES => 31;
use constant MYSQLD_RR => 32;
use constant MYSLQD_CONFIG_VARIABLES => 33;
use constant MYSQLD_CLIENT => 34;
use constant MARIABACKUP => 35;
use constant MYSQLD_MANUAL_GDB => 36;

use constant MYSQLD_PID_FILE => "mysql.pid";
use constant MYSQLD_ERRORLOG_FILE => "mysql.err";
use constant MYSQLD_LOG_FILE => "mysql.log";
use constant MYSQLD_DEFAULT_PORT =>  19300;
use constant MYSQLD_DEFAULT_DATABASE => "test";
use constant MYSQLD_WINDOWS_PROCESS_STILLALIVE => 259;

my $default_shutdown_timeout= 300;

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({'basedir' => MYSQLD_BASEDIR,
                                   'sourcedir' => MYSQLD_SOURCEDIR,
                                   'vardir' => MYSQLD_VARDIR,
                                   'port' => MYSQLD_PORT,
                                   'server_options' => MYSQLD_SERVER_OPTIONS,
                                   'start_dirty' => MYSQLD_START_DIRTY,
                                   'general_log' => MYSQLD_GENERAL_LOG,
                                   'valgrind' => MYSQLD_VALGRIND,
                                   'rr' => MYSQLD_RR,
                                   'manual_gdb' => MYSQLD_MANUAL_GDB,
                                   'config' => MYSQLD_CONFIG_FILE,
                                   'user' => MYSQLD_USER},@_);

    croak "No valgrind support on windows" if osWindows() and defined $self->[MYSQLD_VALGRIND];
    croak "No rr support on windows" if osWindows() and $self->[MYSQLD_RR];
    croak "No cannot use both rr and valgrind at once" if $self->[MYSQLD_RR] and defined $self->[MYSQLD_VALGRIND];
    croak "Vardir is not defined for the server" unless $self->[MYSQLD_VARDIR];

    if (osWindows()) {
        ## Use unix-style path's since that's what Perl expects...
        $self->[MYSQLD_BASEDIR] =~ s/\\/\//g;
        $self->[MYSQLD_VARDIR] =~ s/\\/\//g;
        $self->[MYSQLD_DATADIR] =~ s/\\/\//g;
    }

    if (not $self->_absPath($self->vardir)) {
        $self->[MYSQLD_VARDIR] = $self->basedir."/".$self->vardir;
    }

    # Default tmpdir for server.
    $self->[MYSQLD_TMPDIR] = $self->vardir."/tmp";

    $self->[MYSQLD_DATADIR] = $self->[MYSQLD_VARDIR]."/data";

    $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                          osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                          osWindows()?"mysqld.exe":"mysqld");

    $self->serverType($self->[MYSQLD_MYSQLD]);

    $self->[MYSQLD_BOOT_SQL] = [];

    $self->[MYSQLD_DUMPER] = $self->_find([$self->basedir],
                                          osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
                                          osWindows()?"mysqldump.exe":"mysqldump");

    $self->[MYSQLD_CLIENT] = $self->_find([$self->basedir],
                                          osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
                                          osWindows()?"mysql.exe":"mysql");

    $self->[MARIABACKUP]= $self->_find([$self->basedir],
                            osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
                            osWindows()?"mariabackup.exe":"mariabackup"
                          );

    $self->[MYSQLD_CLIENT_BINDIR] = dirname($self->[MYSQLD_DUMPER]);

    ## Check for CMakestuff to get hold of source dir:

    if (not defined $self->sourcedir) {
        if (-e $self->basedir."/CMakeCache.txt") {
            open CACHE, $self->basedir."/CMakeCache.txt";
            while (<CACHE>){
                if (m/^MySQL_SOURCE_DIR:STATIC=(.*)$/) {
                    $self->[MYSQLD_SOURCEDIR] = $1;
                    say("Found source directory at ".$self->[MYSQLD_SOURCEDIR]);
                    last;
                }
            }
        }
    }

    ## Use valgrind suppression file if available in mysql-test path.
    if (defined $self->[MYSQLD_VALGRIND]) {
        $self->[MYSQLD_VALGRIND_SUPPRESSION_FILE] = $self->_find(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                                                             osWindows()?["share/mysql-test","mysql-test"]:["share/mysql-test","mysql-test"],
                                                             "valgrind.supp")
    };

    foreach my $file ('mysql_system_tables.sql',
                      'mysql_performance_tables.sql',
                      'mysql_system_tables_data.sql',
                      'fill_help_tables.sql',
                      'maria_add_gis_sp_bootstrap.sql',
                      'mysql_sys_schema.sql') {
        my $script =
             eval { $self->_find(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                          ["scripts","share/mysql","share"], $file) };
        push(@{$self->[MYSQLD_BOOT_SQL]},$script) if $script;
    }

    $self->[MYSQLD_MESSAGES] =
       $self->_findDir(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                       ["sql/share","share/mysql","share"], "english/errmsg.sys");

    $self->[MYSQLD_CHARSETS] =
        $self->_findDir(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                        ["sql/share/charsets","share/mysql/charsets","share/charsets"], "Index.xml");


    $self->[MYSQLD_STDOPTS] = ["--basedir=".$self->basedir,
                               $self->_messages,
                               "--character-sets-dir=".$self->[MYSQLD_CHARSETS],
                               "--tmpdir=".$self->tmpdir];

    if ($self->[MYSQLD_START_DIRTY]) {
        say("Using existing data for server " .$self->version ." at ".$self->datadir);
    } else {
        say("Creating " . $self->version . " database at ".$self->datadir);
        if ($self->createMysqlBase != DBSTATUS_OK) {
            sayError("FATAL ERROR: Bootstrap failed, cannot proceed!");
            return undef;
        }
    }

    return $self;
}

sub basedir {
    return $_[0]->[MYSQLD_BASEDIR];
}

sub error_logs {
    return ( $_[0]->[MYSQLD_VARDIR].'/mysql.err' );
}

sub clientBindir {
    return $_[0]->[MYSQLD_CLIENT_BINDIR];
}

sub sourcedir {
    return $_[0]->[MYSQLD_SOURCEDIR];
}

sub datadir {
    return $_[0]->[MYSQLD_DATADIR];
}

sub setDatadir {
    $_[0]->[MYSQLD_DATADIR] = $_[1];
}

sub vardir {
    return $_[0]->[MYSQLD_VARDIR];
}

sub tmpdir {
    return $_[0]->[MYSQLD_TMPDIR];
}

sub port {
    my ($self) = @_;

    if (defined $self->[MYSQLD_PORT]) {
        return $self->[MYSQLD_PORT];
    } else {
        return MYSQLD_DEFAULT_PORT;
    }
}

sub setPort {
    my ($self, $port) = @_;
    $self->[MYSQLD_PORT]= $port;
}

sub user {
    return $_[0]->[MYSQLD_USER];
}

sub serverpid {
    return $_[0]->[MYSQLD_SERVERPID];
}

sub forkpid {
    return $_[0]->[MYSQLD_AUXPID];
}

sub socketfile {
    my ($self) = @_;
    my $socketFileName = $_[0]->vardir."/mysql.sock";
    if (length($socketFileName) >= 100) {
  $socketFileName = "/tmp/RQGmysql.".$self->port.".sock";
    }
    return $socketFileName;
}

sub pidfile {
    return $_[0]->vardir."/".MYSQLD_PID_FILE;
}

sub pid {
    return $_[0]->[MYSQLD_SERVERPID];
}

sub logfile {
    return $_[0]->vardir."/".MYSQLD_LOG_FILE;
}

sub errorlog {
    return $_[0]->vardir."/".MYSQLD_ERRORLOG_FILE;
}

sub setStartDirty {
    $_[0]->[MYSQLD_START_DIRTY] = $_[1];
}

sub valgrind_suppressionfile {
    return $_[0]->[MYSQLD_VALGRIND_SUPPRESSION_FILE] ;
}

#sub libmysqldir {
#    return $_[0]->[MYSQLD_LIBMYSQL];
#}

# Check the type of mysqld server.
sub serverType {
    my ($self, $mysqld) = @_;
    $self->[MYSQLD_SERVER_TYPE] = "Release";

    my $command="$mysqld --version";
    my $result=`$command 2>&1`;

    $self->[MYSQLD_SERVER_TYPE] = "Debug" if ($result =~ /debug/sig);
    return $self->[MYSQLD_SERVER_TYPE];
}

sub generateCommand {
    my ($self, @opts) = @_;

    my $command = '"'.$self->binary.'"';
    foreach my $opt (@opts) {
        $command .= ' '.join(' ',map{'"'.$_.'"'} @$opt);
    }
    $command =~ s/\//\\/g if osWindows();
    return $command;
}

sub addServerOptions {
    my ($self,$opts) = @_;

    push(@{$self->[MYSQLD_SERVER_OPTIONS]}, @$opts);
}

sub getServerOptions {
  my $self= shift;
  return $self->[MYSQLD_SERVER_OPTIONS];
}

sub printServerOptions {
    my $self = shift;
    foreach (@{$self->[MYSQLD_SERVER_OPTIONS]}) {
        say("    $_");
    }
}

sub createMysqlBase  {
    my ($self) = @_;

    ## Clean old db if any
    if (-d $self->vardir) {
        rmtree($self->vardir);
    }

    ## Create database directory structure
    mkpath($self->vardir);
    mkpath($self->tmpdir);
    mkpath($self->datadir);

    my $defaults = ($self->[MYSQLD_CONFIG_FILE] ? "--defaults-file=$self->[MYSQLD_CONFIG_FILE]" : "--no-defaults");

    ## Create boot file

    my $boot = $self->vardir."/boot.sql";
    open BOOT,">$boot";
    print BOOT "CREATE DATABASE test;\n";

    ## Boot database

    my $boot_options = [$defaults];
    push @$boot_options, @{$self->[MYSQLD_STDOPTS]};
    push @$boot_options, "--datadir=".$self->datadir; # Could not add to STDOPTS, because datadir could have changed


    if ($self->_olderThan(5,6,3)) {
        push(@$boot_options,"--loose-skip-innodb", "--default-storage-engine=MyISAM") ;
    } else {
        push(@$boot_options, @{$self->[MYSQLD_SERVER_OPTIONS]});
    }
    push @$boot_options, "--skip-log-bin";
    push @$boot_options, "--loose-enforce-storage-engine=";
    #push @$boot_options, "--loose-innodb-encrypt-tables=OFF";
    #push @$boot_options, "--loose-innodb-encrypt-log=OFF";
    # Set max-prepared-stmt-count to a sufficient value to facilitate bootstrap
    # even if it's otherwse set to 0 for the server
    push @$boot_options, "--max-prepared-stmt-count=1024";
    # Spider tends to hang on bootstrap (MDEV-22979)
    push @$boot_options, "--loose-disable-spider";
    # Workaround for MENT-350
    if ($self->_notOlderThan(10,4,6)) {
        push @$boot_options, "--loose-server-audit-logging=OFF";
    }
    # Workaround for MDEV-29197
    push @$boot_options, "--loose-skip-s3";

    my $command;

    if (not $self->_isMySQL or $self->_olderThan(5,7,5)) {

       # Add the whole init db logic to the bootstrap script
       print BOOT "CREATE DATABASE mysql;\n";
       print BOOT "USE mysql;\n";
       foreach my $b (@{$self->[MYSQLD_BOOT_SQL]}) {
            open B,$b;
            while (<B>) { print BOOT $_;}
            close B;
        }

        push(@$boot_options,"--bootstrap") ;
        $command = $self->generateCommand($boot_options);
        $command = "$command < \"$boot\"";
    } else {
        push @$boot_options, "--initialize-insecure", "--init-file=$boot";
        $command = $self->generateCommand($boot_options);
    }

    my $usertable= ($self->versionNumeric() gt '100400' ? 'global_priv' : 'user');

    ## Add last strokes to the boot/init file: don't want empty users, but want the test user instead
    print BOOT "USE mysql;\n";
    print BOOT "DELETE FROM $usertable WHERE `User` = '';\n";
    if ($self->user ne 'root') {
        print BOOT "CREATE TABLE tmp_user AS SELECT * FROM $usertable WHERE `User`='root' AND `Host`='localhost';\n";
        print BOOT "UPDATE tmp_user SET `User` = '". $self->user ."';\n";
        print BOOT "INSERT INTO $usertable SELECT * FROM tmp_user;\n";
        print BOOT "DROP TABLE tmp_user;\n";
        print BOOT "UPDATE proxies_priv SET Timestamp = NOW();\n"; # This is for MySQL, it has '0000-00-00' there and next CREATE doesn't work
        print BOOT "CREATE TABLE tmp_proxies AS SELECT * FROM proxies_priv WHERE `User`='root' AND `Host`='localhost';\n";
        print BOOT "UPDATE tmp_proxies SET `User` = '". $self->user . "';\n";
        print BOOT "INSERT INTO proxies_priv SELECT * FROM tmp_proxies;\n";
        print BOOT "DROP TABLE tmp_proxies;\n";
    }
    # Protect the work account from password expiration
    if ($self->versionNumeric() gt '100403') {
        print BOOT "UPDATE mysql.global_priv SET Priv = JSON_INSERT(Priv, '\$.password_lifetime', 0) WHERE user in('".$self->user."', 'root');\n";
    }
    if ($self->_isMySQL and not $self->_olderThan(5,8,0)) {
      print BOOT "UPDATE mysql.user SET plugin = 'mysql_native_password' WHERE user in('".$self->user."', 'root');\n";
    }
    close BOOT;

    say("Bootstrap command: $command");
    system("$command > \"".$self->vardir."/boot.log\" 2>&1");
    return $?;
}

sub _reportError {
    say(Win32::FormatMessage(Win32::GetLastError()));
}

sub startServer {
    my ($self) = @_;

  my @defaults = ($self->[MYSQLD_CONFIG_FILE] ? ("--defaults-group-suffix=.runtime", "--defaults-file=$self->[MYSQLD_CONFIG_FILE]") : ("--no-defaults"));

    my ($v1,$v2,@rest) = $self->versionNumbers;
    my $v = $v1*1000+$v2;
    my $command = $self->generateCommand([@defaults],
                                         $self->[MYSQLD_STDOPTS],
                                         ["--core-file",
                                          "--datadir=".$self->datadir,  # Could not add to STDOPTS, because datadir could have changed
                                          "--port=".$self->port,
                                          "--socket=".$self->socketfile,
                                          "--pid-file=".$self->pidfile],
                                         $self->_logOptions);
    my @extra_opts= ( '--max-allowed-packet=1G', # Allow loading bigger blobs
                      '--loose-innodb-ft-min-token-size=10', # Workaround for MDEV-25324
                      '--secure-file-priv=', # Make sure that LOAD_FILE and such works
                      (defined $self->[MYSQLD_SERVER_OPTIONS] ? @{$self->[MYSQLD_SERVER_OPTIONS]} : ())
                    );

    say("Final options for server on port ".$self->port.", MTR style:\n".
      join(' ', map {'--mysqld='.$_} @extra_opts));

    $command = $command." ".join(' ',@extra_opts);

    # If we don't remove the existing pidfile,
    # the server will be considered started too early, and further flow can fail
    unlink($self->pidfile);

    my $errorlog = $self->vardir."/".MYSQLD_ERRORLOG_FILE;

    # In seconds, timeout for the server to start updating error log
    # after the server startup command has been launched
    my $start_wait_timeout= 30;

    # In seconds, timeout for the server to create pid file
    # after it has started updating the error log
    # (before the server is considered hanging)
    my $startup_timeout= 600;

    if ($self->[MYSQLD_RR]) {
        $command = "rr record -h --output-trace-dir=".$self->vardir."/rr_profile_".time()." ".$command;
    }
    elsif (defined $self->[MYSQLD_VALGRIND]) {
        my $val_opt ="";
        $start_wait_timeout= 60;
        $startup_timeout= 1200;
        if ($self->[MYSQLD_VALGRIND]) {
            $val_opt = $self->[MYSQLD_VALGRIND];
        }
        $command = "valgrind --time-stamp=yes --leak-check=yes --suppressions=".$self->valgrind_suppressionfile." ".$val_opt." ".$command;
    }
    $self->printInfo;

    my $errlog_fh;
    my $errlog_last_update_time= (stat($errorlog))[9] || 0;
    if ($errlog_last_update_time) {
        open($errlog_fh,$errorlog) || ( sayError("Could not open the error log " . $errorlog . " for initial read: $!") && return DBSTATUS_FAILURE );
        while (!eof($errlog_fh)) { readline $errlog_fh };
        seek $errlog_fh, 0, 1;
    }

    say("Starting server ".$self->version.": $command");

    $self->[MYSQLD_AUXPID] = fork();
    if ($self->[MYSQLD_AUXPID]) {

        ## Wait for the pid file to have been created
        my $wait_time = 0.2;
        my $waits= 0;
        my $errlog_update= 0;
        my $pid;
        my $wait_end= time() + $start_wait_timeout;

        # After we've launched server startup, we'll wait for max $start_wait_timeout seconds
        # for the server to start updating the error log
        while ((not $pid or kill(0,$pid)) and (not -f $self->pidfile) and (time() < $wait_end)) {
            Time::HiRes::sleep($wait_time);
            $errlog_update= ( (stat($errorlog))[9] > $errlog_last_update_time);
            if ($errlog_update and not $pid) {
              $pid= `grep -E 'starting as process [0-9]*' $errorlog | tail -n 1 | sed -e 's/.*starting as process \\([0-9]*\\).*/\\1/'`;
              if ($pid and $pid =~ /^\d+$/) {
                say("Pid file " . $self->pidfile . " does not exist and timeout hasn't passed yet, but the error log has already been updated and contains pid $pid");
              } elsif ($pid) {
                sayWarning("Pid was detected wrongly: '$pid', discarding");
                $pid= undef;
              }
            } elsif (not $pid) {
              say("Neither pid file nor pid record in the error log have been found yet, waiting");
            }
            sleep 1;
        }

        if (-f $self->pidfile) {
            $pid= get_pid_from_file($self->pidfile);
            say("Server created pid file with pid $pid");
        } elsif (!$errlog_update) {
            sayError("Server has not started updating the error log withing $start_wait_timeout sec. timeout, and has not created pid file");
            sayFile($errorlog);
            return DBSTATUS_FAILURE;
        }

        my $abort_found_in_error_log= 0;

        if (!$pid)
        {
            # If we are here, server has started updating the error log.
            # It can be doing some lengthy startup before creating the pid file,
            # but we might be able to get the pid from the error log record
            # [Note] <path>/mysqld (mysqld <version>) starting as process <pid> ...
            # (if the server is new enough to produce it).
            # We need the latest line of this kind

            unless ($errlog_fh) {
                unless (open($errlog_fh, $errorlog)) {
                    sayError("Could not open the error log  " . $errorlog . ": $!");
                    return DBSTATUS_FAILURE;
                }
            }
            # In case the file is being slowly updated (e.g. with valgrind),
            # and pid is not the first line which was printed (again, as with valgrind),
            # we don't want to reach the EOF and exit too quickly.
            # So, first we read the whole file till EOF, and if the last line was a valgrind-produced line
            # (starts with '== ', we'll keep waiting for more updates, until we get the first normal line,
            # which is supposed to be the PID. If it's not, there is nothing more to wait for.
            # TODO:
            # - if it's not the first start in this error log, so our protection against
            #   quitting too quickly won't work -- we'll read a wrong (old) PID and will leave.
            # And of course it won't work on Windows, but the new-style server start is generally
            # not reliable there and needs to be fixed.

            TAIL:
            for (;;) {
                do {
                    $_= readline $errlog_fh;
                    if (/\[Note\]\s+\S+?[\/\\]mysqld(?:\.exe)?\s+\(mysqld.*?\)\s+starting as process (\d+)\s+\.\./) {
                        $pid= $1;
                        say("Found PID $pid in the error log");
                        last TAIL;
                    }
                    elsif (/(?:Aborting|signal\s+\d+)/) {
                        sayError("Server has apparently crashed");
                        $abort_found_in_error_log= 1;
                        last TAIL;
                    }
                    elsif ($self->[MYSQLD_VALGRIND] and ! /^== /) {
                        last TAIL;
                    }
                } until (eof($errlog_fh));
                sleep 1;
                seek ERRLOG, 0, 1;    # this clears the EOF flag
            }
        }
        close($errlog_fh) if $errlog_fh;

        if ($abort_found_in_error_log) {
          sayFile($errorlog);
          return DBSTATUS_FAILURE;
        }

        unless (defined $pid) {
            say("WARNING: could not find the pid in the error log, might be an old version");
        }

        $wait_end= time() + $startup_timeout;

        while (!-f $self->pidfile and time() < $wait_end) {
            Time::HiRes::sleep($wait_time);
            # If we by now know the pid, we can monitor it along with the pid file,
            # to avoid unnecessary waiting if the server goes down
            last if $pid and not kill(0, $pid);
        }

        if (!-f $self->pidfile) {
            sayFile($errorlog);
            if ($pid and not kill(0, $pid)) {
                sayError("Server disappeared after having started with pid $pid");
                system("ps -ef | grep ".$self->port);
            } elsif ($pid) {
                sayError("Timeout $startup_timeout has passed and the server still has not created the pid file, assuming it has hung, sending final SIGABRT to pid $pid...");
                kill 'ABRT', $pid;
            } else {
                sayError("Timeout $startup_timeout has passed and the server still has not created the pid file, assuming it has hung, but cannot kill because we don't know the pid");
            }
            return DBSTATUS_FAILURE;
        }

        # We should only get here if the pid file was created
        my $pidfile = $self->pidfile;
        my $pid_from_file= get_pid_from_file($self->pidfile);

        $pid_from_file =~ s/.*?([0-9]+).*/$1/;
        if ($pid and $pid != $pid_from_file) {
            say("WARNING: pid extracted from the error log ($pid) is different from the pid in the pidfile ($pid_from_file). Assuming the latter is correct");
        }
        $self->[MYSQLD_SERVERPID] = int($pid_from_file);
        say("Server started with PID ".$self->[MYSQLD_SERVERPID]);
    } else {
        exec("$command >> \"$errorlog\"  2>&1") || croak("Could not start mysql server");
    }

    if ($self->waitForServerToStart && $self->dbh) {
        $self->serverVariables();
        if ($self->[MYSQLD_MANUAL_GDB]) {
          say("Pausing test to allow attaching debuggers etc. to the server process ".$self->[MYSQLD_SERVERPID].".");
          say("Press ENTER to continue the test run...");
          my $keypress = <STDIN>;
        }
        return DBSTATUS_OK;
    } else {
        return DBSTATUS_FAILURE;
    }
}

sub kill {
    my ($self, $signal) = @_;
    $signal= 'KILL' unless defined $signal;

    my $pidfile= $self->pidfile;

    if (not defined $self->serverpid and -f $pidfile) {
        $self->[MYSQLD_SERVERPID]= get_pid_from_file($self->pidfile);
    }

    if (defined $self->serverpid and $self->serverpid =~ /^\d+$/) {
        kill $signal => $self->serverpid;
        my $sleep_time= 0.2;
        my $waits = int($default_shutdown_timeout / $sleep_time);
        while ($self->running && $waits) {
            Time::HiRes::sleep($sleep_time);
            $waits--;
        }
        unless ($waits) {
            sayError("Unable to kill process ".$self->serverpid);
        } else {
            say("Killed process ".$self->serverpid." with $signal");
        }
    }

    # clean up when the server is not alive.
    unlink $self->socketfile if -e $self->socketfile;
    unlink $self->pidfile if -e $self->pidfile;
    return ($self->running ? DBSTATUS_FAILURE : DBSTATUS_OK);
}

sub term {
    my ($self) = @_;

    my $res;
    if (defined $self->serverpid) {
        kill TERM => $self->serverpid;
        my $sleep_time= 0.2;
        my $waits = int($default_shutdown_timeout / $sleep_time);
        while ($self->running && $waits) {
            Time::HiRes::sleep($sleep_time);
            $waits--;
        }
        unless ($waits) {
            say("Unable to terminate process ".$self->serverpid.". Trying SIGABRT");
            kill ABRT => $self->serverpid;
            $res= DBSTATUS_FAILURE;
            $waits= int($default_shutdown_timeout / $sleep_time);
            while ($self->running && $waits) {
              Time::HiRes::sleep($sleep_time);
              $waits--;
            }
            unless ($waits) {
              say("SIGABRT didn't work for process ".$self->serverpid.". Trying KILL");
              $self->kill;
            }
        } else {
            say("Terminated process ".$self->serverpid);
            $res= DBSTATUS_OK;
        }
    }
    if (-e $self->socketfile) {
        unlink $self->socketfile;
    }
    return $res;
}

sub crash {
    my ($self) = @_;

    if (defined $self->serverpid) {
        kill SEGV => $self->serverpid;
        say("Crashed process ".$self->serverpid);
    }

    # clean up when the server is not alive.
    unlink $self->socketfile if -e $self->socketfile;
    unlink $self->pidfile if -e $self->pidfile;

}

sub corefile {
    my ($self) = @_;
    # It can end up being named differently, depending on system settings,
    # it's just the best guess
    return $self->datadir."/core";
}

sub upgradeDb {
  my $self= shift;

  my $mysql_upgrade= $self->_find([$self->basedir],
                                        osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
                                        osWindows()?"mysql_upgrade.exe":"mysql_upgrade");
  my $upgrade_command=
    '"'.$mysql_upgrade.'" --host=127.0.0.1 --port='.$self->port.' -uroot';
  my $upgrade_log= $self->datadir.'/mysql_upgrade.log';
  say("Running mysql_upgrade:\n  $upgrade_command");
  my $res= system("$upgrade_command > $upgrade_log 2>&1");
  if ($res == DBSTATUS_OK) {
    # mysql_upgrade can return exit code 0 even if user tables are corrupt,
    # so we don't trust the exit code, we should also check the actual output
    if (open(UPGRADE_LOG, "$upgrade_log")) {
     OUTER_READ:
      while (<UPGRADE_LOG>) {
        # For now we will only check 'Repairing tables' section,
        # and if there are any errors, we'll consider it a failure
        next unless /Repairing tables/;
        while (<UPGRADE_LOG>) {
          if (/^\s*Error/) {
            $res= DBSTATUS_FAILURE;
            sayError("Found errors in mysql_upgrade output");
            sayFile("$upgrade_log");
            last OUTER_READ;
          }
        }
      }
      close (UPGRADE_LOG);
    } else {
      sayError("Could not find $upgrade_log");
      $res= DBSTATUS_FAILURE;
    }
  } else {
    sayError("mysql_upgrade returned non-okay status");
    sayFile($upgrade_log) if (-e $upgrade_log);
  }
  return $res;
}

sub dumper {
    return $_[0]->[MYSQLD_DUMPER];
}

sub client {
  return $_[0]->[MYSQLD_CLIENT];
}

sub mariabackup {
  return $_[0]->[MARIABACKUP];
}

sub drop_broken {
  my $self= shift;
  my $dbh= $self->dbh;
  say("Checking view and merge table consistency");
  while (1) {
    my $broken= $dbh->selectall_arrayref("select * from information_schema.tables where table_comment like 'Unable to open underlying table which is differently defined or of non-MyISAM type or%' or table_comment like '%references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them' or table_comment like 'Table % is differently defined or of non-MyISAM type or%'");
    last unless ($broken && scalar(@$broken));
    foreach my $vt (@$broken) {
      my $fullname= '`'.$vt->[1].'`.`'.$vt->[2].'`';
      my $type= ($vt->[3] eq 'VIEW' ? 'view' : 'table');
      my $err= $vt->[20];
      sayWarning("Error $err for $type $fullname, dropping");
      $dbh->do("DROP $type $fullname");
    }
  }
}

# dumpdb is performed in two modes.
# One is for comparison. In this case certain objects are disabled,
# data and schema are dumped separately, and data is sorted.
# Another one is for restoring the dump. In this case a "normal"
# dump is perfomed, all together and without suppressions

sub dumpdb {
    my ($self,$database,$file,$for_restoring,$options) = @_;
    my $dbh= $self->dbh;
    $dbh->do('SET GLOBAL max_statement_time=0');
    $self->drop_broken();
    if ($for_restoring) {
      # Workaround for MDEV-29936 (unique ENUM/SET with invalid values cause problems)
      my $enums= $self->dbh->selectall_arrayref(
        "select cols.table_schema, cols.table_name, cols.column_name from information_schema.columns cols ".
        "join information_schema.table_constraints constr on (cols.table_schema = constr.constraint_schema and cols.table_name = constr.table_name) ".
        "join information_schema.statistics stat on (constr.constraint_name = stat.index_name and cols.table_schema = stat.table_schema and cols.table_name = stat.table_name and cols.column_name = stat.column_name) ".
        "where (column_type like 'enum%' or column_type like 'set%') and constraint_type in ('UNIQUE','PRIMARY KEY')"
      );
      foreach my $e (@$enums) {
        $self->dbh->do("delete ignore from $e->[0].$e->[1] where $e->[2] = 0 /* dropping enums with invalid values */");
      }
      # Workaround for MDEV-29941 (spatial columns in primary keys cause problems)
      # We can't just drop PK because it may also contain auto-increment columns.
      # And we can't just drop the spatial column because it's not allowed when it participates in PK.
      # So we will first find out if there are other columns in PK. If not, we'll just drop the PK.
      # Otherwise, we'll try to re-create it but without the spatial column.
      # POINT is not affected
      my $spatial_pk= $self->dbh->selectall_arrayref(
        "select table_schema, table_name, column_name from information_schema.columns ".
        "where column_type in ('linestring','polygon','multipoint','multilinestring','multipolygon','geometrycollection','geometry') and column_key = 'PRI'"
      );
      foreach my $c (@$spatial_pk) {
        my @pk= $self->dbh->selectrow_array(
          "select group_concat(if(sub_part is not null,concat(column_name,'(',sub_part,')'),column_name)) from information_schema.statistics ".
          "where table_schema = '$c->[0]' and table_name = '$c->[1]' and index_name = 'PRIMARY' and column_name != '$c->[2]' order by seq_in_index"
        );
        if (@pk and $pk[0] ne '') {
          $self->dbh->do("alter ignore table $c->[0].$c->[1] drop primary key, add primary key ($pk[0]) /* re-creating primary key containing spatial columns */");
        } else {
          $self->dbh->do("alter ignore table $c->[0].$c->[1] drop primary key /* dropping primary key containing spatial columns */");
        }
      }
    } # End of $for_restoring

    my $databases= '--all-databases';
    if ($database && scalar(@$database) > 1) {
      $databases= "--databases @$database";
    } elsif ($database) {
      $databases= "$database->[0]";
    }
    my $dump_command= '"'.$self->dumper.'" --skip-dump-date -uroot --host=127.0.0.1 --port='.$self->port.' --hex-blob '.$databases;
    unless ($for_restoring) {
      my @heap_tables= @{$self->dbh->selectcol_arrayref(
          "select concat(table_schema,'.',table_name) from ".
          "information_schema.tables where engine='MEMORY' and table_schema not in ('information_schema','performance_schema','sys')"
        )
      };
      my $skip_heap_tables= join ' ', map {'--ignore-table-data='.$_} @heap_tables;
      $dump_command.= " --compact --order-by-primary --skip-extended-insert --no-create-info --skip-triggers $skip_heap_tables";
    }
    $dump_command.= " $options";

    say("Dumping server ".$self->version.($for_restoring ? " for restoring":" data for comparison")." on port ".$self->port);
    say($dump_command);
    my $dump_result = ($for_restoring ?
      system("$dump_command 2>&1 1>$file") :
      system("$dump_command | sort 2>&1 1>$file")
    );
    return $dump_result;
}

# dumpSchema is only performed for comparison

sub dumpSchema {
    my ($self,$database, $file) = @_;

    $self->drop_broken();

    my $databases= '--all-databases --add-drop-database';
    if ($database && scalar(@$database) > 1) {
      $databases= "--databases @$database";
    } elsif ($database) {
      $databases= "$database->[0]";
    }

    my $dump_command = '"'.$self->dumper.'"'.
                             "  --skip-dump-date --compact --no-tablespaces".
                             " --no-data --host=127.0.0.1 -uroot".
                             " --port=".$self->port.
                             " $databases";
    say($dump_command);
    my $dump_result = system("$dump_command 2>&1 1>$file");
    if ($dump_result != 0) {
      # MDEV-28577: There can be Federated tables with virtual columns, they make mysqldump fail

      my $vcol_tables= $self->dbh->selectall_arrayref(
          "SELECT DISTINCT CONCAT(ist.TABLE_SCHEMA,'.',ist.TABLE_NAME), ist.ENGINE ".
          "FROM INFORMATION_SCHEMA.TABLES ist JOIN INFORMATION_SCHEMA.COLUMNS isc ON (ist.TABLE_SCHEMA = isc.TABLE_SCHEMA AND ist.TABLE_NAME = isc.TABLE_NAME) ".
          "WHERE IS_GENERATED = 'ALWAYS'"
        );

      my $retry= 0;
      foreach my $t (@$vcol_tables) {
        if ($t->[1] eq 'FEDERATED') {
          say("Dropping Federated table $t->[0] as it has virtual columns");
          if ($self->dbh->do("DROP TABLE $t->[0]")) {
            $retry= 1;
          } else {
            $retry= 0;
            sayError("Failed to drop Federated table $t->[0] which contains virtual columns, mysqldump won't succeed: ".$self->dbh->err.": ".$self->dbh->errstr());
            last;
          }
        }
      }

      if ($retry) {
        say("Retrying mysqldump after dropping broken Federated tables");
        return $self->dumpSchema($database, $file);
      }

      sayError("Dump failed, trying to collect some information");
      system($self->[MYSQLD_CLIENT_BINDIR]."/mysql -uroot --protocol=tcp --port=".$self->port." -e 'SHOW FULL PROCESSLIST'");
      system($self->[MYSQLD_CLIENT_BINDIR]."/mysql -uroot --protocol=tcp --port=".$self->port." -e 'SELECT * FROM INFORMATION_SCHEMA.METADATA_LOCK_INFO'");
    }
    return $dump_result;
}

# There are some known expected differences in dump structure between
# older and newer versions.
# We need to "normalize" the dumps to avoid false positives while comparing them.
# Optionally, we can also remove AUTOINCREMENT=N clauses.
# The old file is stored in <filename_orig>.
sub normalizeDump {
  my ($self, $file, $remove_autoincs)= @_;
  if ($remove_autoincs) {
    say("normalizeDump removes AUTO_INCREMENT clauses from table definitions");
    move($file, $file.'.tmp1');
    open(DUMP1,$file.'.tmp1');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      if (s/ AUTO_INCREMENT=\d+//) {};
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }
  if ($self->versionNumeric() ge '100201') {
    say("normalizeDump patches DEFAULT clauses for version ".$self->versionNumeric);
    move($file, $file.'.tmp2');
    open(DUMP1,$file.'.tmp2');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      # In 10.2 blobs can have a default clause
      # `col_blob` blob NOT NULL DEFAULT ... => `col_blob` blob NOT NULL.
      s/(\s+(?:blob|text|mediumblob|mediumtext|longblob|longtext|tinyblob|tinytext)(?:\s*NOT\sNULL)?)\s*DEFAULT\s*(?:\d+|NULL|\'[^\']*\')\s*(.*)$/${1}${2}/;
      # `k` int(10) unsigned NOT NULL DEFAULT '0' => `k` int(10) unsigned NOT NULL DEFAULT 0
      s/(DEFAULT\s+)([\.\d]+)(.*)$/${1}\'${2}\'${3}/;
      # DEFAULT current_timestamp() ON UPDATE current_timestamp() => DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
      s/DEFAULT current_timestamp\(\)/DEFAULT CURRENT_TIMESTAMP/g;
      s/ON UPDATE current_timestamp\(\)/ON UPDATE CURRENT_TIMESTAMP/g;
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }
  if ($self->versionNumeric() le '100100') {
    say("normalizeDump patches PERSISTENT NULL etc. for version ".$self->versionNumeric()." (MDEV-5614)");
    move($file, $file.'.tmp3');
    open(DUMP1,$file.'.tmp3');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      # In 10.0 SHOW CREATE TABLE shows things like
      #   `vcol_timestamp` timestamp(3) AS (col_timestamp) VIRTUAL NULL ON UPDATE CURRENT_TIMESTAMP(3)
      # or
      #   `vcol_timestamp` timestamp(5) AS (col_timestamp) PERSISTENT NULL
      # which makes CREATE TABLE invalid (MDEV-5614, fixed in 10.1+)
      s/(PERSISTENT|VIRTUAL) NULL/$1/g;
      s/(PERSISTENT|VIRTUAL) ON UPDATE CURRENT_TIMESTAMP(?:\(\d?\))?/$1/g;
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }

  if ($self->versionNumeric() gt '050701') {
    say("normalizeDump removes _binary for version ".$self->versionNumeric);
    move($file, $file.'.tmp4');
    open(DUMP1,$file.'.tmp4');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      # In 5.7 mysqldump writes _binary before corresponding fields
      #   INSERT INTO `t4` VALUES (0x0000000000,'',_binary ''
      if (/INSERT INTO/) {
        s/([\(,])_binary '/$1'/g;
      }
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }

  if ($self->versionNumeric() gt '100501') {
    say("normalizeDump removes /* mariadb-5.3 */ comments for version ".$self->versionNumeric);
    move($file, $file.'.tmp5');
    open(DUMP1,$file.'.tmp5');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      # MDEV-19906 started writing /* mariadb-5.3 */ comment
      #   for old temporal data types
      if (s/ \/\* mariadb-5.3 \*\///g) {}
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }

  # MDEV-29446 added default COLLATE clause to SHOW CREATE.
  # in 10.3.37, 10.4.27, 10.5.18, 10.6.11, 10.7.7, 10.8.6, 10.9.4, 10.10.2.
  # We can't know whether it was a part of the original definition or not,
  # so we have to remove it unconditionally.
  say("normalizeDump removes COLLATE clause from table and other definitions definitions");
  move($file, $file.'.tmp6');
  open(DUMP1,$file.'.tmp6');
  open(DUMP2,">$file");
  while (<DUMP1>) {
    if (s/ COLLATE[= ]\w+//g) {}
    print DUMP2 $_;
  }
  close(DUMP1);
  close(DUMP2);


  if (-e $file.'.tmp1') {
    move($file.'.tmp1',$file.'.orig');
#    unlink($file.'.tmp2') if -e $file.'.tmp2';
  } elsif (-e $file.'.tmp2') {
    move($file.'.tmp2',$file.'.orig');
  } elsif (-e $file.'.tmp3') {
    move($file.'.tmp3',$file.'.orig');
  } elsif (-e $file.'.tmp4') {
    move($file.'.tmp4',$file.'.orig');
  } elsif (-e $file.'.tmp5') {
    move($file.'.tmp5',$file.'.orig');
  } elsif (-e $file.'.tmp6') {
    move($file.'.tmp6',$file.'.orig');
  }
}

sub nonSystemDatabases {
  my $self= shift;
  return @{$self->dbh->selectcol_arrayref(
      "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA ".
      "WHERE LOWER(SCHEMA_NAME) NOT IN ('mysql','information_schema','performance_schema','sys')"
    )
  };
}

sub collectAutoincrements {
  my $self= shift;
  my $autoinc_tables= $self->dbh->selectall_arrayref(
      "SELECT CONCAT(ist.TABLE_SCHEMA,'.',ist.TABLE_NAME), ist.AUTO_INCREMENT, isc.COLUMN_NAME, '' ".
      "FROM INFORMATION_SCHEMA.TABLES ist JOIN INFORMATION_SCHEMA.COLUMNS isc ON (ist.TABLE_SCHEMA = isc.TABLE_SCHEMA AND ist.TABLE_NAME = isc.TABLE_NAME) ".
      "WHERE ist.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys') ".
      "AND ist.AUTO_INCREMENT IS NOT NULL ".
      "AND isc.EXTRA LIKE '%auto_increment%' ".
      "ORDER BY ist.TABLE_SCHEMA, ist.TABLE_NAME, isc.COLUMN_NAME"
    );
  foreach my $t (@$autoinc_tables) {
    my $max_autoinc= $self->dbh->selectrow_arrayref("SELECT IFNULL(MAX($t->[2]),0) FROM $t->[0]");
    if ($max_autoinc && (ref $max_autoinc eq 'ARRAY')) {
      $t->[3] = $max_autoinc->[0];
    }
  }
  return $autoinc_tables;
}

# XA transactions which haven't been either committed or rolled back
# can further cause locking issues, so different scenarios may want to
# rollback them before doing, for example, DROP TABLE

sub rollbackXA {
  my $self= shift;
  my $xa_transactions= $self->dbh->selectcol_arrayref("XA RECOVER", { Columns => [4] });
  if ($xa_transactions) {
    foreach my $xa (@$xa_transactions) {
      say("Rolling back XA transaction $xa");
      $self->dbh->do("XA ROLLBACK '$xa'");
    }
  }
}

sub binary {
    return $_[0]->[MYSQLD_MYSQLD];
}

sub stopServer {
    my ($self, $shutdown_timeout) = @_;
    $shutdown_timeout = $default_shutdown_timeout unless defined $shutdown_timeout;
    my $res;

    my $shutdown_marker= 'SHUTDOWN_'.time();
    $self->addErrorLogMarker($shutdown_marker);
    if ($shutdown_timeout and defined $self->[MYSQLD_DBH]) {
        say("Stopping server on port ".$self->port);
        $SIG{'ALRM'} = sub { sayWarning("Could not execute shutdown command in time"); };
        ## Use dbh routine to ensure reconnect in case connection is
        ## stale (happens i.e. with mdl_stability/valgrind runs)
        alarm($shutdown_timeout);
        my $dbh = $self->dbh();
        # Need to check if $dbh is defined, in case the server has crashed
        if (defined $dbh) {
            $res = $dbh->func('shutdown','127.0.0.1','root','admin');
            alarm(0);
            if (!$res) {
                ## If shutdown fails, we want to know why:
                if ($dbh->err == 1064) {
                    say("Shutdown command is not supported, sending SIGTERM instead");
                    $res= $self->term;
                }
                if (!$res) {
                    say("Shutdown failed due to ".$dbh->err.":".$dbh->errstr);
                    $res= DBSTATUS_FAILURE;
                }
            }
        }
        if (!$self->waitForServerToStop($shutdown_timeout)) {
            # Terminate process
            say("Server would not shut down properly. Terminate it");
            $res= $self->term;
        } else {
            # clean up when server is not alive.
            unlink $self->socketfile if -e $self->socketfile;
            unlink $self->pidfile if -e $self->pidfile;
            $res= DBSTATUS_OK;
            say("Server has been stopped");
        }
    } else {
        say("Shutdown timeout or dbh is not defined, killing the server");
        $res= $self->kill;
    }
    my ($crashes, undef)= $self->checkErrorLogForErrors($shutdown_marker);
    if ($crashes and scalar(@$crashes)) {
      $res= DBSTATUS_FAILURE;
    }
    return $res;
}

sub checkDatabaseIntegrity {
  my $self= shift;

  say("Testing database integrity");
  my $dbh= $self->dbh;
  my $status= DBSTATUS_OK;
  my $foreign_key_check_workaround= 0;

  $dbh->do("SET max_statement_time= 0");
  my $databases = $dbh->selectcol_arrayref("SHOW DATABASES");
  ALLDBCHECK:
  foreach my $database (@$databases) {
      my $db_status= DBSTATUS_OK;
      next if $database =~ m{^(information_schema|pbxt|performance_schema|sys)$}is;
      my $tabl_ref = $dbh->selectall_arrayref("SELECT TABLE_NAME, TABLE_TYPE, ENGINE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$database'");
      # 1178 is ER_CHECK_NOT_IMPLEMENTED
      my %tables=();
      foreach (@$tabl_ref) {
        my @tr= @$_;
        $tables{$tr[0]} = [ $tr[1], $tr[2] ];
      }
      # table => true
      my %repair_done= ();
      # Mysterious loss of connection upon checks, will retry (once)
      my $retried_lost_connection= 0;
      CHECKTABLE:
      foreach my $table (sort keys %tables) {
        # Should not do CHECK etc., and especially ALTER, on a view
        next CHECKTABLE if $tables{$table}->[0] eq 'VIEW';
        # S3 tables are ignored due to MDEV-29136
        if ($tables{$table}->[1] eq 'S3') {
          say("Check on S3 table $database.$table is skipped due to MDEV-29136");
          next CHECKTABLE;
        }
        #say("Verifying table: $database.$table ($tables{$table}->[1]):");
        my $check = $dbh->selectcol_arrayref("CHECK TABLE `$database`.`$table` EXTENDED", { Columns=>[3,4] });
        if ($dbh->err() > 0) {
          sayError("Got an error for table ${database}.${table}: ".$dbh->err()." (".$dbh->errstr().")");
          # 1178 is ER_CHECK_NOT_IMPLEMENTED. It's not an error
          $db_status= DBSTATUS_FAILURE unless ($dbh->err() == 1178);
          # Mysterious loss of connection upon checks
          if ($dbh->err() == 2013 || $dbh->err() == 2002) {
            if ($retried_lost_connection) {
              last ALLDBCHECK;
            } else {
              say("Trying again as sometimes the connection gets lost...");
              $retried_lost_connection= 1;
              redo CHECKTABLE;
            }
          }
        }
        # CHECK as such doesn't return errors, even on corrupt tables, only prints them
        else {
          my @msg = @$check;
          # table_schema.table_name => [table_type, engine, row_format, table_options]
          my %table_attributes= ();
          CHECKOUTPUT:
          for (my $i = 0; $i < $#msg; $i= $i+2)  {
            my ($msg_type, $msg_text)= ($msg[$i], $msg[$i+1]);
            if ($msg_type eq 'status' and $msg_text ne 'OK' or $msg_type =~ /^error$/i) {
              if (not exists $table_attributes{"$database.$table"}) {
                $table_attributes{"$database.$table"}= $dbh->selectrow_arrayref("SELECT TABLE_TYPE, ENGINE, ROW_FORMAT, CREATE_OPTIONS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$database' AND TABLE_NAME='$table'");
              }
              my $tname="$database.$table";
              my $engine= $table_attributes{$tname}->[1];
              unless ($engine) {
                  # Something is wrong, table's info was not retrieved from I_S
                  # Try to find out from the file system first (glob because the table can be partitioned)
                  say("Checking ".$self->datadir."/$database for the presence of $table data files");
                  system("ls ".$self->datadir."/$database/$table.*");
                  if (glob $self->datadir."/$database/$table*.MAD") {
                      # Could happen as a part of
                      # MDEV-17913: Encrypted transactional Aria tables remain corrupt after crash recovery
                      $engine= 'Aria';
                      if (not $repair_done{$table}
                            and defined $self->serverVariable('aria_encrypt_tables')
                            and $self->serverVariable('aria_encrypt_tables') eq 'ON'
                          ) {
                        sayWarning("Aria table `$database`.`$table` was not loaded, : $msg_type : $msg_text");
                        sayWarning("... ignoring due to known bug MDEV-20313, trying to repair");
                        $dbh->do("REPAIR TABLE $tname");
                        $repair_done{$table}= 1;
                        redo CHECKTABLE;
                      }
                  } elsif (glob "$self->datadir/$database/$table*.MYD") {
                      $engine= 'MyISAM';
                  } elsif (glob "$self->datadir/$database/$table*.ibd") {
                      $engine= 'InnoDB';
                  } elsif (glob "$self->datadir/$database/$table*.CSV") {
                      $engine= 'CSV';
                  } else {
                      $engine= 'N/A';
                  }
                  sayError("Table $tname wasn't loaded properly by engine $engine");
                  last CHECKOUTPUT;
              }
              my $attrs= $table_attributes{$tname}->[1]." ".$table_attributes{$tname}->[0]." ROW_FORMAT=".$table_attributes{$tname}->[2];
              if ($table_attributes{$tname}->[1] eq 'Aria') {
                $attrs= ($table_attributes{$tname}->[3] =~ /transactional=1/ ? "transactional $attrs" : "non-transactional $attrs");
              }
              if ($msg_text =~ /Unable to open underlying table which is differently defined or of non-MyISAM type or doesn't exist/) {
                sayWarning("For $attrs `$database`.`$table` : $msg_type : $msg_text");
                sayWarning("... ignoring inconsistency for the MERGE table");
                last CHECKOUTPUT;
              }
              # MDEV-20313: Transactional Aria table stays corrupt after crash-recovery
              elsif ( not $repair_done{$table}
                        and $table_attributes{$tname}->[1] eq 'Aria'
                        and $table_attributes{$tname}->[3] =~ /transactional=1/
                        and $table_attributes{$tname}->[2] eq 'Page'
                        and $msg_text =~ /Found \d+ keys of \d+/ ) {
                sayWarning("For $attrs `$database`.`$table` : $msg_type : $msg_text");
                sayWarning("... ignoring due to known bug MDEV-20313, trying to repair");
                $dbh->do("REPAIR TABLE $tname");
                $repair_done{$table}= 1;
                redo CHECKTABLE;
              }
              # MDEV-17913: Encrypted transactional Aria tables remain corrupt after crash recovery
              elsif ( not $repair_done{$table}
                        and defined $self->serverVariable('aria_encrypt_tables')
                        and $self->serverVariable('aria_encrypt_tables') eq 'ON'
                        and $table_attributes{$tname}->[1] eq 'Aria'
                        and $table_attributes{$tname}->[3] =~ /transactional=1/
                        and $table_attributes{$tname}->[2] eq 'Page'
                        and $msg_text =~ /Checksum for key:  \d+ doesn't match checksum for records|Record at: \d+:\d+  Can\'t find key for index:  \d+|Record-count is not ok; found \d+  Should be: \d+|Key \d+ doesn\'t point at same records as key \d+|Page at \d+ is not delete marked|Key in wrong position at page|Page at \d+ is not marked for index \d+/ ) {
                sayWarning("For $attrs `$database`.`$table` : $msg_type : $msg_text");
                sayWarning("... ignoring due to known bug MDEV-17913, trying to repair");
                $dbh->do("REPAIR TABLE $tname");
                $repair_done{$table}= 1;
                redo CHECKTABLE;
              } elsif (! $foreign_key_check_workaround and $msg_text =~ /Table .* doesn't exist in engine/) {
                sayWarning("For $attrs `$database`.`$table` : $msg_type : $msg_text");
                sayWarning("... possible foreign key check problem. Trying to turn off FOREIGN_KEY_CHECKS and retry");
                $dbh->do("SET FOREIGN_KEY_CHECKS= 0");
                $foreign_key_check_workaround= 1;
                redo CHECKTABLE;
              } elsif (not $repair_done{$table} and ($table_attributes{$tname}->[1] eq 'Aria' and $table_attributes{$tname}->[3] !~ /transactional=1/ or $table_attributes{$tname}->[1] eq 'MyISAM')) {
                sayWarning("For $attrs `$database`.`$table` : $msg_type : $msg_text");
                sayWarning("... non-transactional table may be corrupt after crash recovery, trying to repair");
                $dbh->do("REPAIR TABLE $tname");
                $repair_done{$table}= 1;
                redo CHECKTABLE;
              } else {
                sayError("For $attrs `$database`.`$table` : $msg_type : $msg_text");
                $db_status= DBSTATUS_FAILURE;
              }
            } else {
              sayDebug("For table `$database`.`$table` : $msg_type : $msg_text");
            }
          }
        }
      }
      $status= $db_status if $db_status > $status;
      if ($db_status == DBSTATUS_OK) {
        say("Check for database $database OK");
      } else {
        sayError("Check for database $database failed");
      }
  }
  if ($status > DBSTATUS_OK) {
    sayError("Database integrity check failed");
  }
  if ($foreign_key_check_workaround) {
    $dbh->do("SET FOREIGN_KEY_CHECKS= DEFAULT");
  }
  return $status;
}

sub addErrorLogMarker {
  my $self= shift;
  my $marker= shift;

    sayDebug("Adding marker $marker to the error log ".$self->errorlog);
  if (open(ERRLOG,">>".$self->errorlog)) {
    print ERRLOG "$marker\n";
    close (ERRLOG);
  } else {
    sayWarning("Could not add marker $marker to the error log ".$self->errorlog);
  }
}

sub waitForServerToStop {
  my $self= shift;
  my $timeout= shift;
  $timeout = (defined $timeout ? $timeout*2 : 120);
  my $waits= 0;
  while ($self->running && $waits < $timeout) {
    Time::HiRes::sleep(0.5);
    $waits++;
  }
  return !$self->running;
}

sub waitForServerToStart {
  my $self= shift;
  my $waits= 0;
  while (!$self->running && $waits < 120) {
    Time::HiRes::sleep(0.5);
    $waits++;
  }
  return $self->running;
}


sub backupDatadir {
  my $self= shift;
  my $backup_name= shift;

  say("Copying datadir... (interrupting the copy operation may cause investigation problems later)");
  if (osWindows()) {
      system('xcopy "'.$self->datadir.'" "'.$backup_name.' /E /I /Q');
  } else {
      system('cp -r '.$self->datadir.' '.$backup_name);
  }
}

# Extract important messages from the error log.
# The check starts from the provided marker or from the beginning of the log

sub checkErrorLogForErrors {
  my ($self, $marker)= @_;

  my @crashes= ();
  my @errors= ();

  open(ERRLOG, $self->errorlog);
  my $found_marker= 0;

  sayDebug("Checking server log for important errors starting from " . ($marker ? "marker $marker" : 'the beginning'));

  my $count= 0;
  while (<ERRLOG>)
  {
    next unless !$marker or $found_marker or /^$marker$/;
    $found_marker= 1;
    $_ =~ s{[\r\n]}{}isg;

    # Ignore certain errors
    next if
         $_ =~ /innodb_table_stats/s
      or $_ =~ /InnoDB: Cannot save table statistics for table/s
      or $_ =~ /InnoDB: Deleting persistent statistics for table/s
      or $_ =~ /InnoDB: Unable to rename statistics from/s
      or $_ =~ /ib_buffer_pool' for reading: No such file or directory/s
      or $_ =~ /has or is referenced in foreign key constraints which are not compatible with the new table definition/s
    ;

    # MDEV-20320
    if ($_ =~ /Failed to find tablespace for table .* in the cache\. Attempting to load the tablespace with space id/) {
        say("Encountered symptoms of MDEV-20320, variant 1");
        next;
    }
    # MDEV-20320 2nd part
    if ($_ =~ /InnoDB: Refusing to load .* \(id=\d+, flags=0x\d+\); dictionary contains id=\d+, flags=0x\d+/) {
        $_=<ERRLOG>;
        if (/InnoDB: Operating system error number 2 in a file operation/) {
            $_=<ERRLOG>;
            if (/InnoDB: The error means the system cannot find the path specified/) {
                $_=<ERRLOG>;
                if (/InnoDB: If you are installing InnoDB, remember that you must create directories yourself, InnoDB does not create them/) {
                    $_=<ERRLOG>;
                    if (/InnoDB: Could not find a valid tablespace file for .*/) {
                        say("Encountered symptoms of MDEV-20320, variant 2");
                        next;
                    }
                }
            }
        }
    }

    # Crashes
    if (
           $_ =~ /Assertion\W/is
        or $_ =~ /got\s+signal/is
        or $_ =~ /segmentation fault/is
        or $_ =~ /segfault/is
        or $_ =~ /got\s+exception/is
        or $_ =~ /AddressSanitizer|LeakSanitizer/is
    ) {
      say("------") unless $count++;
      say($_);
      push @crashes, $_;
    }
    # Other errors
    elsif (
           $_ =~ /\[ERROR\]\s+InnoDB/is
        or $_ =~ /InnoDB:\s+Error:/is
        or $_ =~ /registration as a STORAGE ENGINE failed./is
    ) {
      say("------") unless $count++;
      say($_);
      push @errors, $_;
    }
  }
  say("------") if $count;
  close(ERRLOG);
  return (\@crashes, \@errors);
}

sub serverVariables {
    my $self = shift;
    if (not keys %{$self->[MYSLQD_SERVER_VARIABLES]}) {
        my $dbh = $self->dbh;
        return undef if not defined $dbh;
        my $sth = $dbh->prepare("SHOW VARIABLES");
        $sth->execute();
        my %vars = ();
        while (my $array_ref = $sth->fetchrow_arrayref()) {
            $vars{$array_ref->[0]} = $array_ref->[1];
        }
        $sth->finish();
        $self->[MYSLQD_SERVER_VARIABLES] = \%vars;
    }
    return $self->[MYSLQD_SERVER_VARIABLES];
}

# Store variables which were set through config or command line
sub storeConfigVariables {
    my $self = shift;
    if (not keys %{$self->[MYSLQD_CONFIG_VARIABLES]}) {
        my $dbh = $self->dbh;
        return undef if not defined $dbh;
        my $sth = $dbh->prepare("SELECT variable_name, global_value FROM information_schema.system_variables WHERE global_value_origin = 'CONFIG'");
        $sth->execute();
        my %vars = ();
        while (my $array_ref = $sth->fetchrow_arrayref()) {
            $vars{$array_ref->[0]} = $array_ref->[1];
        }
        $sth->finish();
        $self->[MYSLQD_CONFIG_VARIABLES] = \%vars;
    }
    if (keys %{$self->[MYSLQD_CONFIG_VARIABLES]}) {
      say("Server variables set through config or command-line options:");
      foreach my $v (keys %{$self->[MYSLQD_CONFIG_VARIABLES]}) {
        say("\t$v: ".${$self->[MYSLQD_CONFIG_VARIABLES]}{$v});
      }
    }
}

# Restore dynamic variables which were set through config or command line
# but modified during test execution
# (can be needed for different purposes, e.g. for data consistency checks before/after restart)
sub restoreConfigVariables {
    my $self = shift;
    if ($self->[MYSLQD_CONFIG_VARIABLES]) {
        my $dbh = $self->dbh;
        return undef if not defined $dbh;
        my $sth = $dbh->prepare("SELECT variable_name, global_value FROM information_schema.system_variables WHERE global_value_origin = 'SQL' AND read_only = 'NO'");
        $sth->execute();
        my %vars = ();
        while (my $array_ref = $sth->fetchrow_arrayref()) {
            $vars{$array_ref->[0]} = $array_ref->[1];
        }
        foreach my $var (keys %vars) {
          my $val= (defined ${$self->[MYSLQD_CONFIG_VARIABLES]}{$var} ? ${$self->[MYSLQD_CONFIG_VARIABLES]}{$var} : 'DEFAULT');
          if($val ne $vars{$var}) {
            $val = "'".$val."'" unless ($val =~ /^(?:\d+|NULL|DEFAULT)$/);
            say("Restoring $var: ".$vars{$var}." => $val");
            $sth = $dbh->prepare("SET GLOBAL $var = $val");
            $sth->execute();
          }
        }
    }
}

sub serverVariable {
    my ($self, $var) = @_;
    return $self->serverVariables()->{$var};
}

sub running {
    my($self) = @_;
    my $pid= $self->serverpid;
    unless ($pid and $pid =~ /^\d+$/) {
      if (-f $self->pidfile) {
        $pid= get_pid_from_file($self->pidfile);
      }
    }
    if ($pid and $pid =~ /^\d+$/) {
      if (osWindows()) {
        return kill(0,$pid)
      } else {
        # It looks like in some cases the process may be not responding
        # to ping but is still not quite dead
        return ! system("ls /proc/$pid > /dev/null 2>&1")
      }
    } else {
      sayWarning("PID not found");
      return 0;
    }
}

sub _find {
    my($self, $bases, $subdir, @names) = @_;

    foreach my $base (@$bases) {
        foreach my $s (@$subdir) {
          foreach my $n (@names) {
                my $path  = $base."/".$s."/".$n;
                return $path if -f $path;
          }
        }
    }
    my $paths = "";
    foreach my $base (@$bases) {
        $paths .= join(",",map {"'".$base."/".$_."'"} @$subdir).",";
    }
    my $names = join(" or ", @names );
    croak "Cannot find '$names' in $paths";
}

sub dsn {
    my ($self,$database) = @_;
    $database = MYSQLD_DEFAULT_DATABASE if not defined $database;
    return "dbi:mysql:host=127.0.0.1:port=".
        $self->[MYSQLD_PORT].
        ":user=".
        $self->[MYSQLD_USER].
        ":database=".$database.
        ":mysql_local_infile=1".
        ":max_allowed_packet=1G";
}

sub dbh {
    my ($self) = @_;
    if (defined $self->[MYSQLD_DBH]) {
        if (!$self->[MYSQLD_DBH]->ping) {
            say("Stale connection to ".$self->[MYSQLD_PORT].". Reconnecting");
            $self->[MYSQLD_DBH] = DBI->connect($self->dsn("mysql"),
                                               undef,
                                               undef,
                                               {PrintError => 0,
                                                RaiseError => 0,
                                                AutoCommit => 1,
                                                mysql_auto_reconnect => 1});
        }
    } else {
        say("Connecting to ".$self->[MYSQLD_PORT]);
        $self->[MYSQLD_DBH] = DBI->connect($self->dsn("mysql"),
                                           undef,
                                           undef,
                                           {PrintError => 0,
                                            RaiseError => 0,
                                            AutoCommit => 1,
                                            mysql_auto_reconnect => 1});
    }
    if(!defined $self->[MYSQLD_DBH]) {
        sayError("(Re)connect to ".$self->[MYSQLD_PORT]." failed due to ".$DBI::err.": ".$DBI::errstr);
    }
    return $self->[MYSQLD_DBH];
}

sub _findDir {
    my($self, $bases, $subdir, $name) = @_;

    foreach my $base (@$bases) {
        foreach my $s (@$subdir) {
            my $path  = $base."/".$s."/".$name;
            return $base."/".$s if -f $path;
        }
    }
    my $paths = "";
    foreach my $base (@$bases) {
        $paths .= join(",",map {"'".$base."/".$_."'"} @$subdir).",";
    }
    croak "Cannot find '$name' in $paths";
}

sub _absPath {
    my ($self, $path) = @_;

    if (osWindows()) {
        return
            $path =~ m/^[A-Z]:[\/\\]/i;
    } else {
        return $path =~ m/^\//;
    }
}

sub version {
    my($self) = @_;

    if (not defined $self->[MYSQLD_VERSION]) {
        my $conf = $self->_find([$self->basedir],
                                ['scripts',
                                 'bin',
                                 'sbin'],
                                'mysql_config.pl', 'mysql_config');
        ## This will not work if there is no perl installation,
        ## but without perl, RQG won't work either :-)
        my $ver = `perl $conf --version`;
        chop($ver);
        $self->[MYSQLD_VERSION] = $ver;
    }
    return $self->[MYSQLD_VERSION];
}

sub majorVersion {
    my($self) = @_;

    if (not defined $self->[MYSQLD_MAJOR_VERSION]) {
        my $ver= $self->version;
        if ($ver =~ /(\d+\.\d+)/) {
            $self->[MYSQLD_MAJOR_VERSION]= $1;
        }
    }
    return $self->[MYSQLD_MAJOR_VERSION];
}

sub printInfo {
    my($self) = @_;

    say("Server version: ". $self->version);
    say("Binary: ". $self->binary);
    say("Type: ". $self->serverType($self->binary));
    say("Datadir: ". $self->datadir);
    say("Tmpdir: ". $self->tmpdir);
    say("Corefile: " . $self->corefile);
}

sub versionNumbers {
    my($self) = @_;

    $self->version =~ m/([0-9]+)\.([0-9]+)\.([0-9]+)/;

    return (int($1),int($2),int($3));
}

sub versionNumeric {
    return versionN6($_[0]->version);
}

#############  Version specific stuff

sub _messages {
    my ($self) = @_;

    if ($self->_olderThan(5,5,0)) {
        return "--language=".$self->[MYSQLD_MESSAGES]."/english";
    } else {
        return "--lc-messages-dir=".$self->[MYSQLD_MESSAGES];
    }
}

sub _logOptions {
    my ($self) = @_;

    if ($self->_olderThan(5,1,29)) {
        return ["--log=".$self->logfile];
    } else {
        if ($self->[MYSQLD_GENERAL_LOG]) {
            return ["--general-log", "--general-log-file=".$self->logfile];
        } else {
            return ["--general-log-file=".$self->logfile];
        }
    }
}

# For _olderThan and _notOlderThan we will match according to InnoDB versions
# 10.0 to 5.6
# 10.1 to 5.6
# 10.2 to 5.6
# 10.2 to 5.7

sub _olderThan {
    my ($self,$b1,$b2,$b3) = @_;

    my ($v1, $v2, $v3) = $self->versionNumbers;

    if    ($v1 == 10 and $b1 == 5 and $v2 >= 0 and $v2 < 3) { $v1 = 5; $v2 = 6 }
    elsif ($v1 == 10 and $b1 == 5 and $v2 >= 3) { $v1 = 5; $v2 = 7 }
    elsif ($v1 == 5 and $b1 == 10 and $b2 >= 0 and $b2 < 3) { $b1 = 5; $b2 = 6 }
    elsif ($v1 == 5 and $b1 == 10 and $b2 >= 3) { $b1 = 5; $b2 = 7 }

    my $b = $b1*1000 + $b2 * 100 + $b3;
    my $v = $v1*1000 + $v2 * 100 + $v3;

    return $v < $b;
}

sub _isMySQL {
    my $self = shift;
    my ($v1, $v2, $v3) = $self->versionNumbers;
    return ($v1 == 8 or $v1 == 5 and ($v2 == 6 or $v2 == 7));
}

sub _notOlderThan {
    return not _olderThan(@_);
}

sub get_pid_from_file {
  my $fname= shift;
  my $separ= $/;
  $/= undef;
  open(PID,$fname) || croak("Could not open pid file $fname for reading");
  my $p = <PID>;
  close(PID);
  $p =~ s/.*?([0-9]+).*/$1/;
  $/= $separ;
  return $p;
}
