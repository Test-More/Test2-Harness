package App::Yath2::Plugins;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Util qw/mod2file/;

# Turn the Map that Getopt::Yath produces for --plugin into a list of
# plugin "handles" ready to be dispatched against.
#
# Input shape (what $settings->yath->plugins hands back):
#
#   {
#       'App::Yath2::Plugin::Foo' => ['arg1', 'arg2'],
#       'App::Yath2::Plugin::Bar' => [],
#   }
#
# For each key, load the module, then produce a handle the caller can
# send hook calls through:
#
#   - If the class defines new(), instantiate it with the arrayref
#     args splatted: $class->new(@$args). The instance is the handle.
#   - Otherwise the class itself is the handle; hooks are class methods.
#
# This mirrors the "plugin is class or instance" convention inherited
# from old/ and kept by App::Yath2::Role::Plugin: callers always use
# $plugin->hook(...) without caring which form they received.

sub load_plugins {
    my ($class, $plugin_specs) = @_;
    $plugin_specs //= {};

    croak "Plugin specs must be a hashref (got '$plugin_specs')"
        unless ref($plugin_specs) eq 'HASH';

    my @plugins;
    for my $pclass (sort keys %$plugin_specs) {
        my $args = $plugin_specs->{$pclass};

        croak "Plugin '$pclass' args must be an arrayref"
            unless ref($args) eq 'ARRAY';

        my $file = mod2file($pclass);
        unless (eval { require $file; 1 }) {
            my $err = $@;
            croak "Failed to load plugin '$pclass': $err";
        }

        my $plugin;
        if ($pclass->can('new')) {
            $plugin = $pclass->new(@$args);
        }
        else {
            croak "Plugin '$pclass' has no new() but was given constructor args (@$args)"
                if @$args;
            $plugin = $pclass;
        }

        push @plugins => $plugin;
    }

    return \@plugins;
}

# Small convenience wrapper: call $hook on every plugin that can()
# it, in order, collecting results. Any plugin that does not
# implement $hook is skipped (rather than hitting the role's empty
# default) so that list-returning hooks do not accumulate empty
# answers from every plugin in the set.
sub dispatch {
    my ($class, $plugins, $hook, @args) = @_;

    my @out;
    for my $plugin (@$plugins) {
        next unless $plugin->can($hook);
        my @result = $plugin->$hook(@args);
        push @out => @result;
    }
    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugins - Instantiate and dispatch against yath plugins.

=head1 SYNOPSIS

    use App::Yath2::Plugins;

    my $plugins = App::Yath2::Plugins->load_plugins(
        $settings->yath->plugins,
    );

    # Later, at a hook site:
    $_->client_setup(settings => $settings) for @$plugins;

    # Or via the helper (skips plugins that do not define the hook):
    my @extra = App::Yath2::Plugins->dispatch(
        $plugins, 'client_teardown', settings => $settings,
    );

=head1 DESCRIPTION

Turns the C<plugins> Map produced by C<App::Yath2::Options::Yath>
into an ordered arrayref of loaded plugins, each either a class
name or a blessed instance depending on whether the plugin class
defines C<new()>. Callers dispatch hook methods against the
elements directly (with or without the C<dispatch()> helper); see
L<App::Yath2::Role::Plugin> and L<Test2::Harness2::Role::Plugin>
for the available hooks.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>.

=cut
