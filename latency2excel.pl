#!/usr/bin/env perl

# Force me to write this properly
use strict;
use warnings;
use POSIX qw(strftime);
use File::Copy; # Built-in
use Win32::Autoglob; # ccpan App::cpanminus && [sudo] cpanm Win32::Autoglob
use Excel::Writer::XLSX; # dpkg libexcel-writer-xslx-perl || cpan App::cpanminus && [sudo] cpanm Excel::Writer::XLSX (Case-sensitive)

if (scalar (@ARGV) < 1) {
    die("Usage: latency2excel.pl <workbook name> <files>\n");
}

# Get files
my $site = $ARGV[0];
my @files = @ARGV[1..$#ARGV];

# Create a new Excel workbook
my $datetime = strftime "%m-%d-%Y", localtime;
my $workbook = Excel::Writer::XLSX->new("C:\\SS\\Latency\\Temp\\Staging\\$site-$datetime.xlsx");

foreach my $file (@files) {
    open (my $TXTFILE, "<", "$file") or die("File not accessible\n");

# Add a worksheet
    my @protosheetname = split('-', $file);
    my $sheetname = $protosheetname[0];
    @protosheetname = split(/\\/, $sheetname);
    $sheetname = $protosheetname[-1];
    my $worksheet = $workbook->add_worksheet($sheetname);
    our $row = 0;
    while (<$TXTFILE>) {
        chomp;
        # Get variables
        my $col = 0;
        my @values = split();
        my $status = $values[0];
        my $date = $values[1];
        my $time = $values[2];
        my $url = $values[3];
        my $ip = $values[4];
        my $latency = $values[5];
        $latency =~ s/ms//;
        # Note that $maxiterations isn't passed and is assumed to be 85000

        # Write data
        $worksheet->write($row, $col, $status);
        $col++;
        $worksheet->write($row, $col, $date);
        $col++;
        $worksheet->write($row, $col, $time);
        $col++;
        $worksheet->write($row, $col, $url);
        $col++;
        $worksheet->write($row, $col, $ip);
        $col++;
        $worksheet->write($row, $col, $latency);
        $row++;
    }
    close $TXTFILE;

    # Define formatting for labels and conditions
    my $blue = "#83CAFF";
    my $green = "#579D1C";
    my $yellow = "#FFD320";
    my $red = "#C5000B";
    my $fInfo = $workbook->add_format(bold=>1, underline=>1, size=>16, align=>'center');
    my $fLabel = $workbook->add_format(bold=>1, size=>14, bg_color=>"$blue");
    my $fLabelThresh = $workbook->add_format(bold=>1, size=>11, bg_color=>"$blue");
    my $fLabelWarn = $workbook->add_format(bold=>1, size=>14, bg_color=>"$blue");
    my $fLabelFail = $workbook->add_format(bold=>1, size=>14, bg_color=>"$blue");
    my $fBad = $workbook->add_format(bg_color=>"$red");
    my $fWarn = $workbook->add_format(bg_color=>"$yellow");
    my $fOK = $workbook->add_format(bg_color=>"$green");
    my $fLatency = $workbook->add_format(bg_color=>"$blue", num_format=>'#,##0');
    my $fPercent = $workbook->add_format(num_format=>'0.0%', bg_color=>"$yellow"); # Color will be modified via conditional formatting

# Format I3 as "Bad" if Count is less than 85,000, else as "OK"
    $worksheet->conditional_formatting('I3',
        {
            type => 'cell',
            criteria => '<',
            value => 85000,
            format => $fBad,
        }
    );
    $worksheet->conditional_formatting('I3',
        {
            type => 'cell',
            criteria => '=',
            value => 85000,
            format => $fOK,
        }
    );
    # Format I6 as "bad" if average latency >= 200
    $worksheet->conditional_formatting('I6',
        {
            type => 'cell',
            criteria => '>=',
            value => 200,
            format => $fBad,
        }
    );
    # Otherwise format it as "OK"
    $worksheet->conditional_formatting('I6',
        {
            type => 'cell',
            criteria => '<',
            value => 200,
            format => $fOK,
        }
    );

    # Format I7 as "bad" if % high latency >=10
    $worksheet->conditional_formatting('I7',
        {
            type => 'cell',
            criteria => '>=',
            value => 0.10,
            format => $fBad,
        }
    );
    # Otherwise format it as "OK"
    $worksheet->conditional_formatting('I7',
        {
            type => 'cell',
            criteria => '<',
            value => 0.10,
            format => $fOK,
        }
    );

# Format I9 as "bad" if % high latency (500+) >= 50
    $worksheet->conditional_formatting('I9',
        {
            type => 'cell',
            criteria => '>=',
            value => 0.50,
            format => $fBad,
        }
    );
    # Otherwise format it as "OK"
    $worksheet->conditional_formatting('I9',
        {
            type => 'cell',
            criteria => '<',
            value => 0.50,
            format => $fOK,
        }
    );

    # Format I10 as "bad" if % of packets dropped >= 10
    $worksheet->conditional_formatting('I10',
        {
            type => 'cell',
            criteria => '>=',
            value => 0.10,
            format => $fBad,
        }
    );
    # Otherwise format it as "OK"
    $worksheet->conditional_formatting('I10',
        {
            type => 'cell',
            criteria => '<',
            value => 0.10,
            format => $fOK,
        }
    );

    # Create statistical formulae
    $worksheet->write('H1', 'Information', $fInfo);
    $worksheet->write('J1', 'Thresholds', $fInfo);
    $worksheet->write('H3', 'Count', $fLabel);
    $worksheet->write_formula('I3', '=COUNTA($A:$A)');
    $worksheet->write('J3', '<85,000 packets', $fLabelThresh);

    $worksheet->write('H4', 'Warnings', $fLabelWarn);
    $worksheet->write_formula('I4', '=COUNTIF($A:$A,"WARNING:")', $fWarn);
    $worksheet->write('J4', '>200ms', $fLabelThresh);
    $worksheet->write('H5', 'Failures', $fLabelFail);
    $worksheet->write_formula('I5', '=COUNTIF($A:$A,"FAILURE:")', $fBad);
    $worksheet->write('J5', '', $fLabelThresh);

    $worksheet->write('H6', 'Average Latency', $fLabel);
    $worksheet->write_formula('I6', '=SUM($F:$F)/(I3)', $fLatency);
    $worksheet->write('J6', '>=200', $fLabelThresh);

    $worksheet->write('H7', '% high latency', $fLabel);
    $worksheet->write_formula('I7', '=(I4/(I3))', $fPercent);
    $worksheet->write('J7', '>=10%', $fLabelThresh);
    $worksheet->write('H8', '% high latency (200-499)', $fLabel);
    $worksheet->write_comment('H8', 'Relative to % high latency, not the entire dataset');
    $worksheet->write_formula('I8', '=IF(I4=0,0,(COUNTIFS($F:$F,">199",$F:$F,"<500"))/I4)', $fPercent);
    $worksheet->write('J8', '', $fLabelThresh);
    $worksheet->write('H9', '% high latency (500)', $fLabel);
    $worksheet->write_comment('H9', 'Relative to % high latency, not the entire dataset');
    $worksheet->write_formula('I9', '=IF(I4=0,0,(COUNTIF($F:$F,">=500")/I4))', $fPercent);
    $worksheet->write('J9', '>=50%', $fLabelThresh);

    $worksheet->write('H10', '% of packets dropped', $fLabel);
    $worksheet->write_formula('I10', '=(I5/(I3))', $fPercent);
    $worksheet->write('J10', '>=10%', $fLabelThresh);

    # Set colum widths, hide data columns A-G
    $worksheet->set_column('A:C', 10, undef, 1);
    $worksheet->set_column('D:D', 20, undef, 1);
    $worksheet->set_column('E:E', 15, undef, 1);
    $worksheet->set_column('F:F', 5, undef, 1);
    $worksheet->set_column('G:G', 5, undef, 1);
    $worksheet->set_column('H:H', 29);
    $worksheet->set_column('J:J', 15);

}
$workbook->close();
# Clean up the files used to generate the report and then move it for archivng
unlink @files;
move "C:\\SS\\Latency\\Temp\\Staging\\$site-$datetime.xlsx", "C:\\SS\\Latency\\Temp\\Reporting" or die $!; # Only move today's files
