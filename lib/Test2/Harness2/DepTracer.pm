package Test2::Harness2::DepTracer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    -_on
    -exclude
    -dep_map
    -loaded
    -my_require
    -real_require
    -_my_inc
    -callbacks
    -import_map
    -_exporter_orig
};

my %DEFAULT_EXCLUDE = (
    'warnings.pm' => 1,
    'strict.pm'   => 1,
);

my $ACTIVE;

sub ACTIVE { $ACTIVE }

sub init {
    my $self = shift;

    $self->{+EXCLUDE}    //= {%DEFAULT_EXCLUDE};
    $self->{+DEP_MAP}    //= {};
    $self->{+LOADED}     //= {};
    $self->{+CALLBACKS}  //= {};
    $self->{+IMPORT_MAP} //= {};

    # Capture any existing CORE::GLOBAL::require once; start() will install
    # our wrapper, stop() will restore the original.
    my $stash = \%CORE::GLOBAL::;
    $self->{+REAL_REQUIRE} = exists $stash->{require}
        ? \&{'CORE::GLOBAL::require'}
        : undef;

    my $inc = $self->my_inc;

    my $require = $self->{+MY_REQUIRE} = sub {
        my ($file) = @_;

        my $loaded_by = $self->loaded_by;

        my $real_require = $self->{+REAL_REQUIRE};
        unless ($real_require) {
            my $caller = $loaded_by->[0];
            $real_require = _require_cache($caller);
        }

        goto &$real_require unless $self->{+_ON};

        if ($file =~ m/^[_a-z]/i) {
            unless ($self->{+EXCLUDE}->{$file}) {
                push @{$self->{+DEP_MAP}->{$file}} => $loaded_by;
                $self->{+LOADED}->{$file}++;
            }
        }

        if (!ref($INC[0]) || $INC[0] != $inc) {
            @INC = (
                $inc,
                grep { !(ref($_) && $inc == $_) } @INC,
            );
        }

        local @INC = @INC[1 .. $#INC];

        $real_require->(@_);
    };
}

# Memoized per-caller-package sub that performs a plain CORE::require; used
# when no prior CORE::GLOBAL::require existed and we need to call require
# from within an arbitrary caller's lexical scope.
my %REQUIRE_CACHE;

sub _require_cache {
    my ($caller) = @_;
    return $REQUIRE_CACHE{$caller} //= do {
        my $sub = eval "package $caller; sub { CORE::require(\$_[0]) }"
            or die $@;
        $sub;
    };
}

sub start {
    my $self = shift;

    croak "There is already an active DepTracer" if $ACTIVE;

    $ACTIVE = $self;

    unshift @INC => $self->my_inc;

    {
        no strict 'refs';
        no warnings 'redefine';
        *{'CORE::GLOBAL::require'} = $self->{+MY_REQUIRE};
    }

    $self->_hook_exporter;

    $self->{+_ON} = 1;
}

sub stop {
    my $self = shift;

    croak "DepTracer is not active"     unless $ACTIVE;
    croak "Different DepTracer is active" unless "$ACTIVE" eq "$self";
    $ACTIVE = undef;

    $self->{+_ON} = 0;

    my $inc = $self->{+_MY_INC};
    @INC = grep { !(ref($_) && $inc && $inc == $_) } @INC;

    $self->_unhook_exporter;

    # Restore CORE::GLOBAL::require to whatever we captured at init time.
    # If nothing was there, delete our override entirely.
    {
        no strict 'refs';
        no warnings 'redefine';
        if (my $orig = $self->{+REAL_REQUIRE}) {
            *{'CORE::GLOBAL::require'} = $orig;
        }
        else {
            delete ${CORE::GLOBAL::}{require};
        }
    }

    return 0;
}

