#!/usr/bin/env perl

# Force me to write this properly

use warnings;
use strict;
use 5.0010;    # For the sake of switch
##no critic (TestingAndDebugging::ProhibitNoWarnings)
no warnings 'experimental::smartmatch';
use feature 'switch';

# Modules
use Algorithm::Loops qw( NestedLoops );            # cpan Algorithm::Loops
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );    # cpan Archive::Zip
use Carp;                                          # Built-in
use Config::Simple;    # dpkg libconfig-simple-perl || cpan Config::Simple

# NOTE: Keep the encoding of the INI file ANSI or else things go all to hell
use Date::Manip;                 # dpkg libdate-manip-perl || cpan Date::Manip
use English qw(-no_match_vars);  # built-in
use Excel::Writer::XLSX
    ; # dpkg libexcel-writer-xslx-perl || cpan Excel::Writer::XLSX (Case-sensitive)
use Fcntl ':flock';
use File::Basename;                             # Built-in
use File::Copy;                                 # Built-in
use Getopt::Long qw(:config no_ignore_case);    # Built-in
use Net::FTP;                                   # cpan Net::FTP
use PerlIO::Util;                               # cpan --notest PerlIO::Util
use Pod::Usage;                                 # Built-in
use POSIX qw(strftime);                         # Built-in

## no critic (RequireLocalizedPunctuationVars)
BEGIN {
    $ENV{Smart_Comments} = " @ARGV " =~ /--debug/xms
        ; # Enable Smart::Comments on demand. Keep this BEGIN block above the use statement.
}

use Smart::Comments -ENV;    # cpan Smart::Comments
use Time::Local;             # Built-in
if ( $OSNAME eq 'MSWin32' ) {
    require Win32;              # Built-in
    require Win32::Autoglob;    # cpan Win32::Autoglob
    require Win32::Process;     # Built-in
}

### OS: $OSNAME

INIT {
    if ( !flock main::DATA, LOCK_EX | LOCK_NB ) {
        print "$PROGRAM_NAME is already running\n" or croak $ERRNO;
        exit 1;
    }
}

our $VERSION = '0.6';

# Pre-declare main variables
my ( $site, $maxiterations, $maxping, $ftp_site, $user, $pass, @host );
my ($stop_hour, $stop_minute, $cur_hour, $cur_minute,
    $open_hour, $close_hour,  $crit_warn
);
my $interval;
my ($root, $base,      $bin,     $archives, $scan,
    $temp, $reporting, $staging, $config
);
if ( $OSNAME eq 'MSWin32' ) {
    $root = 'C:/SS';
    $base = "$root/Latency";
}
elsif ( $OSNAME eq 'linux' ) {
    $root = $ENV{'HOME'} . '/.local/share/SS';
    $base = "$root/Latency";
}
my @win_cleanup;
$bin       = "$base/Bin";
$archives  = "$base/Archives";
$scan      = "$base/Scan";
$temp      = "$base/Temp";
$reporting = "$temp/Reporting";
$staging   = "$temp/Staging";
$config    = "$bin/latencyConfig.ini";

my @dirs
    = ( $root, $base, $bin, $archives, $scan, $temp, $reporting, $staging );
### @dirs
if ( $OSNAME eq 'linux' ) {
    my $local = $ENV{'HOME'} . '/.local';
    my $share = $ENV{'HOME'} . '/.local/share';
    if ( !-d $local ) { mkdir $local or croak $ERRNO }
    if ( !-d $share ) { mkdir $share or croak $ERRNO }
}
foreach my $dir (@dirs) {
    if ( !-d $dir ) {
        mkdir $dir or croak $ERRNO;
    }
}

my $datetime = strftime '%m-%d-%Y', localtime;

# Try to read in parameters from the config file
if ( -e "$config" ) {
    my $cfg = Config::Simple->new();
    $cfg->read("$config") || croak $ERRNO;
    $site          = $cfg->param('site');
    $maxiterations = $cfg->param('maxiterations');
    $maxping       = $cfg->param('maxping');
    $ftp_site      = $cfg->param('ftpSite');
    $user          = $cfg->param('user');
    $pass          = $cfg->param('pass');
    @host          = $cfg->param('host');
    $stop_hour     = $cfg->param('stopHour');
    $stop_minute   = $cfg->param('stopMinute');
    $open_hour     = $cfg->param('openHour');
    $close_hour    = $cfg->param('closeHour');
    $crit_warn     = $cfg->param('critWarn');
}

# Override parameters if entered on the command line

GetOptions(
    'help|h'          => \my $help,
    'debug'           => \my $debug,           # Dummy variable
    'preserve-time'   => \my $preserve_time,
    'man'             => \my $man,
    'version'         => \my $version,
    'clean'           => \my $clean,
    'site|s:s'        => \$site,
    'iterations|i:i'  => \$maxiterations,
    'max-ping|m:i'    => \$maxping,
    'ftp|f:s'         => \$ftp_site,
    'user|u:s'        => \$user,
    'pass|p:s'        => \$pass,
    'domains|d:s{,}'  => \my @host2,
    'stop-hour|H:i'   => \$stop_hour,
    'stop-minute|M:i' => \$stop_minute,
    'open-hour|O:i'   => \$open_hour,
    'close-hour|C:i'  => \$close_hour,
    'crit-warn|W:i'   => \$crit_warn,
) or pod2usage( -verbose => 0 );

if ($help) {
    pod2usage( -verbose => 0 );
}
if ($man) {
    pod2usage( -verbose => 2 );
}
if ($version) {
    croak "latencyMonitor v$VERSION\n";
}

if ($clean) {
    clean();
}

if (@host2)
{ # Necessary to clear the array so that hosts from the INI and the argument don't mix
    @host = @host2;
}

if ( $debug && !$preserve_time ) {
    $interval = '5';    # 10 seconds
}
else {
    $interval = '900';    # 15 minutes
}

my $finishing = 0;
local $SIG{ALRM} = sub {
    if ( $finishing != 1 ) {
        alarm_action();
        alarm $interval;
    }
};
alarm $interval;

# Warn the user if the config file is missing
if ( !-f "$config" ) {
    warn "latencyConfig.ini missing\n";
}

