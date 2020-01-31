package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '1.000000';

use File::Spec;

use Test2::Harness::Util qw/clean_path/;

use Cwd qw/realpath/;
use Importer Importer => 'import';
use Config qw/%Config/;
use Carp qw/croak/;

our @EXPORT_OK = qw{
    find_pfile
    find_in_updir
    is_generated_test_pl
    fit_to_width
    isolate_stdout
    find_yath
};

sub find_yath {
    return $App::Yath::Script::SCRIPT if defined $App::Yath::Script::SCRIPT;

    if (-d 'scripts') {
        my $script = File::Spec->catfile('scripts', 'yath');
        return $App::Yath::Script::SCRIPT = clean_path($script) if -e $script && -x $script;
    }

    my @keys = qw{
        bin binexp initialinstalllocation installbin installscript
        installsitebin installsitescript installusrbinperl installvendorbin
        scriptdir scriptdirexp sitebin sitebinexp sitescript sitescriptexp
        vendorbin vendorbinexp
    };

    my %seen;
    for my $path (@Config{@keys}) {
        next unless $path;
        next if $seen{$path}++;

        my $script = File::Spec->catfile($path, 'yath');
        next unless -f $script && -x $script;

        $App::Yath::Script::SCRIPT = $script = clean_path($script);
        return $script;
    }

    die "Could not find yath in Config paths";
}

sub isolate_stdout {
    # Make $fh point at STDOUT, it is our primary output
    open(my $fh, '>&', STDOUT) or die "Could not clone STDOUT: $!";
    select $fh;
    $| = 1;

    # re-open STDOUT redirected to STDERR
    open(STDOUT, '>&', STDERR) or die "Could not redirect STDOUT to STDERR: $!";
    select STDOUT;
    $| = 1;

    # Yes, we want to keep STDERR selected
    select STDERR;
    $| = 1;

    return $fh;
}

sub is_generated_test_pl {
    my ($file) = @_;

    open(my $fh, '<', $file) or die "Could not open '$file': $!";

    my $count = 0;
    while (my $line = <$fh>) {
        last if $count++ > 5;
        next unless $line =~ m/^# THIS IS A GENERATED YATH RUNNER TEST$/;
        return 1;
    }

    return 0;
}


sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -f $check;
    }

    return;
}

sub find_pfile {
    my ($settings, %params) = @_;

    croak "Settings is a required argument" unless $settings;

    # First do the entire search without vivify
    if ($params{vivify}) {
        my $found = find_pfile($settings, %params, vivify => 0);
        return $found if $found;
    }

    my $yath = $settings->yath;

    if (my $pfile = $yath->persist_file) {
        return $pfile if -f $pfile || $params{vivify};

        return; # Specified, but not found and no vivify
    }

    my $project = $yath->project;
    my $name = $project ? "$project-yath-persist.json" : "yath-persist.json";
    my $set_dir = $yath->persist_dir // $ENV{YATH_PERSISTENCE_DIR};
    my $dir = $set_dir // $ENV{TMPDIR} // $ENV{TEMPDIR} // File::Spec->tmpdir;

    # If a dir was specified, or if the current dir is not writable then we must use $dir/$name
    if ($project || $set_dir || !-w '.') {
        my $pfile = clean_path(File::Spec->catfile($dir, $name));
        return $pfile if -f $pfile || $params{vivify};

        return; # Not found, no vivify
    }

    # Fall back to using the current dir (which must be writable)
    $name = ".yath-persist.json";
    my $pfile = find_in_updir($name);
    return $pfile if $pfile && -f $pfile;

    # Creating it here!
    return $name if $params{vivify};

    # Nope, nothing.
    return;
}

sub fit_to_width {
    my ($width, $join, $text) = @_;

    my @parts = ref($text) ? @$text : split /\s+/, $text;

    my @out;

    my $line = "";
    for my $part (@parts) {
        my $new = $line ? "$line$join$part" : $part;

        if ($line && length($new) > $width) {
            push @out => $line;
            $line = $part;
        }
        else {
            $line = $new;
        }
    }
    push @out => $line if $line;

    return join "\n" => @out;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Util - Common utils for yath.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
