use Test2::V0;
require Role::Tiny;
require App::Yath2::Role::Log;

my $info = $Role::Tiny::INFO{'App::Yath2::Role::Log'} || {};
my %req  = map { $_ => 1 } @{ $info->{requires} // [] };

for my $m (qw/run_producers job_producers service_producers collector_producers/) {
    ok($req{$m}, "Role::Log requires $m");
}

done_testing;
