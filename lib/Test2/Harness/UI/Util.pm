package Test2::Harness::UI::Util;
use strict;
use warnings;

use Carp qw/croak/;

use File::ShareDir();

use Importer Importer => 'import';

our @EXPORT = qw/share_dir share_file/;

sub share_file {
    my ($file) = @_;

    return File::ShareDir::dist_file('Test2-Harness-UI' => $file)
        unless 'dev' eq ($ENV{T2_HARNESS_UI_ENV} || '');

    my $path = "share/$file";
    croak "Could not find '$file'" unless -e $path;

    return $path;
}

sub share_dir {
    my ($dir) = @_;

    my $path;

    if ('dev' eq ($ENV{T2_HARNESS_UI_ENV} || '')) {
        $path = "share/$dir";
    }
    else {
        my $root = File::ShareDir::dist_dir('Test2-Harness-UI');
        $path = "$root/$dir";
    }

    croak "Could not find '$dir'" unless -d $path;

    return $path;
}


1;