sub my_inc {
    my $self = shift;

    return $self->{+_MY_INC} if $self->{+_MY_INC};

    return $self->{+_MY_INC} ||= sub {
        my ($this, $file) = @_;

        return unless $self->{+_ON};
        return unless $file =~ m/^[_a-z]/i;
        return if $self->{+EXCLUDE}->{$file};

        my $loaded_by = $self->loaded_by;
        push @{$self->{+DEP_MAP}->{$file}} => $loaded_by;
        $self->{+LOADED}->{$file}++;

        return;
    };
}

sub clear_loaded { %{$_[0]->{+LOADED}} = () }

sub add_callbacks {
    my $self = shift;
    my %watch = @_;
    for my $file (keys %watch) {
        my $cb = $watch{$file};
        $self->add_callback($file => $cb);
    }
}

sub add_callback {
    my $self = shift;
    my ($file, $cb) = @_;
    $self->{+LOADED}->{$file}++;
    $self->{+CALLBACKS}->{$file} = $cb;
}

sub loaded_by {
    my $level = 1;

    while (my @caller = caller($level++)) {
        next if $caller[0] eq __PACKAGE__;
        return [$caller[0], $caller[1]];
    }

    return ['', ''];
}

# ----- Importer tracking (new) --------------------------------------------
#
# We hook Exporter::import so that every `use Source @args` call from any
# target package is recorded. The reloader uses this inverse map to re-run
# imports after reloading an exporter module.
#
# Custom import() methods that bypass Exporter (Moose, Sub::Exporter, etc.)
# are NOT auto-captured; callers may use record_import() directly to
# register them.

