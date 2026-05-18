package App::Yath2::Renderer2::Registry;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Test2::Harness2::Util qw/mod2file/;

# Map short renderer names to fully qualified Renderer2::* classes. The
# short names are what users type on the command line:
#
#   yath render terminal LOGPATH
#   yath render junit    LOGPATH --junit-out=res.xml
#
# Each entry is a [class, default-option-prefix] pair. The option prefix
# is the flat namespace the renderer owns; prefix-ownership conflicts
# between renderers are caught at registration time (see assert_prefix
# below), not at parse time.
my %BUILTIN = (
    'terminal'      => ['App::Yath2::Renderer2::Terminal', 'terminal'],
    'terminal-auto' => ['App::Yath2::Renderer2::Terminal', 'terminal'],
    'junit'         => ['App::Yath2::Renderer2::JUnit',    'junit'],
);

# Tracks which prefix is owned by which renderer class. Populated lazily
# by assert_prefix on first registration. Keyed by prefix string, values
# are the owning class. A second registration of the same prefix by a
# different class is fatal.
my %PREFIX_OWNER;

# Lookup the (class, prefix) tuple for a short renderer name. Croaks
# when the name does not resolve. Accepts a leading '+' on a fully
# qualified class name, matching the convention used elsewhere in the
# codebase (e.g. --renderer +My::Renderer).
sub resolve_name {
    my ($class, $name) = @_;
    croak "renderer name is required" unless defined $name && length $name;

    if ($name =~ /^\+(.+)$/) {
        my $mod = $1;
        return ($mod, _default_prefix_for($mod));
    }

    my $entry = $BUILTIN{$name};
    return @$entry if $entry;

    # Fall back: title-case the dashed form, prepend the namespace.
    # `terminal-auto` -> `TerminalAuto`. This keeps custom renderers
    # invokable without an explicit `+` so long as they live under
    # App::Yath2::Renderer2::*.
    my $title = join '', map { ucfirst $_ } split /-/, $name;
    my $mod   = "App::Yath2::Renderer2::$title";
    return ($mod, $name);
}

# Derive a default option prefix from a renderer class name. Used when
# the caller invoked `+My::Renderer` and didn't declare a prefix on the
# class. The default is the lowercased last package segment.
sub _default_prefix_for {
    my ($class) = @_;
    my $tail = $class;
    $tail =~ s/.*:://;
    $tail =~ s/([a-z])([A-Z])/$1-$2/g;
    return lc($tail);
}

# Register $prefix as owned by $class. Croaks if a different class has
# already claimed it. Idempotent for the same class. This is the only
# enforcement point for flat-option prefix ownership — Stage 8 spec
# requires registration-time detection, not parse-time.
sub assert_prefix {
    my ($class, $renderer_class, $prefix) = @_;
    croak "prefix is required"         unless defined $prefix         && length $prefix;
    croak "renderer_class is required" unless defined $renderer_class && length $renderer_class;

    my $owner = $PREFIX_OWNER{$prefix};
    if (defined $owner && $owner ne $renderer_class) {
        croak "renderer option prefix '$prefix' is already owned by '$owner'; " . "'$renderer_class' cannot also claim it. Each renderer name must own its option prefix exactly.";
    }
    $PREFIX_OWNER{$prefix} = $renderer_class;
    return;
}

# Reset the prefix table. Intended for tests; nothing in production
# code should ever need to call this.
sub _reset_prefix_table { %PREFIX_OWNER = (); return }

# Return a snapshot of the prefix→class map. For tests and diagnostics.
sub prefix_owners { return {%PREFIX_OWNER} }

# Load $class, registering its prefix on the way. Returns the loaded
# class name. Croaks on prefix conflicts (assert_prefix above).
sub load_renderer {
    my ($class, $renderer_class, $prefix) = @_;
    require(mod2file($renderer_class));
    $class->assert_prefix($renderer_class, $prefix);
    return $renderer_class;
}

# Convenience: resolve, load, and assert in one call. Returns
# ($class, $prefix). The `yath render` command uses this when it
# resolves the positional NAME arg.
sub resolve_and_load {
    my ($class, $name)   = @_;
    my ($mod,   $prefix) = $class->resolve_name($name);
    $class->load_renderer($mod, $prefix);
    return ($mod, $prefix);
}

# Walk every known renderer and merge its Getopt::Yath option group
# into $opts (a Getopt::Yath::Instance). Used by the `yath render`
# command to make every renderer's flat options available to the
# parser without the user having to declare the renderer up front.
#
# Prefix conflicts surface here as well as at load_renderer time: the
# include() call lands every renderer's options on the same instance,
# so a later renderer declaring an already-claimed prefix triggers
# assert_prefix's croak before parsing begins.
sub include_all_renderer_options {
    my ($class, $opts) = @_;
    croak "options instance is required" unless $opts;

    my %seen_class;
    for my $name (sort keys %BUILTIN) {
        my ($mod, $prefix) = @{$BUILTIN{$name}};
        next if $seen_class{$mod}++;
        $class->load_renderer($mod, $prefix);
        next unless $mod->can('options');
        $opts->include($mod->options);
    }
    return;
}

