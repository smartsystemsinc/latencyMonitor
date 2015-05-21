#!/usr/bin/env perl

use strict;
use warnings;

system("cpan App::cpanminus");
#system("cpanm Archive::Zip"); # Pulled in by Excel::Writer::XSLX
system("cpanm Config::Simple");
#system("cpanm Date::Manip");
system("cpanm Excel::Writer::XLSX");
system("cpanm Net::FTP");
system("cpanm Win32::Autoglob");
