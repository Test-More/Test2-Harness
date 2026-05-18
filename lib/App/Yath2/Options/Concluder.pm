package App::Yath2::Options::Concluder;
use strict;
use warnings;

our $VERSION = '2.000013';

use Test2::Harness2::Util qw/mod2file fqmod/;

use Getopt::Yath;

option_group {group => 'concluder', category => "Concluder Options"} => sub {
    option classes => (
        type  => 'Map',
        name  => 'concluders',
        field => 'classes',
        alt   => ['concluder'],

        description => 'Specify concluders. Use "+" to give a fully qualified module name. Without "+" "App::Yath2::Concluder::" will be prepended to your argument. Concluders run sequentially in the parent process after all renderer children reap. Default set: Summary + ResetTerm.',

        long_examples  => [' +My::Concluder', ' Summary', ' Summary,ResetTerm', ' Notify=opt1,opt2'],
        short_examples => [' +My::Concluder', ' Summary', ' Summary,ResetTerm', ' Notify=opt1,opt2'],

        # Default set: Summary then ResetTerm. The dispatcher runs
        # ResetTerm last regardless of registration order, so this
        # ordering is documentation-only.
        initialize => sub { {'App::Yath2::Concluder::Summary' => [], 'App::Yath2::Concluder::ResetTerm' => []} },

        normalize => sub { fqmod($_[0], ['App::Yath2::Concluder']), ref($_[1]) ? $_[1] : [split(',', $_[1] // '')] },

        mod_adds_options => 1,

        # --no-concluder / --no-concluders is the auto-generated clear
        # form. Map clear empties the hash; if the user wants to start
        # fresh and then add specific concluders, they pass
        # --no-concluder followed by --concluder NAME.
    );
};

# Instantiate the active concluders. Returns a sorted arrayref ready for
# the dispatch loop in App::Yath2::Command::test (and eventually
# Command::run / Command::replay).
#
# Ordering: ResetTerm is always last, regardless of registration order,
# so it has the final word on the terminal state after every other
# concluder has flushed. Other concluders sort by class name for
# determinism.
sub init_concluders {
    my $class = shift;
    my ($settings, %params) = @_;

    return [] unless $settings->check_group('concluder');

    my $cs        = $settings->concluder;
    my $c_classes = $cs->classes // {};
    return [] unless keys %$c_classes;

    my @names = keys %$c_classes;

    # ResetTerm last; everything else stable-sorts by class name.
    my @ordered = sort {
        my $a_last = $a eq 'App::Yath2::Concluder::ResetTerm' ? 1 : 0;
        my $b_last = $b eq 'App::Yath2::Concluder::ResetTerm' ? 1 : 0;
        $a_last <=> $b_last || $a cmp $b;
    } @names;

    my $log = $params{log};

    my @concluders;
    for my $mod (@ordered) {
        my $file = mod2file($mod);
        require $file unless $INC{$file};

        my $args = $c_classes->{$mod} // [];

        my $c = $mod->new(
            log      => $log,
            settings => $settings,
            @$args,
        );

        push @concluders, $c;
    }

    return \@concluders;
}

# Dispatch every concluder in $list against $log, in registration order
# (with ResetTerm pinned last by init_concluders). Failures are caught
# and emitted as warnings so one failing concluder does not block the
# rest of the chain. Returns the number of concluders that ran without
# raising.
sub dispatch_concluders {
    my $class = shift;
    my ($concluders) = @_;
    return 0 unless ref($concluders) eq 'ARRAY' && @$concluders;

    my $ran = 0;
    for my $c (@$concluders) {
        my $ok = eval { $c->run; 1 };
        if ($ok) {
            $ran++;
        }
        else {
            my $err  = $@;
            my $name = ref($c);
            warn "Concluder $name failed: $err";
        }
    }

    return $ran;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Concluder - Concluder selection and parent-side dispatch.

=head1 DESCRIPTION

Defines the C<--concluder NAME> / C<--no-concluder> option pair and
provides helpers that the parent command uses to construct and dispatch
the active concluder set after all renderer children have been reaped.

=head2 Default concluder set

C<App::Yath2::Concluder::Summary> and C<App::Yath2::Concluder::ResetTerm>.

=head2 Selection semantics

=over 4

=item C<--concluder NAME>

Append C<NAME> to the active concluder set. C<NAME> is fully qualified
when prefixed with C<+>; otherwise C<App::Yath2::Concluder::> is
prepended.

=item C<--no-concluder>

Clear the active concluder set entirely. Combine with one or more
C<--concluder NAME> flags to start fresh and choose explicitly.

=back

C<ResetTerm> is always dispatched last regardless of registration order
so it has the final word on the terminal state.

=head1 PARENT-PROCESS DISPATCH

C<App::Yath2::Command::test> (and, in a follow-up, C<Command::run> and
C<Command::replay>) calls:

    my $concluders = App::Yath2::Options::Concluder->init_concluders(
        $settings,
        log => $log,
    );
    App::Yath2::Options::Concluder->dispatch_concluders($concluders);

C<init_concluders> instantiates each active concluder class with the
shared Log, settings, and any per-class option args. C<dispatch_concluders>
runs each in order; a concluder that dies has its error reported as a
warning and the rest of the chain proceeds.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