# Verify that every variable has _something_ in it, at least
if ( !length $site ) {
    warn
        "Variable 'site' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $maxiterations ) {
    warn
        "Variable 'max iterations' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $maxping ) {
    warn
        "Variable 'maxping' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $ftp_site ) {
    warn
        "Variable 'ftp site' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $user ) {
    warn
        "Variable 'ftp user' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $pass ) {
    warn
        "Variable 'ftp pass' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !scalar @host ) {
    warn
        "Variable 'domains' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $stop_hour ) {
    warn
        "Variable 'stop hour' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $stop_minute ) {
    warn
        "Variable 'stop minute' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $open_hour ) {
    warn
        "Variable 'open hour' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $close_hour ) {
    warn
        "Variable 'close hour' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}
if ( !length $crit_warn ) {
    warn
        "Variable 'crit warn' not defined. If there's no ini file, all arguments are mandatory.\n\n";
    pod2usage( -verbose => 0 );
}

# Set a few more variables

my $zipdatafilename = "$archives/" . $site . '-latency-' . $datetime . '.zip';
my $zipdatafilename_short = "$site" . '-latency-' . $datetime . '.zip';
my $debug_file = "$archives/" . $site . '-debug-' . $datetime . '.txt';

if ($debug) {
    *STDOUT->push_layer( tee => ">>$debug_file" );
    *STDERR->push_layer( tee => ">>$debug_file" );
}

### Starting main program
my @children;

### Fork based on number of domains
for ( my $count = 0; $count <= $#host; $count++ ) {
    my $pid = fork;
    if ($pid) {

        # parent
        ### pid is: $pid
        ### parent is: $$
        push @children, $pid;
    }
    elsif ( $pid == 0 ) {
        checkem($count);    # Leaves files in $staging
    }
    else {
        croak "couldn't fork: $ERRNO\n";
    }
}

foreach (@children) {
    my $tmp = waitpid $_, 0;
    ### done with pid: $tmp
    $finishing = 1;
}

### Preparing files
move_it();

### Making Excel spreadsheet
latency2excel();    # Leaves files in $reporting

### Making zip file
zip_it("$reporting/*$datetime.*");    # Process only today's files
### Archiving
archive_it();                         # Leaves files on FTP and in $archives
if ( $OSNAME eq 'MSWin32' ) {
    windows_cleanup();                # $SELF is closed here via brute force
    exit;
}

### End of main program

# Subprocedures

sub checkem {

# child
# First, see if we have existing data for today and if so, check for a differential
    my $count = shift;
    my $file_today
        = "$scan/" . $host[$count] . '-latency-' . $datetime . '.txt';
    if ( -e $file_today ) {
        ### File exists: "$host[$count]-latency-$datetime.txt"
        open my $LINES, '<',
            "$scan/" . $host[$count] . '-latency-' . $datetime . '.txt'
            or croak "unable to open the test file\n";
        my @lines = <$LINES>;
        my $lines = @lines;
        $maxiterations = $maxiterations - $lines;
        ### Discrepency found: "$maxiterations more runs"
        close $LINES
            or croak "Unable to close the test file\n";
    }
    else {
        # If today has no data, see if it's most likely time to start it
        ### Doesn't exist: "$host[$count]. checking if yesterday's data is needed"
        my @time = localtime;
        --$time[3];
        my $yesterday = strftime '%m-%d-%Y', @time;
        my $file_yesterday
            = "$scan/" . $host[$count] . '-latency-' . $yesterday . '.txt';
        if ( -e $file_yesterday ) {
            $cur_hour   = (localtime)[2];
            $cur_minute = (localtime)[1];
            ### $cur_hour
            ### $cur_minute

# Check the time; if the time equals the defined quitting time, count it as a new day
            if (   $cur_hour < $stop_hour
                || $cur_hour == $stop_hour && $cur_minute < $stop_minute )
            {
                # Get yesterday's date
                my @yesterday = localtime;
                --$yesterday[3];
                $datetime = strftime '%m-%d-%Y', @yesterday;
                ### Reviving data from yesterday
            }
            else {
                ### No data for yesterday; starting a new day
            }
        }
    }
    ### $site
    ### $maxiterations
    ### $ftp_site
    ### $user
    ### $pass
    ### @host
    ### $stop_hour
    ### $stop_minute
    ### $open_hour
    ### $close_hour
    ### $crit_warn
    ### $datetime
    latency_test( $count, $host[$count] );
    exit 0;
}

sub latency_test {
    my ( $num, $host ) = @_;
    ### started child process for: $num

    if ( $host eq 'foo' ) {
        exit 0;
    }

    my $HOST = qr{^(www.|[[:alpha:]].)[[:alpha:]][\d][-][.]]+[.]}xms;
    my $TLD  = qr{(com|edu|gov|mil|net|org|biz|info|name|museum|us|ca|uk)}xms;
    my $URL  = qr{ ( ($HOST) ($TLD) ) }xms;
    my $IP   = qr{^[\d]{1,3}[.][\d]{1,3}[.][\d]{1,3}[.][\d]{1,3}}xms;

    if ( !$host =~ $URL || !$host =~ $IP ) {
        croak(
            "Host $host must be of the format <[www].test.com> or xxx.xxx.xxx\n"
        );
    }

    if ( $maxiterations !~ m/^\d+$/xms ) {
        croak("Iterations must be an integer\n");
    }
    if ( $maxping !~ m/^\d+$/xms ) {
        croak("Max ping must be an integer\n");
    }
    if ( $maxping == 0 ) {
        croak("Max ping must be an integer greater than zero\n");
    }

    my $maxtimetowait = 1;    # Maximum time to wait between ping, in seconds
    my $i             = 0;    # Simple iterator

    # Build the filename for the data files
    my $datafilename = "$scan/" . $host . '-latency-' . $datetime . '.txt';
    my $datafilename_warn = "$scan/" . $host . '-WARN-' . $datetime . '.txt';
    my $datafilename_crit = "$scan/" . $host . '-CRIT-' . $datetime . '.txt';

    open my $OUTPUT, '>>', "$datafilename"
        or croak "unable to create the log file\n";
    open my $OUTPUTWARN, '>>', "$datafilename_warn"
        or croak "unable to create the warning file\n";
    open my $OUTPUTCRIT, '>>', "$datafilename_crit"
        or croak "unable to create the warning file\n";

    while ( $i < $maxiterations ) {
        my $curiteration = $i + 1;
        my $ip;
        my $p;

        # build timestamp
        my $timestamp = strftime '%m/%d/%Y %H:%M:%S', localtime;

        # run an instance of ping.exe
        if ( $OSNAME eq 'MSWin32' ) {
            $p = `ping.exe -n 1 $host`;
        }
        elsif ( $OSNAME eq 'linux' ) {
            $p = `ping -c 1 $host`;
        }
        ### $p
        if (   $p =~ m/General[ ]failure/xms
            || $p =~ m/Destination[ ]host[ ]unreachable/xms
            || $p =~ m/Ping[ ]request[ ]could[ ]not[ ]find[ ]host/xms
            || $p =~ m/Request[ ]timed[ ]out/xms
            || $p =~ m/TTL[ ]expired[ ]in[ ]transit/xms )
        {
            my $chain = "$timestamp $host";

# Iterations here are relative if the script was continued from a previous session
            print
                "[Iteration $curiteration/$maxiterations] FAILURE: $chain Invalid host, host is offline, or system is not connected\n"
                or croak $ERRNO;
            print {$OUTPUT}
                "FAILURE: $chain Invalid host, host is offline, or system is not connected\n"
                or croak $ERRNO;
            print {$OUTPUTWARN}
                (
                "FAILURE: $chain Invalid host, host is offline, or system is not connected\n"
                ) or croak $ERRNO;
            my $timetowait = rand($maxtimetowait) + 1;
            sleep $timetowait;
            $i++;
            next;
        }
        if ( $OSNAME eq 'MSWin32' ) {
            ($ip) = $p =~ /Reply[ ]from[ ](\d+[.][\d.]+)/xms;
        }
        elsif ( $OSNAME eq 'linux' ) {
            ($ip) = $p =~ /PING.+([(]\d+[.]\d+[.][\d.]+[)])/xms;
        }
        ### $ip
        my ($duration) = $p =~ /time\s?=?<?(\d+)/xms;

        # write part of the result
        my $chain = "$timestamp $host $ip";

        if ( $duration <= $maxping ) {

            # print the result, both on screen ...
            printf
                "[Iteration $curiteration/$maxiterations] SUCCESS: $chain %.0fms\n",
                $duration
                or croak $ERRNO;

            # ...	and in the datafile(s)
            print {$OUTPUT} sprintf "SUCCESS: $chain %.0fms\n", $duration
                or croak $ERRNO;
        }
        else {

            printf
                "[Iteration $curiteration/$maxiterations] WARNING: $chain %.0fms\n",
                $duration
                or croak $ERRNO;
            print {$OUTPUT} sprintf "WARNING: $chain %.0fms\n", $duration
                or croak $ERRNO;
            print {$OUTPUTWARN} sprintf "WARNING: $chain %.0fms\n", $duration
                or croak $ERRNO;
        }

        my $timetowait = rand($maxtimetowait) + 1;
        sleep $timetowait;

        $i++;
    }

    # close the output files
    close $OUTPUT
        or croak
        "Unable to close the data file  $datafilename. Results should remain unaffected\n";
    close $OUTPUTWARN
        or croak
        "Unable to close the data file  $datafilename_warn. Results should remain unaffected\n";
    close $OUTPUTCRIT
        or croak
        "Unable to close the data file ($datafilename_crit). Results should remain unaffected\n";
    return $num;
}

