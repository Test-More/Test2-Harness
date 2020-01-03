package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '1.000000';

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/write_file_atomic mod2file/;

use Test2::Harness::Util::Queue;

use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <run_id

    <finder
    <default_search <default_at_search

    <durations <maybe_durations +duration_data

    <env_vars <author_testing <unsafe_inc

    <links

    <event_uuids
    <use_stream
    <mem_usage

    <exclude_files  <exclude_patterns

    <no_long <only_long

    <input <input_file

    <search <test_args <extensions

    <load <load_import

    <fields <meta

    <retry <retry_isolated

    <multi_project
};

sub init {
    my $self = shift;

    croak "run_id is required"
        unless $self->{+RUN_ID};

    $self->{+EXCLUDE_FILES} = { map {( $_ => 1 )} @{$self->{+EXCLUDE_FILES}} } if ref($self->{+EXCLUDE_FILES}) eq 'ARRAY';
}

sub run_dir {
    my $self = shift;
    my ($workdir) = @_;
    return File::Spec->catfile($workdir, $self->{+RUN_ID});
}

sub TO_JSON { +{ %{$_[0]} } }

sub queue_item {
    my $self = shift;
    my ($plugins) = @_;

    croak "a plugins arrayref is required" unless $plugins;

    my $out = {%$self};

    my $meta = $out->{+META} //= {};
    my $fields = $out->{+FIELDS} //= [];
    for my $p (@$plugins) {
        $p->inject_run_data(meta => $meta, fields => $fields, run => $self);
    }

    return $out;
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

    my $finder = $self->{+FINDER};
    require(mod2file($finder));
    return $finder->find_files($self, @_);
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run - Representation of a set of tests to run, and their
options.

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
