package Test2::Harness::UI::Util;
use strict;
use warnings;

use Carp qw/croak/;

use File::ShareDir();

use Importer Importer => 'import';

our @EXPORT = qw/share_dir/;

sub share_dir {
    my ($file) = @_;

    return File::ShareDir::dist_file('Test2-Harness-UI' => $file)
        unless $ENV{T2_HARNESS_UI_ENV} eq 'dev';

    my $path = "share/$file";
    croak "Could not find '$file'" unless -e $path;

    return $path;
}

1;