# Build a list of CLI arguments that re-create the chosen renderer's
# settings from a parsed Settings object. Used by parent commands
# (e.g. `yath replay`) that fan out to a child `yath render` per
# active renderer and need to pass through every flat-option value.
#
# $settings_obj must respond to ->check_group($name) and ->$name
# (Getopt::Yath::Settings shape). Returns an arrayref of CLI tokens.
# Each option is emitted as two tokens (--name VALUE) to avoid the
# quoting pitfalls of "--name=VALUE" with embedded equals signs in
# the value.
sub renderer_option_args {
    my ($class, $renderer_class, $prefix, $settings_obj) = @_;
    croak "renderer_class is required" unless defined $renderer_class && length $renderer_class;
    croak "prefix is required"         unless defined $prefix         && length $prefix;
    croak "settings is required"       unless defined $settings_obj;

    return [] unless $renderer_class->can('options');
    my $instance = $renderer_class->options;

    # Resolve the settings group by name. The group key matches the
    # `group => ...` declaration in option_group; Getopt::Yath does
    # not surface that on each Option, so we read it off the first
    # option in the include. All options in one group share `->group`.
    my @opts = @{$instance->options};
    return [] unless @opts;
    my $group_name = $opts[0]->group;

    return [] unless $settings_obj->check_group($group_name);
    my $group = $settings_obj->$group_name;

    my @out;
    for my $opt (@opts) {
        my $field = $opt->field;
        my $val   = $group->$field;
        next unless defined $val;
        next if ref($val) eq 'ARRAY' && !@$val;
        next if ref($val) eq 'HASH'  && !%$val;

        # Reconstruct the CLI form with the option group's prefix
        # applied; Option->name returns the bare field, and the
        # actual long flag is prefix-joined inside Option->forms.
        my $opt_prefix = $opt->prefix;
        my $flat_name =
            defined($opt_prefix) && length($opt_prefix)
            ? "${opt_prefix}-" . $opt->name
            : $opt->name;
        my $cli = "--$flat_name";

        if (ref($val) eq 'ARRAY') {
            push @out, $cli, $_ for @$val;
        }
        elsif (ref($val) eq 'HASH') {
            push @out, $cli, "$_=" . $val->{$_} for sort keys %$val;
        }
        elsif (!ref($val)) {
            push @out, $cli, "$val";
        }
        else {
            # Skip references we don't know how to serialise.
        }
    }

    return \@out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::Registry - Renderer name resolution + flat-prefix ownership.

=head1 DESCRIPTION

A small registry of the short renderer names users type at the command
line (C<terminal>, C<terminal-auto>, C<junit>, etc.) plus the
fully-qualified Perl class that implements each one. Used by
L<App::Yath2::Command::render> to translate the positional C<NAME>
argument into a loadable class and the option prefix that renderer
owns.

=head2 Flat-option prefix ownership

Each renderer name owns its flat option prefix exactly. The
L</assert_prefix> helper records the C<< prefix => owning-class >>
mapping the first time a renderer is loaded and refuses any later
attempt to register the same prefix from a different class. This makes
naming conflicts surface at registration time (when a plugin or new
renderer is being added) rather than at command-parse time where the
diagnostic would point at the wrong place.

=head1 FUNCTIONS

All functions are class methods on C<App::Yath2::Renderer2::Registry>.

=over 4

=item ($class, $prefix) = App::Yath2::Renderer2::Registry->resolve_name($name)

Resolve a short renderer name to a Perl class and its option prefix.
The short forms are:

=over 4

=item C<terminal>, C<terminal-auto>

Both resolve to L<App::Yath2::Renderer2::Terminal> with prefix
C<terminal>.

=item C<junit>

L<App::Yath2::Renderer2::JUnit> with prefix C<junit>.

=item C<+Fully::Qualified::Class>

Use the given Perl class directly. The option prefix defaults to a
lowercased dashed form of the last namespace segment (e.g.
C<+My::Renderer::FooBar> gives prefix C<foo-bar>).

=item I<dashed-name>

Falls back to title-casing the dashed name and prepending the
namespace. So C<terminal-auto> would also resolve to
C<App::Yath2::Renderer2::TerminalAuto> (currently a selector module
rather than a renderer class) via this branch — the explicit
C<terminal-auto> entry in the registry overrides the fallback.

=back

Croaks when C<$name> is missing.

=item App::Yath2::Renderer2::Registry->assert_prefix($renderer_class, $prefix)

Record that C<$renderer_class> owns C<$prefix>. Calling with a prefix
already claimed by another class is fatal with a clear message naming
both the existing owner and the rejected claimant. Idempotent: a class
re-registering its own prefix is a no-op.

=item App::Yath2::Renderer2::Registry->load_renderer($renderer_class, $prefix)

C<require> the renderer class and call L</assert_prefix>. Returns the
class name. Used by C<resolve_and_load>.

=item ($class, $prefix) = App::Yath2::Renderer2::Registry->resolve_and_load($name)

Composition of C<resolve_name> + C<load_renderer>. The single call
C<yath render NAME ...> uses to translate the user's argument into a
loaded, prefix-asserted Perl class.

=item $hashref = App::Yath2::Renderer2::Registry->prefix_owners

Snapshot of the current C<< prefix => class >> map. Read-only copy;
mutating it does not affect the registry. For tests and diagnostics.

=item App::Yath2::Renderer2::Registry->_reset_prefix_table

Clear the prefix ownership table. Tests only. Production code must
never call this.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
