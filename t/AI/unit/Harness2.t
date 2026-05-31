use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2;

# Test2::Harness2 is the client-side API: it vivifies a workdir, knows the
# service class, and can start/connect to a harness service.

subtest project_required => sub {
    my $err = dies { Test2::Harness2->new };
    like($err, qr/project/i, "project is required");
};

subtest workdir_vivified => sub {
    my $h = Test2::Harness2->new(project => 'demo');
    ok($h->workdir, "a workdir was chosen");
    ok(-d $h->workdir, "the workdir exists");
    like($h->workdir, qr/demo/, "workdir name includes the project");
};

subtest explicit_workdir => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $wd  = "$dir/wd";
    my $h   = Test2::Harness2->new(project => 'demo', workdir => $wd);
    is($h->workdir, $wd, "uses the given workdir");
    ok(-d $wd, "and creates it");
};

subtest default_service_class => sub {
    my $h = Test2::Harness2->new(project => 'demo');
    is($h->service_class, 'Test2::Harness2::Service::Harness', "default service class");
};

done_testing;
