package App::Yath::Plugin::Notify;
use strict;
use warnings;

our $VERSION = '1.000046';

use Test2::Harness::Util::JSON qw/encode_json/;

use Sys::Hostname qw/hostname/;

use App::Yath::Options;

use parent 'App::Yath::Plugin';
use Test2::Harness::Util::HashBase qw/-final -tries/;

# Notifications only apply to commands which build a run.
sub applicable {
    my ($option, $options) = @_;

    return 1 if $options->included->{'App::Yath::Options::Run'};
    return 0;
}

option_group {prefix => 'notify', category => "Notification Options", applicable => \&applicable} => sub {
    option slack => (
        type => 'm',
        description => "Send results to a slack channel and/or user",
        long_examples  => [" '#foo'", " '\@bar'"],
    );

    option slack_fail => (
        type => 'm',
        description => "Send failing results to a slack channel and/or user",
        long_examples => [" '#foo'", " '\@bar'"],
    );

    option slack_url => (
        type => 's',
        description => "Specify an API endpoint for slack webhook integrations",
        long_examples  => [" https://hooks.slack.com/..."],
    );

    option slack_owner => (
        type => 'b',
        description => "Send slack notifications to the slack channels/users listed in test meta-data when tests fail.",
        default => 0,
    );

    option no_batch_slack => (
        type => 'b',
        default => 0,
        description => 'Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.',
    );

    option email_from => (
        type          => 's',
        long_examples => [' foo@example.com'],
        description   => "If any email is sent, this is who it will be from",
        default       => sub {
            my $user = getlogin() || scalar(getpwuid($<)) || $ENV{USER} || 'unknown';
            my $host = hostname() || 'unknown';
            return "${user}\@${host}";
        },
    );

    option email => (
        type => 'm',
        long_examples => [' foo@example.com'],
        description => "Email the test results to the specified email address(es)",
    );

    option email_fail => (
        type => 'm',
        long_examples => [' foo@example.com'],
        description => "Email failing results to the specified email address(es)",
    );

    option email_owner => (
        type => 'b',
        description => 'Email the owner of broken tests files upon failure. Add `# HARNESS-META-OWNER foo@example.com` to the top of a test file to give it an owner',
        default => 0,
    );

    option no_batch_email => (
        type => 'b',
        default => 0,
        description => 'Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.',
    );

    option text => (
        type => 's',
        alt => ['message', 'msg'],
        description => "Add a custom text snippet to email/slack notifications",
    );

    post sub {
        my %params = @_;

        my $settings = $params{settings};
        my $options  = $params{options};

        my $set_by_cli = $options->set_by_cli->{notify};

        # Should we use email?
        if (@{$settings->notify->email} || $settings->notify->email_owner) {
            $settings->notify->field(email_owner => 1) unless $set_by_cli->{email_owner};

            # Do we have Email::Stuffer?
            eval { require Email::Stuffer; 1 } or die "Cannot use --email-owner without Email::Stuffer, which is not installed.\n";

            push @{$settings->harness->plugins} => __PACKAGE__->new() unless grep { $_->isa(__PACKAGE__) } @{$settings->harness->plugins};
        }

        my $use_slack = grep { $settings->notify->$_ } qw/slack_url slack_owner/;
        $use_slack ||= grep { @{$settings->notify->$_} } qw/slack slack_fail/;
        if ($use_slack) {
            die "slack url must be provided in order to use slack" unless $settings->notify->slack_url;

            eval { require HTTP::Tiny; 1 } or die "Cannot use slack without HTTP::Tiny which is not installed.\n";

            die "HTTP::Tiny reports that it does not support SSL, cannot use slack without ssl."
                unless HTTP::Tiny::can_ssl();

            $settings->notify->field(slack_owner => 1) unless $set_by_cli->{slack_owner};

            push @{$settings->harness->plugins} => __PACKAGE__->new() unless grep { $_->isa(__PACKAGE__) } @{$settings->harness->plugins};
        }
    };
};

sub handle_event {
    my $self = shift;
    my ($e, $settings) = @_;

    my $f = $e->facet_data;

    return $self->handle_job_end($e, $f, $settings) if $f->{harness_job_end};
    return $self->handle_final($e, $f, $settings) if $f->{harness_final};

    return;
}

sub handle_final {
    my $self = shift;
    my ($e, $f, $settings) = @_;

    $self->{+FINAL} = $e;
}

sub handle_job_end {
    my $self = shift;
    my ($e, $f, $settings) = @_;

    return unless $f->{harness_job_end}->{fail};

    my $job_id = $f->{harness}->{job_id};

    if ($f->{harness_job_end}->{retry}) {
        $self->{+TRIES}->{$job_id}++;
        return;
    }

    my @args = ($e, $f, $self->{+TRIES}->{$job_id}, $settings);

    $self->send_job_notification_slack(@args);
    $self->send_job_notification_email(@args);
}

sub send_job_notification_slack {
    my $self = shift;

    my ($e, $f, $tries, $settings) = @_;

    return unless $settings->notify->no_batch_slack;

    my $tf = Test2::Harness::TestFile->new(file => $f->{harness_job_end}->{abs_file});

    my @slack;
    push @slack => $tf->meta('slack') if $settings->notify->slack_owner;
    push @slack => @{$settings->notify->slack_fail};

    return unless @slack;

    my $text = $self->_gen_slack_text($settings, $tf, $tries);

    $self->_send_slack($text, $settings, @slack);
}