sub move_it {
    foreach (@host) {
        my $datafilename = "$scan/" . $_ . '-latency-' . $datetime . '.txt';
        ### $datafilename
        my $datafilename_warn = "$scan/" . $_ . '-WARN-' . $datetime . '.txt';
        ### $datafilename_warn
        my $datafilename_crit = "$scan/" . $_ . '-CRIT-' . $datetime . '.txt';
        ### $datafilename_crit
        copy $datafilename, "$staging/" or carp "Copy failed $ERRNO";
        if ( $OSNAME eq 'MSWin32' ) {
            push @win_cleanup, $datafilename, $datafilename_warn,
                $datafilename_crit;
            foreach ( $datafilename, $datafilename_warn, $datafilename_crit )
            {
                copy $_, "$reporting/"
                    or carp "Copy failed $ERRNO";
            }
        }
        elsif ( $OSNAME eq 'linux' ) {
            foreach ( $datafilename, $datafilename_warn, $datafilename_crit )
            {
                move $_, "$reporting/" or carp "Move failed $ERRNO";
            }
        }
    }
    return;
}

sub latency2excel {

# Note that $maxiterations isn't passed and is assumed to be 85000 for the sake of making the statistical highlighting

    # Create a new Excel workbook
    my @files = "$staging/*-latency-$datetime.txt";
    ### files: map {glob} @files
    my $workbook = Excel::Writer::XLSX->new("$staging/$site-$datetime.xlsx");
    $workbook->set_optimization();

    # Define formatting for labels and conditions
    my $blue   = '#83CAFF';
    my $green  = '#579D1C';
    my $yellow = '#FFD320';
    my $red    = '#C5000B';
    my $f_info = $workbook->add_format(
        bold      => 1,
        underline => 1,
        size      => 16,
        align     => 'center'
    );
    my $f_label = $workbook->add_format(
        bold     => 1,
        size     => 14,
        bg_color => "$blue"
    );
    my $f_lable_thresh = $workbook->add_format(
        bold     => 1,
        size     => 11,
        bg_color => "$blue"
    );
    my $f_lable_warn = $workbook->add_format(
        bold     => 1,
        size     => 14,
        bg_color => "$blue"
    );
    my $f_lable_fail = $workbook->add_format(
        bold     => 1,
        size     => 14,
        bg_color => "$blue"
    );
    my $f_bad  = $workbook->add_format( bg_color => "$red" );
    my $f_warn = $workbook->add_format( bg_color => "$yellow" );
    my $f_ok   = $workbook->add_format( bg_color => "$green" );
    my $f_latency = $workbook->add_format(
        bg_color   => "$blue",
        num_format => '#,##0'
    );
    my $f_percent = $workbook->add_format(
        num_format => '0.0%',
        bg_color   => "$yellow"
    );    # Color will be modified via conditional formatting

    foreach my $file ( map {glob} @files ) {

        # Add a worksheet
        my @protosheetname = split /-/xms, $file;
        my $sheetname = $protosheetname[0];
        @protosheetname = split /\//xms, $sheetname;
        $sheetname = $protosheetname[-1];
        ### $sheetname
        my $worksheet = $workbook->add_worksheet($sheetname);
        my $row       = 0;

        ## no critic (RequireBriefOpen)
        open my $TXTFILE, '<', "$file" or croak("File not accessible\n");
        while (<$TXTFILE>) {
            chomp;

            # Get variables
            my $col     = 0;
            my @values  = split;
            my $status  = $values[0];
            my $date    = $values[1];
            my $time    = $values[2];
            my $url     = $values[3];
            my $ip      = $values[4];
            my $latency = $values[5];
            $latency =~ s/ms//xms;

            # Write data
            $worksheet->write( $row, $col, $status );
            $col++;
            $worksheet->write( $row, $col, $date );
            $col++;
            $worksheet->write( $row, $col, $time );
            $col++;
            $worksheet->write( $row, $col, $url );
            $col++;
            $worksheet->write( $row, $col, $ip );
            $col++;
            $worksheet->write( $row, $col, $latency );

            if ( $row < 10 ) {

                ## no critic (ValuesAndExpressions::RequireInterpolationOfMetachars)
                # Create statistical formulae
                given ($row) {
                    when (/0/xms) {
                        $worksheet->write( 'H1', 'Information', $f_info );
                        $worksheet->write( 'J1', 'Thresholds',  $f_info );
                    }
                    when (/2/xms) {
                        $worksheet->write( 'H3', 'Count', $f_label );
                        $worksheet->write_formula( 'I3', '=COUNTA($A:$A)' );
                    }
                    when (/3/xms) {
                        $worksheet->write( 'H4', 'Warnings', $f_lable_warn );
                        $worksheet->write_formula( 'I4',
                            '=COUNTIF($A:$A,"WARNING:")', $f_warn );
                        $worksheet->write( 'J4', '>200ms', $f_lable_thresh );
                    }
                    when (/4/xms) {
                        $worksheet->write( 'H5', 'Failures', $f_lable_fail );
                        $worksheet->write_formula( 'I5',
                            '=COUNTIF($A:$A,"FAILURE:")', $f_bad );
                        $worksheet->write( 'J5', q{}, $f_lable_thresh );
                    }
                    when (/5/xms) {
                        $worksheet->write( 'H6', 'Average Latency',
                            $f_label );
                        $worksheet->write_formula( 'I6', '=SUM($F:$F)/(I3)',
                            $f_latency );
                        $worksheet->write( 'J6', '>=200', $f_lable_thresh );
                    }
                    when (/6/xms) {
                        $worksheet->write( 'H7', '% high latency', $f_label );
                        $worksheet->write_formula( 'I7', '=(I4/(I3))',
                            $f_percent );
                        $worksheet->write( 'J7', '>=10%', $f_lable_thresh );
                    }
                    when (/7/xms) {
                        $worksheet->write( 'H8', '% high latency (200-499)',
                            $f_label );
                        $worksheet->write_comment( 'H8',
                            'Relative to % high latency, not the entire dataset'
                        );
                        $worksheet->write_formula(
                            'I8',
                            '=IF(I4=0,0,(COUNTIFS($F:$F,">199",$F:$F,"<500"))/I4)',
                            $f_percent
                        );
                        $worksheet->write( 'J8', q{}, $f_lable_thresh );
                    }
                    when (/8/xms) {
                        $worksheet->write( 'H9', '% high latency (500)',
                            $f_label );
                        $worksheet->write_comment( 'H9',
                            'Relative to % high latency, not the entire dataset'
                        );
                        $worksheet->write_formula( 'I9',
                            '=IF(I4=0,0,(COUNTIF($F:$F,">=500")/I4))',
                            $f_percent );
                        $worksheet->write( 'J9', '>=50%', $f_lable_thresh );
                    }
                    when (/9/xms) {

                        $worksheet->write( 'H10', '% of packets dropped',
                            $f_label );
                        $worksheet->write_formula( 'I10', '=(I5/(I3))',
                            $f_percent );
                        $worksheet->write( 'J10', '>=10%', $f_lable_thresh );
                    }
                }

            }
            $row++;
        }
        close $TXTFILE or croak $ERRNO;

        # Clean up file after use, since it's a copy
        unlink $file;

        # Format I6 as "bad" if average latency >= 200
        $worksheet->conditional_formatting(
            'I6',
            {   type     => 'cell',
                criteria => '>=',
                value    => '200',
                format   => $f_bad,
            }
        );

        # Otherwise format it as "OK"
        $worksheet->conditional_formatting(
            'I6',
            {   type     => 'cell',
                criteria => '<',
                value    => '200',
                format   => $f_ok,
            }
        );

        # Format I7 as "bad" if % high latency >=10
        $worksheet->conditional_formatting(
            'I7',
            {   type     => 'cell',
                criteria => '>=',
                value    => 0.10,
                format   => $f_bad,
            }
        );

        # Otherwise format it as "OK"
        $worksheet->conditional_formatting(
            'I7',
            {   type     => 'cell',
                criteria => '<',
                value    => 0.10,
                format   => $f_ok,
            }
        );

        # Format I9 as "bad" if % high latency (500+) >= 50
        $worksheet->conditional_formatting(
            'I9',
            {   type     => 'cell',
                criteria => '>=',
                value    => 0.50,
                format   => $f_bad,
            }
        );

        # Otherwise format it as "OK"
        $worksheet->conditional_formatting(
            'I9',
            {   type     => 'cell',
                criteria => '<',
                value    => 0.50,
                format   => $f_ok,
            }
        );

        # Format I10 as "bad" if % of packets dropped >= 10
        $worksheet->conditional_formatting(
            'I10',
            {   type     => 'cell',
                criteria => '>=',
                value    => 0.10,
                format   => $f_bad,
            }
        );

        # Otherwise format it as "OK"
        $worksheet->conditional_formatting(
            'I10',
            {   type     => 'cell',
                criteria => '<',
                value    => 0.10,
                format   => $f_ok,
            }
        );

        # Set colum widths, hide data columns A-G
        $worksheet->set_column( 'A:C', '10', undef, 1 );
        $worksheet->set_column( 'D:D', '20', undef, 1 );
        $worksheet->set_column( 'E:E', '15', undef, 1 );
        $worksheet->set_column( 'F:F', '5',  undef, 1 );
        $worksheet->set_column( 'G:G', '5',  undef, 1 );
        $worksheet->set_column( 'H:H', '29' );
        $worksheet->set_column( 'J:J', '15' );

    }
    $workbook->close();

    # Move it for archivng
    move "$staging/$site-$datetime.xlsx", "$reporting"
        or croak $ERRNO;    # Only move today's files
    return;
}

