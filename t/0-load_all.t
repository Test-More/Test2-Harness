use Test2::V0;
use Test2::IPC;

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

my $pid = $$;
find({wanted => \&wanted, no_chdir => 1}, 'lib/');

sub wanted {
    die "LEAK!" unless $$ == $pid;
    my $file = $File::Find::name;
    return unless $file =~ m/\.pm$/;

    return if $SKIP{$file};

    my $pid = fork;
    if ($pid) {
        waitpid($pid, 0);
        ok(!$?, "Subprocess exited cleanly");
        return;
    }
    else {
        local $ENV{T2_HARNESS_PIPE_COUNT} = -1;
        subtest $file => sub {
            $file =~ s{^.*lib/}{}g;
            my @warnings;

            if ($file =~ m{Schema/(MySQL|PostgreSQL|SQLite)/}) {
                ok(eval { require "Test2/Harness/UI/Schema/$1.pm" }, "Load necessary schema '$1'", $@);
            }
            elsif ($file =~ m{UI/Schema\.pm$} || $file =~ m{Schema/(Overlay|Result)}) {
                ok(eval { require Test2::Harness::UI::Schema::PostgreSQL }, "Load schema");
            }

            my $ok = eval { local $SIG{__WARN__} = sub { push @warnings => @_ }; require($file); 1 };
            my $err = $@;
            {
                no warnings 'once';
                ok($ok, "require $file (" . ($Test2::Harness::UI::Schema::LOADED // 'undef') . ")", $ok ? () : $err);
            }
            ok(!@warnings, "No Warnings", @warnings);

            my $mod = file2mod($file);
            my $sym = "$mod\::VERSION";
            no strict 'refs';
            is($$sym, $Test2::Harness::VERSION, "Package $mod ($file) has the version number");
        };

        exit(0);
    }
};

done_testing;
