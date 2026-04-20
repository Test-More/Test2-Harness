package Test2::Harness2::Reloader::Default;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Util qw/mod2file/;

# Object::HashBase doesn't generate new() from a bare empty slot
# list, so we install one explicitly. The reloader is stateless --
# every policy decision comes from the (module, file, info) tuple --
# but the HashBase-style new() keeps the role construction pattern
# consistent with the other services in this distribution.
sub new {
    my $class = shift;
    return bless {@_}, $class;
}

use Role::Tiny::With;
with 'Test2::Harness2::Role::Reloader';

# Does Moose look usable? We treat "Moose is loaded" as the signal --
# no point dragging the dep in at check time when the preload service
# would only be reloading a Moose-based module if Moose was already in
# memory.
use constant HAS_MOOSE => eval { require Moose; 1 } ? 1 : 0;

sub viable { 1 }

sub reload_module {
    my ($self, $module, $file, $info) = @_;
    $info //= {};

    # User-provided watch callback wins -- the DSL author knows what
    # they want done for this file.
    if (my $cb = $info->{callback}) {
        my ($status, %fields) = $cb->($file);
        return ($status, %fields) if defined $status;
    }

    # HARNESS-CHURN blocks: re-eval the marked subroutine bodies
    # without touching the rest of the module's package state.
    if (my $churn = $info->{churn}) {
        return $self->_reload_churn($module, $file, $churn);
    }

    # Non-perl files without a callback we bail on.
    return ('not_reloadable', reason => "non-perl file with no watch callback")
        unless $info->{perl};

    # Modules with a non-trivial import() are refused by default.
    # Callers that want Exporter-based reload can layer a dedicated
    # reloader (e.g. Test2::Harness2::Reloader::Exporter in old/);
    # Stage 9 ships only the Default + KillRestart pair.
    return ('not_reloadable', reason => "module has non-trivial import()")
        if $info->{has_import};

    return ('not_reloadable', reason => "no module name associated with '$file'")
        unless $module;

    return $self->_reload_in_place($module, $file, $info);
}

sub _reload_in_place {
    my ($self, $module, $file, $info) = @_;

    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings => @_ };

        # Moose-aware path: re-initialise the metaclass so accessors
        # and roles come back correctly. Otherwise re-requiring a
        # Moose-consuming file leaves the metaclass half-updated.
        if ($info->{is_moose} && HAS_MOOSE) {
            $self->_reload_moose($module, $file, $info);
        }
        else {
            $self->_reload_generic($module, $file, $info);
        }

        1;
    };
    my $err = $@;

    return (0, reason => $err) unless $ok;
    return (0, reason => "reload emitted warnings: " . join("", @warnings))
        if @warnings;
    return (1);
}

sub _reload_generic {
    my ($self, $module, $file, $info) = @_;

    # Clear the package's stash so the re-require starts with a clean
    # symbol table. Nested-package entries (ending in "::") stay put.
    {
        no strict 'refs';
        my $stash = \%{"${module}::"};
        for my $sym (keys %$stash) {
            next if $sym =~ /::$/;
            delete $stash->{$sym};
        }
    }

    my $inc_entry = $info->{inc_entry} // mod2file($module);

    delete $INC{$inc_entry};
    delete $INC{$file};

    local $.;
    require $file;

    $INC{$inc_entry} //= $file;
    $INC{$file}      //= $file;

    return 1;
}

sub _reload_moose {
    my ($self, $module, $file, $info) = @_;

    # Best-effort metaclass reset: reinitialise so the module's
    # post-reload `use Moose` rebuilds everything. Skip
    # Moose::Meta::Class::create_anon_class-style phantom classes.
    my $meta = $module->can('meta') ? $module->meta : undef;
    if ($meta && $meta->can('_reinitialize_class')) {
        $meta->_reinitialize_class(1);
    }
    elsif (eval { require Moose::Util::MetaRole; 1 }) {
        # Nothing specific to do -- the generic reload below will
        # rebuild the metaclass from the source file.
    }

    return $self->_reload_generic($module, $file, $info);
}

sub _reload_churn {
    my ($self, $module, $file, $churn) = @_;

    my @errors;
    for my $block (@$churn) {
        my ($start, $code, $end) = @$block;
        my $sline = $start + 1;

        my $src = "package $module;\n" . "use strict;\n" . "use warnings;\n" . "no warnings 'redefine';\n" . "#line $sline $file\n" . "$code\n;1;";

        my $ok = eval $src;
        push @errors => "$file (churn $start-$end): $@" unless $ok;
    }

    return (0, reason => join("\n", @errors)) if @errors;
    return (1);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::Default - Default in-place reloader for
the preload system.

=head1 DESCRIPTION

Implements the reload policy described in C<IPC_AND_LOGGERS> section
10.5 under "in-place reload". Attempts to re-run a changed module
inside the same preload-stage process. Order of operations:

=over 4

=item 1. User-supplied watch callback -- if the DSL's C<watch $file
=E<gt> $cb> registered a custom callback, it runs first.

=item 2. HARNESS-CHURN blocks -- if the file contains
C<#HARNESS-CHURN-START> / C<#HARNESS-CHURN-STOP> markers, just the
bracketed subroutine bodies are re-eval'd (via C<eval $src> with
C<#line> directives) so line numbers in stack traces stay accurate.

=item 3. Generic path -- clear the package's stash, delete C<%INC>,
C<require> again. Moose-consuming modules get a metaclass reset
first so accessors and roles rebuild correctly.

=back

A module with a non-trivial C<import()> is refused with C<('not_reloadable', reason => ...)>.
The caller (typically the preload resource) can then chain to a
secondary reloader (e.g. L<Test2::Harness2::Reloader::KillRestart>)
to trigger branch pruning.

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