sub zip_it {
    my @files = @_;
    my $zip   = Archive::Zip->new();

    foreach my $member_name ( map {glob} @files ) {
        {
            my @proto_name = split /\//xms, $member_name;
            my $short_name = $proto_name[-1];
            my $member     = $zip->addFile( $member_name, $short_name )
                or carp "Can't add file $member_name\n";
        }
    }
    $zip->writeToFileNamed($zipdatafilename);
    foreach my $member_name ( map {glob} @files ) {
        unlink $member_name
            ;    # Delete specific files instead of the entirety of Reports
    }
    return;
}

sub archive_it {

    ### Connecting to FTP site
    my $ftp = Net::FTP->new("$ftp_site")
        or croak "Cannot connect to $ftp_site: $EVAL_ERROR";
    ### Logging in
    $ftp->login( "$user", "$pass" )
        or croak 'Cannot login ', $ftp->message;
    ### Ensuring directories exist
    $ftp->mkdir("Files/CustomerFiles/LatencyLogs/$site/");
    $ftp->binary();    # Do not move this or I will cut you
    ### Uploading file
    ### $zipdatafilename
    $ftp->put( "$zipdatafilename",
        "/Files/CustomerFiles/LatencyLogs/$site/$zipdatafilename_short" )
        or croak 'put failed ', $ftp->message;
    $ftp->quit;
    move $zipdatafilename, "$archives";
    return;
}

