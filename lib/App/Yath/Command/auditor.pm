package App::Yath::Command::auditor;
use strict;
use warnings;

our $VERSION = '1.000153';

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
sub name            { 'auditor' }

sub run {
    my $self = shift;
    my ($auditor_class, $run_id, %args) = @{$self->{+ARGS}};

    my $name = 'yath-auditor';
    $name = "$args{procname_prefix}-${name}" if $args{procname_prefix};
    $0 = $name;

    my $fh = isolate_stdout();

    require(mod2file($auditor_class));

    my $auditor = $auditor_class->new(
        %args,
        run_id => $run_id,
        action => sub { print $fh defined($_[0]) ? blessed($_[0]) ? $_[0]->as_json . "\n" : encode_json($_[0]) . "\n" : "null\n" },
    );

    local $SIG{PIPE} = 'IGNORE';
    my $ok = eval { $auditor->process(); 1 };
    my $err = $@;

    eval { $auditor->finish(); 1 } or warn $@;

    die $err unless $ok;

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

