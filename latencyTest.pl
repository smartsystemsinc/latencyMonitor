#!/usr/bin/env perl

# Force me to write this properly

use strict;
use warnings;
use POSIX qw(strftime);
use File::Copy; # Built-in

# Variables
if ($#ARGV <2 ) {
    die("Usage: latencyTest.pl <domain or IP> <iterations> <max ping>\n");
}
my $host = $ARGV[0];

if ($host eq "foo") {
    exit 0;
}

# Matches "www.whatever.com" and IPs, basically. # is being used as a delimiter instead of / because it's easier to handle.
unless ($host =~ m#^(www.|[a-zA-Z].)[a-zA-Z0-9\-\.]+\.(com|edu|gov|mil|net|org|biz|info|name|museum|us|ca|uk)(\:[0-9]+)*(/($|[a-zA-Z0-9\.\,\;\?\'\\\+&amp;%\$\#\=~_\-]+))*$# || $host =~ m/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/){
    die("Site must be of the format <[www].test.com> or xxx.xxx.xxx.xxx\n");
}

my $maxiterations = $ARGV[1]; # maximum number of iterations/pings
unless ($maxiterations =~ m/^\d+$/) {
    die("Iterations must be an integer\n");
}
my $maxping = $ARGV[2]; # maximum ping tolerated
unless ($maxping =~ m/^\d+$/) {
    die("Max ping must be an integer\n");
}
if ($maxping == 0) {
    die("Max ping must be an integer greater than zero\n");
}

my $maxtimetowait = 1; # maximum time to wait between ping, in seconds
my $i = 0; # simple iterator

# build the filename for the data files
my $datetime = strftime "%m-%d-%Y", localtime;
my $datafilename = "C:\\SS\\Latency\\Scan\\". $host . "-latency-" . $datetime . ".txt";
my $datafilenameWarn = "C:\\SS\\Latency\\Scan\\" . $host . "-WARN-" . $datetime. ".txt";

open (my $OUTPUT, ">>", "$datafilename")
    or die "unable to create the log file\n";
open (my $OUTPUTWARN, ">>", "$datafilenameWarn")
    or die "unable to create the warning file\n";
# Record true PID from forking
my $PIDFileName = "C:\\SS\\Latency\\pid.txt";
open (my $PIDFILE, ">>", "$PIDFileName")
    or die "unable to create the log file\n";
print $PIDFILE "$$\n";
close($PIDFILE)
    or die "Unable to close the data file ($PIDFileName)\n";

while($i < $maxiterations)
{
    my $curiteration = $i+1;
    # build timestamp
    my $datetime = strftime "%m/%d/%Y %H:%M:%S", localtime;

    # run an instance of ping.exe
    my $p = `ping.exe -n 1 $host`;
    if ($p =~ m/General failure/ || $p =~ m/Destination host unreachable/ || $p =~ m/Ping request could not find host/ || $p =~ m/Request timed out/ || $p =~ m/TTL expired in transit/) {
        my $chain = "$datetime $host";
        # Iterations here are relative if the script was continued from a previous session
        print ("[Iteration $curiteration/$maxiterations] FAILURE: $chain Invalid host, host is offline, or system is not connected\n");
        print $OUTPUT ("FAILURE: $chain Invalid host, host is offline, or system is not connected\n");
        print $OUTPUTWARN ("FAILURE: $chain Invalid host, host is offline, or system is not connected\n");
        my $timetowait = rand($maxtimetowait) + 1;
        sleep($timetowait);
        $i++;
        next;
    }
    my ($ip) = $p =~ /Reply from (\d+[.][\d.]+)/;
    my ($duration) = $p =~ /time=(\d+)/;

    # write part of the result
    my $chain = "$datetime $host $ip";

    if($duration <= $maxping) {

        # print the result, both on screen ...
        printf("[Iteration $curiteration/$maxiterations] SUCCESS: $chain %.0fms\n", $duration);

        # ...	and in the datafile(s)
        print $OUTPUT sprintf("SUCCESS: $chain %.0fms\n", $duration);
    }
    else {

        printf("[Iteration $curiteration/$maxiterations] WARNING: $chain %.0fms\n", $duration);
        print $OUTPUT sprintf("WARNING: $chain %.0fms\n", $duration);
        print $OUTPUTWARN sprintf("WARNING: $chain %.0fms\n", $duration);
    }

    my $timetowait = rand($maxtimetowait) + 1;
    sleep($timetowait);

    $i++;
}

# close the output files
close($OUTPUT)
    or die "Unable to close the data file ($datafilename). Results should remain unaffected\n";
close($OUTPUTWARN)
    or die "Unable to close the data file ($datafilenameWarn). Results should remain unaffected\n";

# Move files for report generation and archival
copy $datafilename, "C:\\SS\\Latency\\Temp\\Staging\\";
sleep(1);
move $datafilename, "C:\\SS\\Latency\\Temp\\Reporting\\";
sleep(1);
move $datafilenameWarn, "C:\\SS\\Latency\\Temp\\Reporting\\";