sub _gen_slack_text {
    my $self = shift;
    my ($settings, $tf, $tries) = @_;

    my $host = hostname();
    my $file = $tf->relative;

    return join "\n\n" => grep { $_ }
        $settings->notify->text,
        "Failed test on $host: '$file'.",
        $tries ? ("Test was run " . (1 + $tries) . " time(s).") : (),
        join "\n" => map {"> <$_|$_>"} @{$settings->run->links};
}

sub _send_slack {
    my $self = shift;
    my ($text, $settings, @to) = @_;

    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();

    for my $dest (@to) {
        my $r = $ht->post(
            $settings->notify->slack_url,
            {
                headers => {'content-type' => 'application/json'},
                content => encode_json({channel => $dest, text => $text}),
            },
        );
        warn "Failed to send slack message to '$dest'" unless $r->{success};
    }
}

sub send_job_notification_email {
    my $self = shift;

    my ($e, $f, $tries, $settings) = @_;

    return unless $settings->notify->no_batch_email;

    my $tf = Test2::Harness::TestFile->new(file => $f->{harness_job_end}->{abs_file});

    my @to;
    push @to => $tf->meta('owner') if $settings->notify->email_owner;
    push @to => @{$settings->notify->email_fail};
    return unless @to;

    my $text = $self->_gen_email_text($settings, $tf, $tries);
    my $subject = "Failed test on " . hostname() . ": '" . $tf->relative . "'.";

    $self->_send_email($subject, $text, $settings, @to);
}

sub _gen_email_text {
    my $self = shift;
    my ($settings, $tf, $tries) = @_;

    my $host = hostname();
    my $file = $tf->relative;

    return join "\n\n" => grep { $_ }
        $settings->notify->text,
        "Failed test on $host: '$file'.",
        $tries ? ("Test was run " . (1 + $tries) . " time(s).") : (),
        join "\n" => @{$settings->run->links};
}

sub _send_email {
    my $self = shift;
    my ($subject, $text, $settings, @to) = @_;

    my $mail = Email::Stuffer->to(@to);
    $mail->from($settings->notify->email_from);
    $mail->subject($subject);
    $mail->text_body($text);

    eval { $mail->send_or_die; 1 } or warn $@;
}

sub finish {
    my $self = shift;
    my %params = @_;
    my $settings = $params{settings};

    my $e = $self->{+FINAL} or return;
    my $f = $e->facet_data or return;
    my $final = $f->{harness_final} or return;

    $self->send_run_notification_slack($final, $settings);
    $self->send_run_notification_email($final, $settings);
}

sub send_run_notification_slack {
    my $self = shift;
    my ($final, $settings) = @_;

    my $host = hostname();

    return if $settings->notify->no_batch_slack;

    my @to = @{$settings->notify->slack};
    push @to => @{$settings->notify->slack_fail} unless $final->{pass};

    my $files = "";
    if ($final->{failed}) {
        for my $set (@{$final->{failed}}) {
            my $file = $set->[1];

            $files = $files ? "$files\n$file" : $file;

            next unless $settings->notify->slack_owner;
            my $tf = Test2::Harness::TestFile->new(file => $file);
            push @to => $tf->meta('slack');
        }
    }

    return unless @to;

    my $text = join "\n\n" => grep { $_ } (
        $settings->notify->text,
        ($final->{pass} ? "Tests passed on $host" : "Tests failed on $host"),
        ($files ? $files : ()),
        join("\n" => map {"> <$_|$_>"} @{$settings->run->links}),
    );

    $self->_send_slack($text, $settings, @to);
}

sub send_run_notification_email {
    my $self = shift;
    my ($final, $settings) = @_;

    my $host = hostname();

    return if $settings->notify->no_batch_email;

    my @to = @{$settings->notify->email};
    push @to => @{$settings->notify->email_fail} unless $final->{pass};

    my $files = "";
    if ($final->{failed}) {
        for my $set (@{$final->{failed}}) {
            my $file = $set->[1];

            $files = $files ? "$files\n$file" : $file;

            next unless $settings->notify->email_owner;
            my $tf = Test2::Harness::TestFile->new(file => $file);
            push @to => $tf->meta('owner');
        }
    }

    return unless @to;

    my $subject = $final->{pass} ? "Tests passed on $host" : "Tests failed on $host";

    my $text = join "\n\n" => grep { $_ } (
        $settings->notify->text,
        $subject,
        ($files ? $files : ()),
        join("\n" => @{$settings->run->links}),
    );

    $self->_send_email($subject, $text, $settings, @to);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin::Notify - Plugin to send email and/or slack notifications

=head1 DESCRIPTION

This plugin is used for sending email and/or slack notifications from yath.

=head1 SYNOPSIS

=head2 IN A TEST

    #!/usr/bin/perl
    use Test2::V0;
    # HARNESS-META owner author@example.com
    # HARNESS-META slack #slack_channel
    # HARNESS-META slack #slack_user

You can use the C<# HARNESS-META owner EMAIL_ADDRESS> to specify an "owner"
email address. You can use the C<# HARNESS-META slack USER/CHANNEL> to specify
a slack user or channel that owns the test.

=head2 RUNNING WITH NOTIFICATIONS ENABLED

    $ yath test -pNotify ...

Also of note, most of the time you can just specify the notification options
you want and the plugin will load as needed as long as C<--no-scan-plugins> was
not specified.

=head3 EMAIL

    $ yath test --notify-email-owner --notify-email-from user@example.com --notify-email-fail fixer@example.com

=head3 SLACK

A slack hooks url is always needed for slack to work.

    $ yath test --notify-slack-url https://hooks.slack.com/... --notify-slack-fail '#foo' --notify-slack-owner

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
