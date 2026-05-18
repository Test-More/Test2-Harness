use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;

use App::Yath2::Log;
use App::Yath2::Concluder::Notify;

# A tiny mock settings object that satisfies check_group + per-group
# accessors. The real $settings carries a full Getopt::Yath stack we do
# not want to construct in a unit test.
{

    package T::FakeSettings;

    sub new {
        my ($class, %g) = @_;
        return bless {groups => \%g}, $class;
    }

    sub check_group {
        my ($self, $g) = @_;
        return exists $self->{groups}{$g} ? 1 : 0;
    }
    sub notify { $_[0]->{groups}{notify} }
}
{

    package T::FakeNotify;

    sub new {
        my ($class, %a) = @_;
        my %defaults = (
            email       => [],
            email_fail  => [],
            email_owner => 0,
            slack       => [],
            slack_fail  => [],
            slack_owner => 0,
        );
        my %merged = (%defaults, %a);
        return bless \%merged, $class;
    }
    sub email       { $_[0]->{email} }
    sub email_fail  { $_[0]->{email_fail} }
    sub email_owner { $_[0]->{email_owner} }
    sub slack       { $_[0]->{slack} }
    sub slack_fail  { $_[0]->{slack_fail} }
    sub slack_owner { $_[0]->{slack_owner} }
}

sub _empty_log {
    my $dir = tempdir(CLEANUP => 1);
    return App::Yath2::Log->new(dir => $dir);
}

sub _log_with_run {
    my (%p) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs/1/jobs/j1/0");

    open my $sp, '>', "$dir/runs/1/jobs/j1/0/spec.jsonl" or die "spec: $!";
    close $sp;

    open my $js, '>', "$dir/runs/1/jobs/j1/0/.sealed" or die "job seal: $!";
    print $js encode_json({
        sealed_at => 200, final_state => 'completed',
        pass      => $p{pass} // 1,
    });
    close $js;

    open my $rs, '>', "$dir/runs/1/.sealed" or die "run seal: $!";
    print $rs encode_json({
        sealed_at => 300, final_state => 'completed',
        pass      => $p{pass} // 1,
        exit      => $p{pass} ? 0 : 1,
    });
    close $rs;

    return App::Yath2::Log->new(dir => $dir);
}

subtest 'no settings group: silent no-op' => sub {
    my $c          = App::Yath2::Concluder::Notify->new(log => _empty_log());
    my $stderr_buf = '';
    {
        local *STDERR;
        open *STDERR, '>', \$stderr_buf;
        $c->run;
    }
    is($stderr_buf, '', 'silent when no settings group attached');
};

subtest 'group present but no channels: no-op' => sub {
    my $s = T::FakeSettings->new(notify => T::FakeNotify->new);
    my $c = App::Yath2::Concluder::Notify->new(log => _empty_log(), settings => $s);

    my $stderr_buf = '';
    {
        local *STDERR;
        open *STDERR, '>', \$stderr_buf;
        $c->run;
    }
    is($stderr_buf, '', 'silent when no channels configured');
};

subtest 'email + slack channels emit stub lines' => sub {
    my $s = T::FakeSettings->new(
        notify => T::FakeNotify->new(
            email => ['a@example.com', 'b@example.com'],
            slack => ['#chan',         '@user'],
        )
    );

    my $c = App::Yath2::Concluder::Notify->new(
        log      => _log_with_run(pass => 1),
        settings => $s,
    );

    my $stderr_buf = '';
    {
        local *STDERR;
        open *STDERR, '>', \$stderr_buf;
        $c->run;
    }

    like($stderr_buf, qr/NOTIFY: email:a\@example\.com .*PASSED/, 'email channel line');
    like($stderr_buf, qr/NOTIFY: email:b\@example\.com .*PASSED/, 'second email');
    like($stderr_buf, qr/NOTIFY: slack:#chan .*PASSED/,           'slack #chan line');
    like($stderr_buf, qr/NOTIFY: slack:\@user .*PASSED/,          'slack @user line');
};

subtest 'owner toggles emit channel lines' => sub {
    my $s = T::FakeSettings->new(
        notify => T::FakeNotify->new(
            email_owner => 1,
            slack_owner => 1,
        )
    );

    my $c = App::Yath2::Concluder::Notify->new(
        log      => _log_with_run(pass => 0),
        settings => $s,
    );

    my $stderr_buf = '';
    {
        local *STDERR;
        open *STDERR, '>', \$stderr_buf;
        $c->run;
    }

    like($stderr_buf, qr/NOTIFY: email:owner .*FAILED/, 'email owner line, fail summary');
    like($stderr_buf, qr/NOTIFY: slack:owner .*FAILED/, 'slack owner line, fail summary');
};

done_testing;