sub alarm_action {
    ### alarm_action event
    check_crit();
    check_time();
    return;
}

sub check_crit {
    ### Initiating check_crit
    foreach (@host) {
        my $datafilename_warn = "$scan/" . $_ . '-WARN-' . $datetime . '.txt';
        my $datafilename_crit = "$scan/" . $_ . '-CRIT-' . $datetime . '.txt';
        my $cur_time          = localtime;
        my @times;
        open my $LOG, '<', "$datafilename_warn"
            or return;    #warn("File not accessible $ERRNO\n");
        my @log = <$LOG>;
        close $LOG or croak $ERRNO;
        if (@log) {

            foreach my $line (@log) {
                my @values = split q{ }, $line;
                ### @values
                my $date = $values[1];
                ### $date
                my $time = $values[2];
                ### $time
                my $timestamp = $date . q{ } . $time;
                ### $timestamp

                $cur_time = UnixDate( ParseDate($timestamp), '%Y%m%d%H%M%S' );
                my $deltastr = "$interval seconds ago";
                my $fifteen_ago = DateCalc( $cur_time, $deltastr );
                $fifteen_ago
                    = UnixDate( ParseDate($fifteen_ago), '%Y%m%d%H%M%S' );
                ### $timestamp
                ### $cur_time
                ### $fifteen_ago

                if ( $timestamp ge $fifteen_ago && $timestamp le $cur_time ) {
                    push @times, $line;
                }
            }
            if ( scalar @times >= $crit_warn ) {
                my $cur_hour_crit = (localtime)[2];
                if (   $cur_hour_crit >= $open_hour
                    && $cur_hour_crit <= $close_hour )
                {    # Write only during business hours
                    open my $OUTPUTCRIT, '>>', "$datafilename_crit"
                        or carp "unable to open the crit file\n";
                    foreach my $line (@times) {
                        print {$OUTPUTCRIT} ("CRITICAL: $line\n")
                            or croak $ERRNO;
                    }
                    close $OUTPUTCRIT or croak $ERRNO;
                }
            }
        }
    }
    return;
}

sub check_time {

    # When countdown reaches 0, kill all children and move on to archival
    ### Initiating check_time
    my $cur_hour_check   = (localtime)[2];
    my $cur_minute_check = (localtime)[1];
    if ( $cur_hour_check == $stop_hour && $cur_minute_check >= $stop_minute )
    {
        $finishing = 1;
        print "$stop_hour:$stop_minute reached, shutting down\n"
            or croak $ERRNO;
        if ( $OSNAME eq 'MSWin32' ) {
            ### @children
            foreach (@children) {
                kill 9, $_;
            }
        }
        elsif ( $OSNAME eq 'linux' ) {
            ### @children
            foreach (@children) {
                kill 'SIGTERM', $_;
            }
        }

        if ( $OSNAME eq 'MSWin32' ) {
            move_it();
            windows_finish();
            windows_cleanup();
            exit 0;
        }
    }
}

# These extra subs and the exception code above is necessary because Windows
# doesn't understand the concept of a fork, and as such perl is forced to use
# threading instead to try and emulate it. Because this is imperfect, the
# children can't be killed normally and have to be terminated with kill 9,
# which leaves the parents waiting forever. To work around this, the next parts
# of the script have to be started manually. Then, to properly clean up, since
# Windows is obscenely paranoid about how it handles open files, we kill every
# possible filehandle (since the ones we'd need are out of scope at this point)
# and then delete the files.

sub windows_finish {
    ### Making Excel spreadsheet (Windows)
    latency2excel();
    ### Making zip file (Windows)
    zip_it("$reporting/*$datetime.*");    # Process only today's files
    ### Archiving (Windows)
    archive_it();
    return;
}

