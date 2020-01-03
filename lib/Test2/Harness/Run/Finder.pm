package Test2::Harness::Run::Finder;
use strict;
use warnings;

our $VERSION = '1.000000';

use Test2::Harness::Util qw/clean_path/;
use List::Util qw/first/;
use Cwd qw/getcwd/;

use Test2::Harness::TestFile;
use File::Spec;

sub find_files {
    my $class = shift;
    my ($run, $plugins, $settings) = @_;

    return $class->_find_project_files($run, $plugins, $settings) if $run->multi_project;
    return $class->_find_files($run, $plugins, $settings, $run->search);
}

sub _find_project_files {
    my $class = shift;
    my ($run, $plugins, $settings) = @_;

    my $search = $run->search // [];

    die "multi-project search must be a single directory, or the current directory" if @$search > 1;
    my ($pdir) = @$search;
    my $dir = clean_path(getcwd());

    my $out = [];
    my $ok = eval {
        chdir($pdir) if defined $pdir;
        my $ret = clean_path(getcwd());

        opendir(my $dh, '.') or die "Could not open project dir: $!";
        for my $subdir (readdir($dh)) {
            chdir($ret);

            next if $subdir =~ m/^\./;
            my $path = clean_path(File::Spec->catdir($ret, $subdir));
            next unless -d $path;

            chdir($path) or die "Could not chdir to $path: $!\n";

            for my $item (@{$class->_find_files($run, $plugins, $settings, [])}) {
                push @{$item->queue_args} => ('ch_dir' => $path);
                push @$out => $item;
            }
        }

        chdir($ret);
        1;
    };
    my $err = $@;

    chdir($dir);
    die $err unless $ok;

    return $out;
}

sub _find_files {
    my $class = shift;
    my ($run, $plugins, $settings, $input) = @_;

    $input   //= [];
    $plugins //= [];

    my $default_search = [@{$run->default_search}];
    push @$default_search => @{$run->default_at_search} if $run->author_testing;

    $_->munge_search($run, $input, $default_search, $settings) for @$plugins;

    my $search = @$input ? $input : $default_search;

    die "No tests to run, search is empty\n" unless @$search;

    my (%seen, @tests, @dirs);
    for my $path (@$search) {
        push @dirs => $path and next if -d $path;

        unless(-f $path) {
            die "'$path' is not a valid file or directory.\n" if @$input;
            next;
        }

        $path = clean_path($path);
        $seen{$path}++;

        my $test;
        unless (first { $test = $_->claim_file($path, $settings) } @$plugins) {
            $test = Test2::Harness::TestFile->new(file => $path);
            next unless @$input || $class->_include_file($run, $test);
        }

        push @tests => $test;
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';

                    my $file = clean_path($File::Find::name);

                    return if $seen{$file}++;
                    return unless -f $file;

                    my $test;
                    unless(first { $test = $_->claim_file($file, $settings) } @$plugins) {
                        for my $ext (@{$run->extensions}) {
                            next unless m/\.\Q$ext\E$/;
                            $test = Test2::Harness::TestFile->new(file => $file);
                            last;
                        }
                    }

                    return unless $test && $class->_include_file($run, $test);
                    push @tests => $test;
                },
            },
            @dirs
        );
    }

    $_->munge_files($run, \@tests, $settings) for @$plugins;

    return [ sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @tests ];
}

sub _include_file {
    my $class = shift;
    my ($run, $test) = @_;

    return 0 unless $test->check_feature(run => 1);

    my $full = $test->file;
    my $rel  = $test->relative;

    return 0 if $run->exclude_files->{$full};
    return 0 if $run->exclude_files->{$rel};
    return 0 if first { $rel =~ m/$_/ } @{$run->exclude_patterns};

    my $durations = $run->duration_data;
    $test->set_duration($durations->{$rel}) if $durations->{$rel};

    return 0 if $run->no_long   && $test->check_duration eq 'long';
    return 0 if $run->only_long && $test->check_duration ne 'long';

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run::Finder - Library that searches for test files

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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
