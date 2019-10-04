use Test2::V0;

__END__

package App::Yath::Command::collector;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec;

use Test2::Harness::Util qw/mod2file/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub internal_only   { 1 }
sub summary         { "For internal use only" }
sub name            { 'runner' }

sub run {
    my $self = shift;
    my ($collector_class, $dir, $run_id, %args) = @{$self->{+ARGS}};

    $0 = 'yath-collector';

    select STDERR;
    open(my $fh, '>&', STDOUT) or die "Could not clone STDOUT: $!";
    open(STDOUT, '>&', STDERR) or die "Could not redirect STDOUT to STDERR: $!";

    my $settings = App::Yath::Settings->new(File::Spec->catfile($dir, 'settings.json'));

    require(mod2file($collector_class));

    my $collector = $collector_class->new(
        %args,
        settings => $settings,
        workdir  => $dir,
        run_id   => $run_id,
        # as_json may already have the json form of the event cached, if so
        # we can avoid doing an extra call to encode_json
        action => sub { print $fh $_[0]->as_json },
    );

    local $SIG{PIPE} = 'IGNORE';
    my $ok = eval { $collector->run(); 1 };
    my $err = $@;

    eval { print $fh "null\n"; 1 } or warn $@;

    die $err unless $ok;

    return 0;
}

1;