sub windows_cleanup {
    for ( 3 .. 1024 ) {
        POSIX::close($_);                 # Arbitrary upper bound
    }
    ### @win_cleanup
    unlink @win_cleanup or carp "Unable to cleanup files (Windows) $ERRNO";
    return;
}

sub clean {

    # Ensure we have all the data we need
    if ( !length $site ) {
        warn
            "Variable 'site' not defined. If there's no ini file, supply it manually.\n\n";
        pod2usage( -verbose => 0 );
    }
    if ( !length $ftp_site ) {
        warn
            "Variable 'ftp site' not defined. If there's no ini file, supply it manually.\n\n";
        pod2usage( -verbose => 0 );
    }
    if ( !length $user ) {
        warn
            "Variable 'ftp user' not defined. If there's no ini file, supply it manually.\n\n";
        pod2usage( -verbose => 0 );
    }
    if ( !length $pass ) {
        warn
            "Variable 'ftp pass' not defined. If there's no ini file, supply it manually.\n\n";
        pod2usage( -verbose => 0 );
    }

    # Gather a list of files not matching today's date
    my @combined;
    my @scan_files = grep { !/.*$datetime*/xms } <$scan/*.txt>;
    ### @scan_files
    if (@scan_files) {
        foreach (@scan_files) {
            if ( $_ =~ 'latency' ) {
                copy $_, $staging   or croak $ERRNO;
                move $_, $reporting or croak $ERRNO;
            }
            else {
                move $_, $reporting or croak $ERRNO;
            }
        }
    }
    else {
        print "Scan: No files found or files are dated for today\n"
            or croak $ERRNO;
    }

    # Staging files

    # Gather a list of files not matching today's date
    my @staging_files = grep { !/.*$datetime*/xms } <$staging/*.txt>;

    # Get the base names of the files for easier comparison
    if (@staging_files) {
        get_unique_files(@staging_files);    # returns @combined
        for ( my $i = 0; $i < @combined; $i++ ) {
            $datetime = $combined[$i][2];
            latency2excel();    # Makes decisions based on $datetime
        }
    }
    else {
        print "Staging: No files found or files are dated for today\n"
            or croak $ERRNO;
    }

    # Reporting files

    $datetime = strftime '%m-%d-%Y', localtime;    # Reset $datetime
    my @reporting_files = grep { !/.*$datetime*/xms } <$reporting/*.*>;
    if (@reporting_files) {
        get_unique_files(@reporting_files);        # returns @combined
        for ( my $i = 0; $i < @combined; $i++ ) {
            $datetime = $combined[$i][2];
            $zipdatafilename
                = "$archives/" . $site . '-latency-' . $datetime . '.zip';
            $zipdatafilename_short
                = "$site" . '-latency-' . $datetime . '.zip';
            zip_it("$reporting/*$datetime.*");    # Takes files as an argument
        }
    }
    else {
        print "Reporting: No files found or files are dated for today\n"
            or croak $ERRNO;
    }

    # Archiving files
    # Check whether files in here exist on the FTP, then upload selectively

    # Get files that don't match "dot" or "dot dot", i.e. PWD or its parent
    my @archiving_files = grep { !/^[.][.]?$/xms } <$reporting/*.zip>;
    ### @archiving_files
    if (@archiving_files) {
        ### Connecting to FTP site (cleanup)
        my $ftp = Net::FTP->new("$ftp_site")
            or croak "Cannot connect to $ftp_site: $EVAL_ERROR";
        ### Logging in (cleanup)
        $ftp->login( "$user", "$pass" )
            or croak 'Cannot login ', $ftp->message;
        my @ftp_files = $ftp->ls("/Files/CustomerFiles/LatencyLogs/$site");
        ### @ftp_files
        my %count = ();
        foreach my $element ( @archiving_files, @ftp_files ) {
            $count{$element}++;
        }
        my @difference = grep { $count{$_} == 1 } keys %count;
        ### @difference
        foreach (@difference) {
            archive_it();
        }
    }
    else {
        print "Archiving: No files eligable for upload\n" or croak $ERRNO;
    }

    print "Cleanup complete\n" or croak $ERRNO;
    exit;
}

sub get_unique_files {
    my @base_files;
    my @files = shift;
    foreach (@files) {
        my $unique_base = basename($_);
        push @base_files, $unique_base;
    }

    ### @base_files

    # Get a list of all hosts and dates
    my @hosts;
    my @dates;
    if (@base_files) {
        foreach (@base_files) {

            # Separate host and date via dashes
            my $host  = ( split /-/xms, $_ )[0];
            my $date1 = ( split /-/xms, $_ )[-1];    # Year
            $date1 =~ s/[.]txt//xms;
            my $date2 = ( split /-/xms, $_ )[-2];    # Month
            my $date3 = ( split /-/xms, $_ )[-3];    # Day
            my $date = $date3 . qw{-} . $date2 . qw{-} . $date1;
            push @hosts, $host;
            push @dates, $date;
        }

        # Ensure only unique hosts and dates are preserved
        @hosts = keys %{ { map { $_ => 1 } @hosts } };
        my @types = qw(latency WARN CRIT);
        @dates = keys %{ { map { $_ => 1 } @dates } };
        ### @hosts;
        ### @types;
        ### @dates;

        # Combine hosts, types, and dates into a 3D array
        my @cat = ( [@hosts], [@types], [@dates] );
        ### @cat
        # Get all unique combinations of hosts, types, and dates
        my @combined;
        NestedLoops( \@cat, sub { push @combined, [@_] } );
        ### @combined
        return @combined;
    }
}

__END__

# Documentation

=pod Changelog

=begin comment

Changelog:

0.6
-Adjusted the regex for Linux to include optional whitespace in the time and to look for the IP from the ping in
 the top line instead of later on as in Windows, since that doesn't always appear if packet loss is at 100%
-Discovered that some ping tests finishing quickly and then the check event's
 cleanup being triggered would cause issues due to files being moved, so those
 sections were re-arranged
-Cleaned up the code considerably with the aid of perlcritic and perltidy.
-Re-wrote latency2excel() to facilitate the use of its memory optimisation,
 which should have a fairly tremendous effect on overall efficiency of that process, notably in memory usage.
-Due to the above, introduced the use of the experimental 'switch' feature, which replaces the deprecated
 Switch.pm
-Replaced instances of "unless" with negative if-statements and tidied up a few
 more of the regexes all in the name of readability
-Adjusted the documentation to be more in-line with standards
-Fixed a bug with the Windows cleanup operations which previously omitted the raw latency records from the final zip
-Fixed the faulthy file-locking algorithm, replacing it with the one used in Sys::RunAlone and putting it in an INIT
 block.
-Removed the heartbeat file, as the proper locking algorithm makes it needless.
 Updated this documentation accordingly.

0.5
-Re-wrote the script to be monolithic instead of spread across 3 files
-Changed the name of the main script accordingly from "latencyLaunch.pl" to
 "latencyMonitor.pl"
-Re-wrote paths to be cross-platform ready and more easily edited
    -NOTE: Cross-platform from here on out refers to MSWin32 and linux; can't test on OS X; BSD compatibility
     isn't currently needed
-Implemented cross-platform compatibility via checking $OSNAME and reacting accordingly:
    -Only loads Win32 modules if running on MSWin32
    -Configures paths as appropriate to the OS
    -Creates the folders as appropriate in here alongside of N-Able, in case anything gets broken
    -Handles pinging based on the OS by making two simple decisions based on the OS, using
     the OS' native ping
    -Handles process termination appropriate to the OS
    -Implemented a workaround for Windows when it comes to terminating the child threads and continuing the
     script; Windows has no concept of forking and has draconian locks on files, so a solution was engineered
     to counteract this. This lack of proper forking was the reason the script was intitially split into three
     files.
-Implemented an experimental check to filter relevant items in the WARN files to a CRIT file, based on time of
 day and how close they are together (user-defined; $x occurances in each heartbeat every 15 minutes). If this
 ends up being useful, it'll be moved into the Excel report.
-Implemented three new variables in the INI file to account for this: openHour, closeHour, and critWarn
-Heartbeat file is created on startup as well as on the heartbeat
-Attempted to distribute the file via PAR::Archiver, but due to the fact that it
 wraps everything in BEGIN statements it has proven to be unusable under
 Windows, as wrapping the emulated forks in BEGIN statements doesn't work.
-Converted usage() to use the in-line POD; added a --man option to print the
 entirety of the documentation since perldoc couldn't handle the executables
 produced by PAR::Archiver on its own. -Added a --version command while I was
 at it.
-Renamed the $datetime variable in latency_test to $timestamp to avoid any accidental overloading or overwriting
 of that variable, since it's used to determine the filename as well.
-Fixed a race condition with the various checks and the main process; if the
 checks triggered during the cleanup phase, it would fail due to missing files.
-The time between alarms is now set to 15 minutes unless --debug is used, in
 which case it goes down to 5 seconds. This is to protect against forgetting to
 set it back, which triggered the race condition mentioned above.
-Added a --preserve-time option for use with --debug to counter-act the debug if desired.
-Finally added a cleanup option via --clean; it runs through the folder structure and finishes processing leftover
 data from days that aren't today. For sanity's sake, this is a one-off thing and doesn't launch the main script.
-The --debug parameter now creates a dated DEBUG file in a similar fashion to
 the CRIT/WARN files, which is included in the archive. This file contains all STDERR output, which Smart::Comments
 also uses.

0.4b
-Adjusted the regex in latency_test.pl for grabbing the duration of a ping; it did not account for pings
 that were less than 1ms, which displays as "<1ms" instead of "=1ms" or the like.

0.4a
-Accounts for middle-of-the-night reboots by checking to see if today has data, and if so, looking for
 a differential as usual; if today has no data, it revives yesterday's after doing a check to see if
 it's most likely necessary
-Re-wrote to incorporate Smart::Comments on-demand and be otherwise relatively silent up until the actual
 data-gathering
-Changed the changelog and the documentation to in-line POD

0.4
-Started using version numbers
-Converted the latency2excel call to a subprocedure for consistency, even if it is a one-liner
-Set a timer and checks to terminate the child processes used to gather pings at a specific time
    -That same timer also creates a heartbeat file for use with N-Able
    -Requres Win32::Process and a PID file; includes cleanup in this script
-Introduced a brief sleep to help counter an apparent race-condition while moving the log files around
-Implemented Fcntl to ensure only one copy is running at a time
-Script now continues when re-launched if previous data for today exists
    -Goes by arguments, not a simple scan, so control is left with the user
-Arguments can be supplied from an ini file (C:\SS\Latency\Bin\latencyConfig.ini)
-Arguments can also be supplied from the command line, which overrides the ini

=end comment

=cut

=pod TODO

=begin comment

Nothing at the moment

=end comment

=cut

=pod

=head1 NAME

LatencyMonitor - Parallel latency data collection tool

=head1 USAGE

     perl latencyMonitor.pl [OPTION...] or else defaults to the ini
     -h, --help          Display this help text
         --man           Displays the full embedded manual
         --debug         Enable debug data via Smart::Comments; sets time checks to 5 seconds.
                         Also enables debug logging.
         --preserve-time Keeps the time checks at 15 minutes; does nothing without --debug
         --version       Displays the version and then exits
         --clean         Goes through all folders compiling and archiving any left-behind
                         reports dated before today, then exits
     -s, --site          Name of the site, which also names the output files
     -i, --iterations    Number of times to ping, unless the script runs out of time
     -m, --max-ping      Highest ping to tolerate before triggering a warning
     -f, --ftp           URL of the ftp site to upload data to
     -u, --user          User name for the ftp site
     -p, --pass          Password for the ftp site
     -d, --domains       A list of space-separated URLs or IPs to ping
     -H, --stop-hours    The hour to stop the script at (24-hour format)
     -M, --stop-minute   The minute of the hour to stop the script at (24-hour format)
     -O, --open-hour     The hour that the site opens
     -C, --close-hour    The hour that the site closes
     -W, --crit-warn     How many critical items per interval before an alert is triggered

=head1 DESCRIPTION

Essentially, the script is a wrapper around GNU/Linux or Windows' ping tool,
capturing and organising output. It works well in conjunction with N-Able
monitoring and was built with that in mind, producing currently five items of
output per session, those being a file named with the format
B<$site-latency-$date.txt>, which contains the full output of the command,
B<$site-WARN.txt>, which includes just the warning and failure messages,
B<$site-CRIT.txt>, which includes only entries deemed critical (explained
further below), an Excel spreadsheet summarising the information, and a zip
file, which is uploaded to an FTP site. The date is not included in the warning
or crit files in order to make it easier to monitor with N-Able; it is
recommended that the Log (Appended) type of job be used and that the files be
archived for best results. The script is capable of monitoring multiple sites
within a single primary instance, with forks or threads created as necessary
(depending on the OS). It takes approximately 85,000 pings at one per second to
cover a little over 24 hours; expect drift to occur if the latency is less than
perfect or the host machine under heavy load. After the log file is finished,
or a specified time reached (06:45 by default), it will automatically be moved
to C:\SS\Latency\Staging or ~/.local/share/SS/Latency/Staging as appropriate,
where it will be converted into an Excel spreadsheet via the *latency2excel*
subprocedure. Afterwards, the source files and the spreadsheet will be zipped
and uploaded to the provided FTP site.

The script also has the ability to recover gracefully from stops and overnight
reboots, which should enable the script to intelligently write to the
desired/correct data files on a given day. It is recommended (and safe) to have
N-Able simply launch the script every half hour or so, as the script will
self-destruct if it sees another instance running.

The program, as described previously, outputs to several
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

As of version 0.4a, the script has a safeguard to ensure it only runs once;
this allows N-Able to re-launch it periodically in case it stops for whatever
reason, or to start it explicitly after a planned reboot. Along those same
lines, it also has a feature wherein if, when it runs, it detects a
www.google.com latency log dated for that same day, it will count the number of
lines in it and then adjust its run to ensure that the google log has 85000
entries, which further facilitates the usage of planned reboots.

Should --debug be used, additional data will be printed to STDERR but not the
aforementioned files; instead, it will go to a dated debug log in the Archives
folder, where it will be scooped up later during the archival process.

=head1 REQUIRED ARGUMENTS

All obvious arguments are required; if not provided on the command line, they
can be provided via an INI file.

=head1 OPTIONS

The only behaviour-modifying options at present are --preserve-time (when used
in conjunction with --debug) and --clean.

=head1 DIAGNOSTICS

Should things be acting up, double-check that all the required modules are
present; their dpkg names and cpan names are all listed. Failing that, remember
to enable --debug mode and look at the log it generates in the Archives folder.

=head1 EXIT STATUS

0 on success; any other value indicates failure. A value of 1 given immediately
most likely means that the script is already running, and a line of text should
indicate as such.

=head1 CONFIGURATION

The program will attempt to use a configuration file
(C:\SS\Latency\Bin\latencyConfig.ini or
~/.local/share/SS/Latency/Bin/latencyConfig.ini as appropriate), structured as
follows:

     site=siteName
     maxiterations=85000
     maxping=200
     ftpSite=ftp.site.net
     user=ftpUser
     pass=password
     host=8.8.8.8, www.startpage.com
     stopHour=06
     stopMinute=45
     openHour=8
     closeHour=17
     critWarn=7

Note that the list of hosts is separated by both a comma and whitespace here,
in contrast to the command-line syntax. Parameters passed to the command line
take precedence over parameters defined in the INI file, allowing for local
exceptions as needed.

All parameters have some basic sanity checking to help
prevent input errors, and if any are found the program will print a
helpful reminder.

=head1 SETTING UP N-ABLE

In order to use the script with N-Able, it needs to be set up as a scheduled
task consisting of an Automation Policy configured to deploy the script; it is
also recommended to create other policies in order to install/update the script
and the INI files. Scripts will be stored on the company FTP site in their own
directory, currently in */Dropbox/Automation/Latency*.

