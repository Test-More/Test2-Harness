package Test2::Harness::UI::Util::DateTimeFormat;
use strict;
use warnings;

use Carp qw/confess/;
use Importer Importer => 'import';

our @EXPORT = qw/DTF/;

my $DTF;
sub DTF {
    return $DTF if $DTF;

    confess "You must first load a Test2::Harness::UI::Schema::NAME module"
        unless $Test2::Harness::UI::Schema::LOADED;

    if ($Test2::Harness::UI::Schema::LOADED =~ m/postgresql/i) {
        require DateTime::Format::Pg;
        return $DTF = 'DateTime::Format::Pg';
    }

    if ($Test2::Harness::UI::Schema::LOADED =~ m/mysql/i) {
        require DateTime::Format::MySQL;
        return $DTF = 'DateTime::Format::MySQL';
    }

    die "Not sure what DateTime::Formatter to use";
}

1;
