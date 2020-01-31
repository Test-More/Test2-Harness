package Test2::Harness::Finder;
use strict;
use warnings;

our $VERSION = '1.000000';

use Test2::Harness::Util qw/clean_path/;
use List::Util qw/first/;
use Cwd qw/getcwd/;

use Test2::Harness::TestFile;
use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <default_search <default_at_search

    <durations <maybe_durations +duration_data

    <exclude_files  <exclude_patterns

    <no_long <only_long

    <search <extensions

    <multi_project
};

sub munge_settings {}

sub init {
    my $self = shift;

    $self->{+EXCLUDE_FILES} = { map {( $_ => 1 )} @{$self->{+EXCLUDE_FILES}} } if ref($self->{+EXCLUDE_FILES}) eq 'ARRAY';
}

sub duration_data {
    my $self = shift;
    return $self->{+DURATION_DATA} //= $self->pull_durations() // {};
}

sub pull_durations {
    my $self = shift;

    my $primary  = delete $self->{+MAYBE_DURATIONS} || [];
    my $fallback = delete $self->{+DURATIONS};

    for my $path (@$primary) {
        local $@;
        my $durations = eval { $self->_pull_durations($path) } or print "Could not fetch optional durations '$path', ignoring...\n";
        next unless $durations;

        print "Found durations: $path\n";
        return $self->{+DURATION_DATA} = $durations;
    }

    return $self->{+DURATION_DATA} = $self->_pull_durations($fallback)
        if $fallback;
}

sub _pull_durations {
    my $self = shift;
    my ($in) = @_;

    if (my $type = ref($in)) {
        return $self->{+DURATIONS} = $in if $type eq 'HASH';
    }
    elsif ($in =~ m{^https?://}) {
        require HTTP::Tiny;
        my $ht = HTTP::Tiny->new();
        my $res = $ht->get($in, {headers => {'Content-Type' => 'application/json'}});

        die "Could not query durations from '$in'\n$res->{status}: $res->{reason}\n$res->{content}"
            unless $res->{success};

        return $self->{+DURATIONS} = decode_json($res->{content});
    }
    elsif(-f $in) {
        require Test2::Harness::Util::File::JSON;
        my $file = Test2::Harness::Util::File::JSON->new(name => $in);
        return $self->{+DURATIONS} = $file->read();
    }

    die "Invalid duration specification: $in";
}

sub find_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    return $self->find_multi_project_files($plugins, $settings) if $self->multi_project;
    return $self->find_project_files($plugins, $settings, $self->search);
}

sub find_multi_project_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $search = $self->search // [];

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

            for my $item (@{$self->find_project_files($plugins, $settings, [])}) {
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

sub find_project_files {
    my $self = shift;
    my ($plugins, $settings, $input) = @_;

    $input   //= [];
    $plugins //= [];

    my $default_search = [@{$self->default_search}];
    push @$default_search => @{$self->default_at_search} if $settings->check_prefix('run') && $settings->run->author_testing;

    $_->munge_search($input, $default_search, $settings) for @$plugins;

    my $search = @$input ? $input : $default_search;

    die "No tests to run, search is empty\n" unless @$search;

    my (%seen, @tests, @dirs);
    for my $path (@$search) {
        push @dirs => $path and next if -d $path;

        unless(-f $path) {
            die "'$path' is not a valid file or directory.\n" if @$input;
            next;
        }

        $path = clean_path($path, 0);
        $seen{$path}++;

        my $test;
        unless (first { $test = $_->claim_file($path, $settings) } @$plugins) {
            $test = Test2::Harness::TestFile->new(file => $path);
            next unless @$input || $self->include_file($test);
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

                    my $file = clean_path($File::Find::name, 0);

                    return if $seen{$file}++;
                    return unless -f $file;

                    my $test;
                    unless(first { $test = $_->claim_file($file, $settings) } @$plugins) {
                        for my $ext (@{$self->extensions}) {
                            next unless m/\.\Q$ext\E$/;
                            $test = Test2::Harness::TestFile->new(file => $file);
                            last;
                        }
                    }

                    return unless $test && $self->include_file($test);
                    push @tests => $test;
                },
            },
            @dirs
        );
    }

    $_->munge_files(\@tests, $settings) for @$plugins;

    return [ sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @tests ];
}

sub include_file {
    my $self = shift;
    my ($test) = @_;

    return 0 unless $test->check_feature(run => 1);

    my $full = $test->file;
    my $rel  = $test->relative;

    return 0 if $self->exclude_files->{$full};
    return 0 if $self->exclude_files->{$rel};
    return 0 if first { $rel =~ m/$_/ } @{$self->exclude_patterns};

    my $durations = $self->duration_data;
    $test->set_duration($durations->{$rel}) if $durations->{$rel};

    return 0 if $self->no_long   && $test->check_duration eq 'long';
    return 0 if $self->only_long && $test->check_duration ne 'long';

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Finder - Library that searches for test files

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