sub _hook_exporter {
    my $self = shift;

    return if $self->{+_EXPORTER_ORIG};

    # Make sure Exporter is loaded so Exporter::import exists.
    require Exporter;

    my $orig = \&Exporter::import;
    $self->{+_EXPORTER_ORIG} = $orig;

    my $recorder = sub {
        my $source = $_[0];
        return unless defined $source && length $source;

        # Exporter::import consults ${"${source}::ExportLevel"}. We must
        # too, so the recorded target matches the package Exporter itself
        # exports into. Call chain inside the recorder:
        #   caller(0) = recorder, caller(1) = wrapper (Exporter::import
        #   stand-in), caller(2+$level) = the code that did `use Source`.
        # Exporter::import would read caller($level) from its own frame;
        # from our recorder that is caller(1 + $level).
        my $level = 0;
        {
            no strict 'refs';
            $level = ${"${source}::ExportLevel"} || 0;
        }

        my $target = (caller(1 + $level))[0];
        return unless defined $target && length $target;

        $self->record_import($source, $target, [@_[1 .. $#_]]);
    };

    {
        no strict 'refs';
        no warnings 'redefine';
        *Exporter::import = sub {
            $recorder->(@_);
            goto &$orig;
        };
    }
}

sub _unhook_exporter {
    my $self = shift;

    my $orig = delete $self->{+_EXPORTER_ORIG} or return;

    no strict 'refs';
    no warnings 'redefine';
    *Exporter::import = $orig;
}

sub record_import {
    my $self = shift;
    my ($source, $target, $args) = @_;

    return unless defined $source && length $source;
    return unless defined $target && length $target;

    $args //= [];

    push @{$self->{+IMPORT_MAP}->{$source}->{$target}} => [@$args];
}

sub importers_of {
    my $self = shift;
    my ($source) = @_;

    my $targets = $self->{+IMPORT_MAP}->{$source} or return [];
    return [sort keys %$targets];
}

sub import_args {
    my $self = shift;
    my ($source, $target) = @_;

    my $map = $self->{+IMPORT_MAP}->{$source}     or return [];
    my $arg = $map->{$target}                      or return [];
    return [map { [@$_] } @$arg];
}

sub clear_imports {
    my $self = shift;
    my ($source) = @_;

    if (defined $source) {
        delete $self->{+IMPORT_MAP}->{$source};
    }
    else {
        %{$self->{+IMPORT_MAP}} = ();
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DepTracer - Trace module dependencies and exporter imports
as they happen during module load.

=head1 DESCRIPTION

When a stage in the L<Test2::Harness2> preload tree detects a file change
and needs to reload a module, the harness must know I<what other modules
were pulled in because of it> (so those can be reloaded too) and I<what
packages imported names from it> (so those imports can be replayed).

DepTracer maintains both maps. It hooks C<CORE::GLOBAL::require> and
L<Exporter/import> while active, and exposes the resulting graphs.

=head1 SYNOPSIS

    use Test2::Harness2::DepTracer;

    my $dt = Test2::Harness2::DepTracer->new;
    $dt->start;

    require Some::Thing;        # Some/Thing.pm -> dep_map tracks it
    Some::Thing->import(@args); # import_map tracks caller + args

    $dt->stop;

    my $loaded_by = $dt->dep_map->{'Some/Thing.pm'};
    my $importers = $dt->importers_of('Some::Thing');
    my $args_list = $dt->import_args('Some::Thing', 'Some::Caller');

=head1 ATTRIBUTES

=over 4

=item $hashref = $dt->exclude

Files/modules to skip. Defaults to C<strict> and C<warnings>.

=item $hashref = $dt->dep_map

Keyed by filename (C<Foo/Bar.pm>), value is an arrayref of
C<[caller_pkg, caller_file]> pairs recording everything that triggered a
load of the file.

=item $hashref = $dt->loaded

Count of direct loads per file.

=item $hashref = $dt->import_map

Keyed by source package, then by target package, value is a list of
argument-arrayrefs passed to each C<import()> call. Populated by hooking
C<Exporter::import> and by explicit calls to C<record_import>.

=back

=head1 METHODS

=over 4

=item $dt->start

Install the C<@INC> hook, the C<CORE::GLOBAL::require> wrapper, and the
C<Exporter::import> shim. Sets the class-level ACTIVE reference.

=item $dt->stop

Remove the hooks and clear ACTIVE. Does not clear the collected maps;
callers may inspect them after stop.

=item $dt->clear_loaded

Wipe the C<loaded> counters (keeps C<dep_map> and C<import_map>).

=item $dt->clear_imports($source_pkg?)

Drop entries in C<import_map>. With no argument, clears every source. With
an argument, clears just that source.

=item $dt->add_callback($file, $cb)

Register a callback to run when C<$file> is reloaded by a consumer. Seeds
C<loaded> so the consumer knows a watch exists on the file.

=item $dt->add_callbacks(%file_to_cb)

Bulk form of C<add_callback>.

=item $dt->record_import($source_pkg, $target_pkg, \@args)

Register an import event manually. Use this for exporter-like modules that
do not go through C<Exporter::import> (Moose, Sub::Exporter, Importer with
a custom class method, etc.) if you want their callers to be replayed
during reload.

=item $pkgs = $dt->importers_of($source_pkg)

Sorted arrayref of target packages that imported from C<$source_pkg>
during the traced interval.

=item $args = $dt->import_args($source_pkg, $target_pkg)

Arrayref of deep-copied argument arrayrefs, one per recorded C<import()>
call from C<$source_pkg> into C<$target_pkg>.

=back

=head1 CLASS METHODS

=over 4

=item $dt_or_undef = Test2::Harness2::DepTracer->ACTIVE()

Return the currently active DepTracer, if any. Only one may be active at a
time.

=back

=head1 CAVEATS

=over 4

=item Custom importers

Modules that install their own C<import> method (Moose, Sub::Exporter, many
Exporter::Tiny consumers with overridden behavior) bypass the
C<Exporter::import> hook. Their import events will not be captured
automatically. Teach such modules to call C<record_import> on the
active DepTracer if you want their imports included.

=item ExportLevel

The Exporter hook reads C<$Source::ExportLevel> at call time, matching the
behavior of C<Exporter::import> itself. Modules that set an unusual
C<ExportLevel> will be recorded with the target at that level.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
