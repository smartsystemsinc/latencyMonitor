#!/usr/bin/env perl

# TODO: Improve usefulness of WARN data by creating an algorithm to, on the
# heartbeat, see if WARNs are close together and see if it's a busy time of
# day; if it's likely to be notable, then append them to a CRIT file to be
# monitored by N-Able. Consider using a percentage over 5 minutes; e.g. if 50%
# of packets are over 200ms, then we have an issue

# TODO: See if it's possible to make this cross-platform by replacing Windows'
# ping.exe with a perl implementation. Also see if we can make the Excel sheet
# more useful outside of Excel by doing a little less hard-coding.

# Changelog:
# 0.4a
# -Accounts for middle-of-the-night reboots by checking to see if today has data, and if so, looking for
#  a differential as usual; if today has no data, it revives yesterday's after doing a check to see if
#  it's most likely necessary
# -Re-wrote to incorporate Smart::Comments on-demand and be otherwise relatively silent up until the actual
#  data-gathering
#
# 0.4
# -Started using version numbers
# -Converted the latency2excel call to a subprocedure for consistency, even if it is a one-liner
# -Set a timer and checks to terminate the child processes used to gather pings at a specific time
#   -That same timer also creates a heartbeat file for use with N-Able
#   -Requres Win32::Process and a PID file; includes cleanup in this script
# -Introduced a brief sleep to help counter an apparent race-condition while moving the log files around
# -Implemented Fcntl to ensure only one copy is running at a time
# -Script now continues when re-launched if previous data for today exists
#   -Goes by arguments, not a simple scan, so control is left with the user
# -Arguments can be supplied from an ini file (C:\SS\Latency\Bin\latencyConfig.ini)
# -Arguments can also be supplied from the command line, which overrides the ini

# Force me to write this properly

use strict;
use warnings;

# Modules
use Archive::Zip qw( :ERROR_CODES :CONSTANTS ); # cpanm Archive::Zip
use Config::Simple; # cpanm Config::Simple
use File::Copy; # Built-in
use Getopt::Long qw(:config no_ignore_case); # Built-in
use Net::FTP; # cpanm Net::FTP (Case-sensitive)
use POSIX qw(strftime); # Built-in
BEGIN { $ENV{Smart_Comments} = " @ARGV " =~ / --debug / } # Enable Smart::Comments on demand
use Smart::Comments -ENV; # Not needed in production; cpanm Smart::Comments
use Time::Local; # Built-in
use Win32; # Built-in
use Win32::Autoglob; # cpanm Win32::Autoglob
use Win32::Process; # Built-in

# Where needed, variables are checked by the other scripts
our $VERSION = "0.4a";
#my $interval = 5; # 10 seconds
my $interval = 900; # 15 minutes
$SIG{ALRM} = sub { &alarmAction;
    alarm $interval; };
alarm $interval;
# Pre-declare main variables
my ($site, $maxiterations, $maxping, $ftpSite, $user, $pass, @host);
my ($stopHour, $stopMinute, $curHour, $curMinute);

# Try to read in parameters from the config file
if (-e "C:\\SS\\Latency\\Bin\\latencyConfig.ini") {
    my $cfg = new Config::Simple();
    $cfg->read('C:\\SS\\Latency\\Bin\\latencyConfig.ini') || die $!;
    $site = $cfg->param("site");
    $maxiterations = $cfg->param("maxiterations");
    $maxping = $cfg->param("maxping");
    $ftpSite = $cfg->param("ftpSite");
    $user = $cfg->param("user");
    $pass = $cfg->param("pass");
    @host = $cfg->param("host");
    $stopHour = $cfg->param("stopHour");
    $stopMinute = $cfg->param("stopMinute");
}
my $help;
my $debug; # Dummy variable

# Override parameters if entered on the command line

GetOptions('help|h' => \$help,
    'debug' => \$debug, # Dummy variable
    'site|s:s' => \$site,
    'iterations|i:i' => \$maxiterations,
    'max-ping|m:i' => \$maxping,
    'ftp|f:s' => \$ftpSite,
    'user|u:s' => \$user,
    'pass|p:s' => \$pass,
    'domains|d:s{,}' => \@host,
    'stop-hour|H:i' => \$stopHour,
    'stop-minute|M:i' => \$stopMinute,
) or usage();
if ($help) {
    usage();
}

# Now with real documentation

