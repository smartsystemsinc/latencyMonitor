#!/usr/bin/env perl

use strict;
use warnings;
use English qw(-no_match_vars);

our $VERSION = '0.5';

system 'cpan App::cpanminus';
system 'cpanm Algorithm::Loops';
system 'cpanm Config::Simple';
system 'cpanm Date::Manip';
system 'cpanm Excel::Writer::XLSX';
system 'cpanm Net::FTP';
system 'cpanm --notest PerlIO::Util';
system 'cpanm Smart::Comments';
system 'cpanm Email::Sender::Simple';
system 'cpanm Email::Simple';
system 'cpanm MIME::Base64';
system 'cpanm Authen::SASL';

if ( $OSNAME eq 'MSWin32' ) {
    system 'cpanm Win32::Autoglob';
}