As mentioned previously, a default run takes approximately 24 hours by default,
though it will stop at the nearest instance of whatever stop time is defined.
After the runs are complete, the script will automatically copy the main log to
a Staging folder, where it can be further processed by the *latency2excel*
subprocedure. Afterwards, files will be moved to the Reporting folder where it
will be archived and uploaded.

While the script is deployed, it can be monitored by N-Able. To do so, make use
of the appended log monitor, which is able to look at the WARN or, ideally,
CRIT file every so often and remember where it left off. When this service sees
the appropraite regex (define one as WARNING and one as FAILURE) it can react
as needed, ideally sending a notification to the support account and creating
an appropriate ticket. These services and profiles are all bundled under
"Latency" under the SmartSystems account in N-Able.

For reference, here is the intended file tree:

    SS
    L-- Latency
        |-- Bin
            L-- latencyMonitor.exe
            L-- latencyConfig.ini
        |-- Archives
        |   L-- DEBUG.txt
        |-- Scan
        |   L-- LatencyFile.txt
        |   L-- WARN.txt
        |   L-- CRIT.txt
        L-- Temp
            |-- Reporting
            L-- Staging

=head1 DEPENDENCIES

This script depends on a number of CPAN modules:

Algorithm::Loops
Archive::Zip
Config::Simple
Date::Manip
Excel::Writer::XLSX
Net::FTP
PerlIO::Util
Smart::Comments

Additionally, if running on Windows, Win32::Autoglob is required. If running
under GNU/Linux, this dependency will be ignored.

=head1 INCOMPATIBILITIES

None known at present, though behaviour of "switch" may change in the future.

=head1 BUGS AND LIMITATIONS

No (confirmed) bugs known at the moment. However, forking as a concept doesn't
exist under Windows, and the performance, notably on start-up, won't be quite
as good as on Linux, as Strawberry Perl can't integrate quite as closely on
Windows.

=head1 AUTHOR

Cory Sadowski <cory@smartsystemsaz.com>

=head1 REPORTING BUGS

Report any bugs found to either the author or to the SmartSystems support
account, <support@smartsystemsaz.com>

=head1 LICENSE AND COPYRIGHT

(c) 2015 SmartSystems, Inc. All rights reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
