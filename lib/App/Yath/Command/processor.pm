package App::Yath::Command::processor;
use strict;
use warnings;

our $VERSION = '1.000043';

use File::Spec;
use Scalar::Util qw/blessed/;

use App::Yath::Util qw/isolate_stdout/;

use Test2::Harness::Util::JSON qw/decode_json encode_json/;
use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::Run;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only   { 1 }
sub summary         { "For internal use only" }
sub name            { 'processor' }

sub run {
    my $self = shift;
    my ($processor_class, $dir, $run_id, $runner_pid, %args) = @{$self->{+ARGS}};

    $0 = 'yath-processor';

    my $fh = isolate_stdout();

    my $settings = Test2::Harness::Settings->new(File::Spec->catfile($dir, 'settings.json'));

    require(mod2file($processor_class));

    my ($run_json, $job_json) = <STDIN>;
    my $run = Test2::Harness::Run->new(%{decode_json($run_json)});
    my $job = decode_json($job_json);

    $0 = 'yath-processor ' . $job->{file};

    my $processor = $processor_class->new(
        %args,
        settings   => $settings,
        workdir    => $dir,
        run_id     => $run_id,
        runner_pid => $runner_pid,
        run        => $run,
        job        => $job,

        action => sub { print $fh defined($_[0]) ? blessed($_[0]) ? $_[0]->as_json . "\n" : encode_json($_[0]) . "\n" : "null\n" },
    );

    local $SIG{PIPE} = 'IGNORE';
    my $ok = eval { $processor->process(); 1 };
    my $err = $@;

    eval { print $fh "null\n"; 1 } or warn $@;

    die $err unless $ok;

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

