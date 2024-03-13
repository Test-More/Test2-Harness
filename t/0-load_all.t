use Test2::V0;

use File::Find;
use Test2::Harness;
use Test2::Harness::Util qw/file2mod/;

use Test2::Harness::Util::Deprecated();
$Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 1;

my %SKIP = (
    'lib/Test2/Harness/IPC/Protocol/IPSocket.pm'              => 1,
    'lib/Test2/Harness/IPC/Protocol/IPSocket/Connection.pm'   => 1,
    'lib/Test2/Harness/IPC/Protocol/UnixSocket.pm'            => 1,
    'lib/Test2/Harness/IPC/Protocol/UnixSocket/Connection.pm' => 1,
);

find(\&wanted, 'lib/');

sub wanted {
    my $file = $File::Find::name;
    return unless $file =~ m/\.pm$/;

    return if $SKIP{$file};

    subtest $file => sub {
        $file =~ s{^.*lib/}{}g;
        my @warnings;
        my $ok = eval { local $SIG{__WARN__} = sub { push @warnings => @_ }; require($file); 1 };
        my $err = $@;
        ok($ok, "require $file", $ok ? () : $err);
        ok(!@warnings, "No Warnings", @warnings);

        my $mod = file2mod($file);
        my $sym = "$mod\::VERSION";
        no strict 'refs';
        is($$sym, $Test2::Harness::VERSION, "Package $mod ($file) has the version number");
    };
};

done_testing;
