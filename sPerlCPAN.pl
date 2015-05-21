#!/usr/bin/env perl

use strict;
use warnings;

system("cpan App::cpanminus");
system("cpan Algorithm::Loops");
system("cpanm Config::Simple");
system("cpanm Date::Manip");
system("cpanm Excel::Writer::XLSX");
system("cpanm Net::FTP");
system("cpanm --notest PerlIO::Util");
system("cpanm Smart::Comments");
if ($^O eq "MSWin32") {
    system("cpanm Win32::Autoglob");
}
