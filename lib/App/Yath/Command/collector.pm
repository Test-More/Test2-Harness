package App::Yath::Command::collector;
use strict;
use warnings;

our $VERSION = '1.000043';

use File::Spec;

use App::Yath::Util qw/isolate_stdout/;

use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Run;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only   { 1 }
sub summary         { "For internal use only" }
sub name            { 'collector' }

sub run {
    my $self = shift;
    my ($collector_class, $dir, $run_id, $runner_pid, %args) = @{$self->{+ARGS}};

    $0 = 'yath-collector';

    my $fh = isolate_stdout();

    my $settings = Test2::Harness::Settings->new(File::Spec->catfile($dir, 'settings.json'));

    require(mod2file($collector_class));

    my $run = Test2::Harness::Run->new(%{decode_json(<STDIN>)});

    my $collector = $collector_class->new(
        %args,
        settings   => $settings,
        workdir    => $dir,
        run_id     => $run_id,
        runner_pid => $runner_pid,
        run        => $run,
        # as_json may already have the json form of the event cached, if so
        # we can avoid doing an extra call to encode_json
        action => sub { print $fh defined($_[0]) ? $_[0]->as_json . "\n" : "null\n"; },
    );

    local $SIG{PIPE} = 'IGNORE';
    my $ok = eval { $collector->process(); 1 };
    my $err = $@;

    eval { print $fh "null\n"; 1 } or warn $@;

    die $err unless $ok;

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

