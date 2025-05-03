package Test2::Harness::TestSettings;
use strict;
use warnings;

our $VERSION = '2.000005';

use Scalar::Util qw/blessed/;
use Test2::Util qw/IS_WIN32/;
use Test2::Harness::Util qw/clean_path/;

use File::Spec;

my $DEFAULT_COVER_ARGS = '-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
sub default_cover_args { $DEFAULT_COVER_ARGS }

my (@BOOL, @SCALAR, @HASH, @ARRAY);

BEGIN {
    @BOOL   = qw{ use_preload use_stream use_fork use_timeout tlib lib blib unsafe_inc retry_isolated allow_retry event_uuids mem_usage};
    @SCALAR = qw{ event_timeout post_exit_timeout cover retry input input_file ch_dir};
    @HASH   = qw{ env_vars load_import };
    @ARRAY  = qw{ switches load includes args };
}

my %PROPOGATE_FALSE = (
    use_preload => 1,
    use_fork    => 1,
    allow_retry => 1,
);

my %DEFAULTS = (
    allow_retry       => 1,
    args              => [],
    blib              => 1,
    cover             => undef,
    env_vars          => {},
    event_timeout     => 60,
    event_uuids       => 1,
    includes          => [],
    input             => undef,
    input_file        => undef,
    lib               => 1,
    load              => [],
    load_import       => {},
    mem_usage         => 1,
    post_exit_timeout => 15,
    retry             => 0,
    retry_isolated    => 0,
    switches          => [],
    tlib              => 0,
    unsafe_inc        => 0,
    use_fork          => IS_WIN32 ? 0 : 1,
    use_preload       => IS_WIN32 ? 0 : 1,
    use_stream        => 1,
    use_timeout       => 1,
);

use Test2::Harness::Util::HashBase('<cleared', map { "+$_" } @ARRAY, @HASH, @SCALAR, @BOOL);

sub init { $_[0]->purge }

sub purge {
    my $self = shift;
    delete $self->{$_} for grep { !defined($self->{$_}) } keys %$self;
}