sub usage {
    die("Usage: $0 [OPTION...] or else defaults to the ini\n
        -h, --help          Display this help text\n
            --debug         Enable debug data via Smart::Comments
        -s, --site          Name of the site, which also names the output files\n
        -i, --iterations    Number of times to ping, unless the script runs out of time\n
        -m, --max-ping      Highest ping to tolerate before triggering a warning\n
        -f, --ftp           URL of the ftp site to upload data to\n
        -u, --user          User name for the ftp site\n
        -p, --pass          Password for the ftp site\n
        -d, --domains       A list of space-separated URLs or IPs to ping\n
        -H, --stop-hours    The hour to stop the script at (24-hour format)\n
        -M, --stop-minute   The minute of the hour to stop the script at (24-hour format)\n"
    );
}

# Warn the user if the config file is missing
unless (-e "C:\\SS\\Latency\\Bin\\latencyConfig.ini") {
    warn("latencyConfig.ini missing\n");
}

# Verify that every variable has _something_ in it, at least
unless ( length $site ) { warn "Variable 'site' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $maxiterations ) { warn "Variable 'max iterations' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $maxping ) { warn "Variable 'maxping' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $ftpSite ) { warn "Variable 'ftp site' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $user ) { warn "Variable 'ftp user' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $pass ) { warn "Variable 'ftp pass' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( scalar @host ) { warn "Variable 'domains' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $stopHour ) { warn "Variable 'stop hour' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }
unless ( length $stopMinute ) { warn "Variable 'stop minute' not defined. If there's no ini file, all arguments are mandatory.\n\n"; usage(); }

# Set a few more variables and the lock

our $datetime = strftime "%m-%d-%Y", localtime;
my $zipdatafilename = "C:\\SS\\Latency\\Archives\\". $site . "-latency-" . $datetime . ".zip";
my $zipdatafilenameShort = "$site" . "-latency-" . $datetime . ".zip";
my $PIDFileName = "C:\\SS\\Latency\\pid.txt";
use Fcntl ':flock';

open my $SELF, '<', $0 or die 'I am already running...';
flock $SELF, LOCK_EX | LOCK_NB  or exit;

### Starting main program
my @children;

### Clear PID file, in case of crash
unlink $PIDFileName;

### Fork based on number of domains
for ( my $count = 0; $count <= $#host; $count++) {
    my $pid = fork();
    if ($pid) {
        # parent
        ### pid is: $pid
        ### parent is: $$
        push(@children, $pid);
    } elsif ($pid == 0) {
        checkem($count);
    } else {
        die "couldn't fork: $!\n";
    }
}

foreach (@children) {
    my $tmp = waitpid($_, 0);
    ### done with pid: $tmp
}

# Back to the main program, which is set to launch the next script
### Making Excel spreadsheet
latency2excel($site);

# And then zip + archive everything to the FTP
### Making zip file
zipIt("C:\\SS\\Latency\\Temp\\Reporting\\*$datetime.*"); # Process only today's files
### Archiving
archiveIt($ftpSite, $user, $pass);

# Clear PID file
unlink $PIDFileName;

# Fin
### End of main program

# Subprocedures

sub checkem {
    # child
    # First, see if we have existing data for today and if so, check for a differential
    my $count = shift;
    if (-e "C:\\SS\\Latency\\Scan\\". $host[$count] . "-latency-" . $datetime . ".txt") {
        ### File exists: "$host[$count]-latency-$datetime.txt"
        open (my $LINES, "<", "C:\\SS\\Latency\\Scan\\". $host[$count] . "-latency-" . $datetime . ".txt")
            or die "unable to open the test file\n";
        my @lines = <$LINES>;
        my $lines = @lines;
        $maxiterations = $maxiterations - $lines;
        ### Discrepency found: "$maxiterations more runs"
        close($LINES)
            or die "Unable to close the test file\n";
    }
    else {
        # If today has no data, see if it's most likely time to start it
        ### Doesn't exist: "$host[$count]. checking if yesterday's data is needed"
        my @time = localtime;
        --$time[3];
        my $yesterday = strftime "%m-%d-%Y",@time;
        if (-e "C:\\SS\\Latency\\Scan\\". $host[$count] . "-latency-" . $yesterday . ".txt") {
            $curHour = (localtime)[2];
            $curMinute = (localtime)[1];
            # Check the time; if the time equals the defined quitting time, count it as a new day
            if ($curHour < $stopHour || $curHour == $stopHour && $curMinute < $stopMinute) {
                # Get yesterday's date
                my @time = localtime;
                --$time[3];
                $datetime = strftime "%m-%d-%Y",@time;
                ### Reviving data from yesterday
            }
            else {
                ### No data for yesterday; starting a new day
            }
        }
        }
        ### $site
        ### $maxiterations
        ### $ftpSite
        ### $user
        ### $pass
        ### @host
        ### $curHour
        ### $curMinute
        ### $stopHour
        ### $stopMinute
        ### $datetime
        latencyTest($count, $site, $maxiterations, $maxping, $host[$count]);
        exit 0;
}

sub latencyTest {
    my ($num, $site, $maxiterations, $maxping, $host) = (@_);
    ### started child process for: $num
    system("C:\\SS\\Latency\\Bin\\latencyTest.pl", "$host", "$maxiterations", "$maxping");
    ### done with child process for: $num
    return $num;
}
sub latency2excel {
    my ($site) = (@_);
    # Note that $maxiterations isn't passed and is assumed to be 85000 for the sake of making the statistical highlighting
    system("C:\\SS\\Latency\\Bin\\latency2excel.pl", "$site", "C:\\SS\\Latency\\Temp\\Staging\\*-latency-$datetime.txt"); # Process only today's files
}

sub zipIt {
    my $zip = Archive::Zip->new();
    my @files = @_;

    foreach my $memberName (map { glob } @files)
    {
        {
            my @protoName = split(/\\/, $memberName);
            my $shortName = $protoName[-1];
            my $member = $zip->addFile( $memberName, $shortName )
                or warn "Can't add file $memberName\n";
        }
    }
    $zip->writeToFileNamed($zipdatafilename);
    foreach my $memberName (map { glob } @files) {
        unlink $memberName; # Delete specific files instead of the entirety of Reports
    }
}
sub archiveIt {
    my $ftpsite = shift;
    my $user = shift;
    my $pass = shift;
    my $ftp = Net::FTP->new("$ftpsite")
        or die "Cannot connect to $ftpsite: $@";
    $ftp->login("$user","$pass")
        or die "Cannot login ", $ftp->message;
    $ftp->mkdir("Files/CustomerFiles/LatencyLogs/$site/");
    $ftp->binary(); # Do not move this or I will cut you
    $ftp->put("$zipdatafilename", "/Files/CustomerFiles/LatencyLogs/$site/$zipdatafilenameShort")
        or die "put failed ", $ftp->message;
    $ftp->quit;
    move $zipdatafilename, "C:\\SS\\Latency\\Archives\\";

}
sub alarmAction {
    ### alarmAction event
    makeLock();
    #checkCrit();
    checkTime();
}

sub makeLock {
    # Used by N-Able to see if script is running; it deletes it after each check
    my $lock = "C:\\SS\\Latency\\latencyLock.dat";
    open (my $LOCK, ">", "$lock")
        or die "unable to create the log file\n";
    close($LOCK)
        or die "Unable to close the lock \n";
}

# sub checkCrit {
# foreach (@host) {
# my $datafilenameWarn = "C:\\SS\\Latency\\Scan\\" . $_ . "-WARN-" . $datetime. ".txt";
# my $datafilenameCrit = "C:\\SS\\Latency\\Scan\\" . $_ . "-CRIT-" . $datetime. ".txt";
# open (my $LOG, "<", "$mydatafilenameWarn") or die("File not accessible\n"
# my @log = <$LOG>;
# close $LOG;
# # Get a line and associate it with its time (perhaps a hash)
# # For each time, see if it's within 5 minutes of the last one (skipping over the first)
# # If it is, increment a counter. At the end, if the counter is 3 or more, write to CRIT.
# }
# }

sub checkTime {
# When countdown reaches 0, kill all children and move on to archival
    my $curHour = (localtime)[2];
    my $curMinute = (localtime)[1];
    if ($curHour == $stopHour && $curMinute >= $stopMinute) {
        open (my $PIDLIST, "<", "$PIDFileName")
            or die "unable to open PID list\n";
        my @PIDList = <$PIDLIST>;
        foreach (@PIDList) {
            Win32::Process::KillProcess($_, 0) # Required due to the way perl handles fork() on Windows
        }

        # Move files for report generation and archival since latencyTest can't in this case
        foreach (@host) {
            my $datafilename = "C:\\SS\\Latency\\Scan\\". $_ . "-latency-" . $datetime . ".txt";
            my $datafilenameWarn = "C:\\SS\\Latency\\Scan\\" . $_ . "-WARN-" . $datetime. ".txt";
            copy $datafilename, "C:\\SS\\Latency\\Temp\\Staging\\" or die "Copy failed $!";
            sleep(1);
            move $datafilename, "C:\\SS\\Latency\\Temp\\Reporting\\" or die "Move failed $!";
            sleep(1);
            move $datafilenameWarn, "C:\\SS\\Latency\\Temp\\Reporting\\" or die "Move failed $!";
        }
    }
}

# Documentation
=pod

=head1 NAME

LatencyMonitor v0.4a - Parallel latency data collection tool for Windows

=head1 SYNOPSIS

     perl latencyLaunch.pl [OPTION...] or else defaults to the ini
     -h, --help          Display this help text
         --debug         Enable debug data via Smart::Comments
     -s, --site          Name of the site, which also names the output files
     -i, --iterations    Number of times to ping, unless the script runs out of time
     -m, --max-ping      Highest ping to tolerate before triggering a warning
     -f, --ftp           URL of the ftp site to upload data to
     -u, --user          User name for the ftp site
     -p, --pass          Password for the ftp site
     -d, --domains       A list of space-separated URLs or IPs to ping
     -H, --stop-hours    The hour to stop the script at (24-hour format)
     -M, --stop-minute   The minute of the hour to stop the script at (24-hour format)

=head1 DESCRIPTION

Essentially, the script is a wrapper around Windows' "ping.exe", capturing and
organising output. It works well in conjunction with N-Able monitoring and was
built with that in mind, producing currently four items of output per session,
those being a file named with the format B<$site-latency-$date.txt>, which
contains the full output of the command, B<$site-WARN.txt>, which includes
just the warning and failure messages, an Excel spreadsheet summarising the
information, and a zip file, which is uploaded to an FTP site. The date is not
included in the warning file in order to make it easier to monitor with N-Able;
it is recommended that the Log (Appended) type of job be used and that the
files be archived for best results. The script is capable of monitoring
multiple sites within a single primary instance, with forks created as
necessary. It takes approximately 85,000 pings at one per second to cover a
little over 24 hours; expect drift to occur if the latency is less than perfect
or the host machine under heavy load. After the log file is finished, or a
specified time reached (06:45 by default), it will automatically be moved to
C:\SS\latency\staging, where it will be converted into an Excel spreadsheet via
latency2excel.pl. Afterwards, the source files and the spreadsheet will be
zipped and uploaded to the provided FTP site.

New in version 0.4a is the ability to recover more gracefully from stops and
overnight reboots, which should enable the script to intelligently write to
the desired/correct data files on a given day.

=head1 INSTALLATION

System requirements:

    -A supported version of Windows (tested and developed under Windows 8.1
  Spring)
    -Approximately 90MB for the default installation of [Strawberry
  Perl](http://www.strawberryperl.com)
    -Various Perl modules (facilitated by sPerlCPAN.pl)
    -Archive::Zip (cpanm Archive::Zip)
    -Config::Simple (cpanm Config::Simple)
    -Excel::Writer::XLSX (cpanm Excel::Writer::XLSX)
    -Net::FTP (cpanm Net::FTP)
    -Smart::Comments (cpanm Smart::Comments) (OPTIONAL, used for debugging)
    -Win32::Autoglob (cpanm Win32::Autoglob)
    -Sufficient space for log files. A day's worth is typically in the
  realm of 10MB or so.
    -UAC needs to be disabled because of Powershell, which has a warped
  idea of what constitutes security.

    -Ensure that the following folders are created:
    -C:\SS\
    -C:\SS\latency\Archives
    -C:\SS\latency\Bin
    -C:\SS\latency\Scan
    -C:\SS\latency\Temp
    -C:\SS\latency\Temp\Reporting
    -C:\SS\latency\Temp\Staging

    -Ensure the config file is created in C:\SS\bin (documented below)

To install, simply ensure that the above conditions are true and either
copy the .pl files to the system and follow the invocation instructions
or, more ideally, create a script within N-Able to deploy it, supplying
input fields for all required parameters and monitoring for WARNING and
FAILURE labels in the appropriate file.

=head1 INVOCATION AND USE

Invocation, done within cmd.exe or Powershell (though perl itself will
execute its processes in cmd), is as follows (assuming the script is in
the current directory):

     perl latencyLaunch.pl [OPTION...] or else defaults to the ini
     -h, --help          Display this help text
         --debug         Enable debug data via Smart::Comments
     -s, --site          Name of the site, which also names the output files
     -i, --iterations    Number of times to ping, unless the script runs out of time
     -m, --max-ping      Highest ping to tolerate before triggering a warning
     -f, --ftp           URL of the ftp site to upload data to
     -u, --user          User name for the ftp site
     -p, --pass          Password for the ftp site
     -d, --domains       A list of space-separated URLs or IPs to ping
     -H, --stop-hours    The hour to stop the script at (24-hour format)
     -M, --stop-minute   The minute of the hour to stop the script at (24-hour format)

The program will attempt to use a configuration file
(C:\SS\latency\Bin\latencyConfig.ini), structured as follows:

     site=siteName
     maxiterations=85000
     maxping=200
     ftpSite=ftp.site.net
     user=ftpUser
     pass=password
     host=8.8.8.8, www.startpage.com
     stopHour=06
     stopMinute=45

Note that the list of hosts is separated by both a comma and whitespace.

Ideally, perl should be automatically put in your B<$PATH> when
installed. All parameters have some basic sanity checking to help
prevent input errors, and if any are found the program will print a
helpful reminder. The program, as described previously, outputs to two
text files and prints one of three things per line, roughly once per second
(a delay of 1 second is built-in to avoid DDOSing the target). Under
normal conditions, a line will be printed as follows:

    06/26/2014 09:13:29 www.google.com 74.125.207.104 78ms

The above contains, in order, the date, the time (24-hour time), the
desired target, the target's IP, and the amount of time the ping took in
milliseconds. Should the maximum ping be met or exceeded, a line similar
to the following will occur:

    WARNING: 06/24/2014 13:40:36 www.google.com 173.194.64.104 256ms

It is constructed precisely the same as a normal line, but is prepended
with WARNING: in order to be easily searchable. Lastly, the third
possible condition is utter failure, which is presented as follows:

    FAILURE: 06/26/2014 08:57:14 ftp.smartsystemsaz.net Invalid host, host
    is offline, or system is not connected

Constructed the same as WARNING, albeit with a bit of a generic message,
which is actually a catch-all for five different conditions in order to
make the log file more readable since they amount to about the same
thing: the connection is completely hosed. For reference, those five
conditions are:

     - General failure
     - Destination host unreachable
     - Ping request could not find host
     - Request timed out
     - TTL expired in transit

As of the latest update, the script has a safeguard to ensure it only runs
once; this allows N-Able to re-launch it periodically in case it stops for
whatever reason, or to start it explicitly after a planned reboot. Along those
same lines, it also has a feature wherein if, when it runs, it detects a
www.google.com latency log dated for that same day, it will count the number of
lines in it and then adjust its run to ensure that the google log has 85000
entries, which further facilitates the usage of planned reboots. Lastly, it
also creates, every fifteen minutes, a "heartbeat" file called latencyLock.dat
which N-Able can use to see if the script is likely running (the script deletes
it upon completion). The script also creates and periodically deletes a file
called B<pid.txt>, which stores the proper PIDs of the forked processes so that
they can be correctly killed when the script completes.

=head1 SETTING UP N-ABLE

In order to use the script with N-Able, it needs to be set up as a
scheduled task consisting of Automation Policies configured to deploy
the script and any needed helpers required. Scripts will be stored on
the company FTP site in their own directory, currently in
*/Dropbox/Automation/Latency*. It is recommended in this case of
latencyTest to deploy individual instances at least two minutes apart to
prevent the host machine from downloading the script over itself
mid-read. While it may seem that the script could only be downloaded
once, by setting it up that way you are preventing automatic updates to
the script.

As mentioned previously, a run takes approximately 24 hours by default, though
it will stop at the nearest instance of whatever stop time is defined. After
the runs are complete, the script will automatically copy the main log to a
Staging folder, where it can be further processed with the companion script
*latency2excel.pl*. Afterwards, it will be archived and uploaded.

While the script is deployed, it needs to be monitored by N-Able. To do
so, make use of the appended log monitor, which is able to look at the
WARN file every five minutes or so and remember where it left off. When
this service sees the appropraite regex (define one as WARNING and one as
FAILURE) it can react as needed, ideally sending a notification to the support
account and creating an appropriate ticket. These services and profiles are all
bundled under "Latency" under the SmartSystems account in N-Able. Again, note
also the existence of the latencyLock.dat file and act accordingly; it is
suggested to set up an automation policy to delete the file if it's there and
re-launch the script if it's not there.

For reference, here is the intended file tree:

    SS
    L-- Latency
        |-- pid.txt
        |-- Bin
            L--latencyLock.dat
            L--latencyConfig.ini
        |-- Archives
        |-- Scan
        |   L-- LatencyFile.txt
        |   L-- Warn.txt
        L-- Temp
            |-- Reporting
            L-- Staging

=head1 AUTHOR

Cory Sadowski <cory@smartsystemsaz.com>

=cut
