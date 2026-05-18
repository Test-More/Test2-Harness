package App::Yath2::Concluder::Notify;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Concluder';

# v1 stub: enumerate configured notification channels (email / slack)
# from $settings->notify and print one "NOTIFY: <kind> <message>" line
# to STDERR per channel. The legacy renderer-based notifier dispatched
# email via Email::Stuffer and slack via HTTP::Tiny webhooks; porting
# those external integrations to the descriptor-driven path lands in a
# follow-up commit.
#
# This stub still walks the Log to derive a simple pass/fail summary so
# the placeholder message reflects the real outcome.
sub run {
    my $self     = shift;
    my $settings = $self->settings;
    my $log      = $self->log;

    # Settings group may be absent (e.g. unit tests without the option
    # group included); treat that as "no channels configured" and
    # silently no-op.
    my $notify = $self->_notify_settings($settings);
    return unless $notify;

    my @channels = $self->_configured_channels($notify);
    return unless @channels;

    my $msg = $self->_build_summary_message($log);

    # Errors here must not derail the rest of the concluder chain.
    # Print to STDERR so the placeholder is visible without trampling
    # any renderer's STDOUT output.
    for my $ch (@channels) {
        my $ok = eval { print STDERR "NOTIFY: $ch $msg\n"; 1 };
        warn "Notify concluder channel '$ch' failed: $@" unless $ok;
    }

    return;
}

sub _notify_settings {
    my ($self, $settings) = @_;
    return undef unless $settings;
    return undef unless $settings->can('check_group') && $settings->check_group('notify');
    return $settings->notify;
}

sub _configured_channels {
    my ($self, $notify) = @_;
    my @channels;

    # Email channels — any populated list or the email_from sender
    # counts as a configured channel.
    for my $field (qw/email email_fail/) {
        next unless $notify->can($field);
        my $val = $notify->$field;
        next unless ref($val) eq 'ARRAY' && @$val;
        push @channels, "email:$_" for @$val;
    }
    push @channels, "email:owner" if $notify->can('email_owner') && $notify->email_owner;

    # Slack channels — list-shaped (channel/user names) plus the
    # owner toggle.
    for my $field (qw/slack slack_fail/) {
        next unless $notify->can($field);
        my $val = $notify->$field;
        next unless ref($val) eq 'ARRAY' && @$val;
        push @channels, "slack:$_" for @$val;
    }
    push @channels, "slack:owner" if $notify->can('slack_owner') && $notify->slack_owner;

    return @channels;
}

sub _build_summary_message {
    my ($self, $log) = @_;

    my ($any_run, $any_fail) = (0, 0);
    my @runs = $log->run_producers->all;

    for my $run_p (@runs) {
        $any_run++;
        my $rp = $run_p->pass;
        $any_fail++ if defined $rp && !$rp;

        for my $job_p ($log->job_producers($run_p->id)->all) {
            next unless ($job_p->state // '') eq 'sealed';
            my $jp = $job_p->pass;
            next        unless defined $jp;    # abandoned: skip
            $any_fail++ unless $jp;
        }
    }

    return "no runs in log" unless $any_run;
    return $any_fail ? "test run FAILED" : "test run PASSED";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Concluder::Notify - End-of-run notification dispatch (v1 stub).

=head1 DESCRIPTION

Sends end-of-run notifications based on the C<notify> options group
(C<--notify-email>, C<--notify-slack>, etc.).

The v1 implementation is a placeholder: it enumerates configured
channels (email addresses, slack channel / user names, and the owner
toggles) and prints a single C<NOTIFY: $channel $message> line per
channel to STDERR. The real channel implementations (SMTP via
L<Email::Stuffer>, Slack webhook via L<HTTP::Tiny>) port from the
legacy renderer in a follow-up.

When the C<notify> settings group is not present, or no channels are
configured, C<run> is a silent no-op.

=head1 METHODS

=over 4

=item $c->run

Enumerate configured channels and emit one placeholder notification
line per channel to STDERR. Returns without writing when no channels
are configured.

=back

=head1 SEE ALSO

L<App::Yath2::Concluder>,
L<App::Yath2::Renderer::Notify> (the legacy renderer that hosts the
SMTP / Slack integrations to be ported).

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
