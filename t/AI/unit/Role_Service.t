use v5.38;
use Test2::V0;

{
    package My::Svc;
    use v5.38;
    use Object::HashBase qw{ -ticks -started -stopped };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub on_start ($self) { $self->{+STARTED} = 1 }
    sub on_stop  ($self) { $self->{+STOPPED} = 1 }

    sub tick ($self) {
        $self->{+TICKS}++;
        return 1 if $self->{+TICKS} < 3;   # did work twice
        return 0;                          # then idle
    }

    sub should_stop ($self) { ($self->{+TICKS} // 0) >= 3 ? 1 : 0 }
}

my $svc = My::Svc->new;
$svc->run;
is($svc->started, 1, "on_start fired");
is($svc->stopped, 1, "on_stop fired");
is($svc->ticks, 3, "looped until should_stop");

done_testing;