sub merge {
    my $class = ref($_[0]) || shift;

    my $new = $class->new;

    for my $item (@_) {
        my $cleared = $item->{+CLEARED} // {};
        delete $new->{$_} for keys %$cleared;

        for my $field (@BOOL, @SCALAR) {
            next unless defined $item->{$field};

            if ($PROPOGATE_FALSE{$field} && defined($item->{$field})) {
                if (my $ref = ref($item->{$field})) {
                    next if $ref eq 'ARRAY' && !@{$ref};
                    next if $ref eq 'HASH'  && !keys(%{$ref});
                }
            }

            $new->{$field} = $item->{$field};
        }

        for my $field (@HASH) {
            next unless $new->{$field} || $item->{$field};
            $new->{$field} = {%{$new->{$field} // {}}, %{$item->{$field} // {}}};
        }

        for my $field (@ARRAY) {
            next unless $new->{$field} || $item->{$field};
            my %seen;
            $new->{$field} = [grep { !$seen{$_}++ } @{$new->{$field} // []}, @{$item->{$field} // []}];
        }
    }

    $new->purge();

    return $new;
}

sub includes {
    my $self = shift;

    my $out = [@{$self->{+INCLUDES} // $DEFAULTS{+INCLUDES}}];

    push @$out => File::Spec->catdir('t', 'lib') if $self->tlib;

    push @$out => 'lib' if $self->lib;

    if ($self->blib) {
        push @$out => (
            File::Spec->catdir('blib', 'lib'),
            File::Spec->catdir('blib', 'arch'),
        );
    }

    push @$out => split /;/, $ENV{T2_HARNESS_INCLUDES} if $ENV{T2_HARNESS_INCLUDES};
    push @$out => '.' if $self->{+UNSAFE_INC};

    if (my $ch_dir = $self->{+CH_DIR}) {
        push @$out => map { File::Spec->catdir($ch_dir, $_) } @$out;
    }

    my %seen;
    return [grep { !$seen{$_}++ } @$out];
}

sub cover {
    my $self = shift;
    my $val  = $self->{+COVER} or return;

    return $self->default_cover_args if $val eq '1';
    return $val;
}

sub use_preload {
    my $self = shift;
    return 0 if IS_WIN32;
    return 0 unless $self->{+USE_PRELOAD};
    return 0 if $self->cover;
    return $DEFAULTS{+USE_PRELOAD};
}

sub use_fork {
    my $self = shift;
    return 0 if IS_WIN32;
    return 0 unless $self->{+USE_FORK};
    return 0 if $self->cover;
    return $DEFAULTS{+USE_FORK};
}

sub load_import {
    my $self = shift;
    my $hash = {%{$self->{+LOAD_IMPORT} // $DEFAULTS{+LOAD_IMPORT}}};

    if (my $cover = $self->cover) {
        push @{$hash->{'@'} //= []} => 'Devel::Cover';
        $hash->{'Devel::Cover'} = [split(/,/, $cover)];
    }

    if ($self->event_uuids) {
        unshift @{$hash->{'@'} //= []} => 'Test2::Plugin::UUID';
        $hash->{'Test2::Plugin::UUID'} = [];
    }

    if ($self->mem_usage) {
        unshift @{$hash->{'@'} //= []} => 'Test2::Plugin::MemUsage';
        $hash->{'Test2::Plugin::MemUsage'} = [];
    }

    return $hash;
}

sub load {
    my $self = shift;
    my $array = [@{$self->{+LOAD} // $DEFAULTS{+LOAD}}];

    my %seen;
    return [ grep { !$seen{$_}++ } @$array ];
}

*set_env_var = \&set_env_vars;
sub set_env_vars {
    my $self = shift;
    my %params = @_;

    $self->{+ENV_VARS} //= { %{$DEFAULTS{+ENV_VARS}} };

    for my $key (keys %params) {
        $self->{+ENV_VARS}->{$key} = $params{$key};
    }
}

sub env_vars {
    my $self = shift;

    my $hash = { %{$self->{+ENV_VARS} //= { %{$DEFAULTS{+ENV_VARS}} }} };

    if (my $cover = $self->cover) {
        $hash->{T2_NO_FORK} = 1;
        $ENV{T2_NO_FORK} = 1;
    }

    $hash->{T2_FORMATTER} = 'Stream' if $self->use_stream;

    return $hash;
}

sub event_timeout {
    my $self = shift;
    return $self->{+EVENT_TIMEOUT} if exists $self->{+EVENT_TIMEOUT};
    return $self->{+EVENT_TIMEOUT} = undef unless $self->use_timeout;
    return $self->{+EVENT_TIMEOUT} = $DEFAULTS{+EVENT_TIMEOUT};
}

sub post_exit_timeout {
    my $self = shift;
    return $self->{+POST_EXIT_TIMEOUT} if exists $self->{+POST_EXIT_TIMEOUT};
    return $self->{+POST_EXIT_TIMEOUT} = undef unless $self->use_timeout;
    return $self->{+POST_EXIT_TIMEOUT} = $DEFAULTS{+POST_EXIT_TIMEOUT};
}

for my $field (@BOOL) {
    my $f = $field;
    next if __PACKAGE__->can($field);
    no strict 'refs';
    *$field = sub { ($_[0]->{$f} // $DEFAULTS{$f}) ? 1 : 0 };
    *{"set_$field"} = sub { $_[0]->{$f} = $_[1] ? 1 : 0 };
}

for my $field (@SCALAR) {
    my $f = $field;
    next if __PACKAGE__->can($field);
    no strict 'refs';
    *$field = sub { $_[0]->{$f} // $DEFAULTS{$f} };
    *{"set_$field"} = sub { $_[0]->{$f} = $_[1] };
}

for my $field (@ARRAY) {
    my $f = $field;
    next if __PACKAGE__->can($field);
    no strict 'refs';
    *$field = sub { $_[0]->{$f} // [@{$DEFAULTS{$f} // []}] };
    *{"set_$field"} = sub { $_[0]->{$f} = $_[1] };
}

for my $field (@HASH) {
    my $f = $field;
    next if __PACKAGE__->can($field);
    no strict 'refs';
    *$field = sub { $_[0]->{$f} // {%{$DEFAULTS{$f} // {}}} };
    *{"set_$field"} = sub { $_[0]->{$f} = $_[1] };
}

{
    no warnings 'once';

    *stream        = *use_stream;
    *set_stream    = *set_use_stream;

    *test_args     = *args;
    *set_test_args = *set_args;
}

sub TO_JSON { +{%{$_[0]}, class => blessed($_[0])} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::TestSettings - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

