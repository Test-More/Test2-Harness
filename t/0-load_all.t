use Test2::V0;
use Test2::IPC qw/cull/;
# HARNESS-JOB-SLOTS

use File::Find;
use Test2::Harness;
use Test2::Harness::Util qw/file2mod/;
use Parallel::Runner;

use Test2::Harness::Util::Deprecated();
$Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 1;

my %SKIP = (
    'lib/Test2/Harness/IPC/Protocol/IPSocket.pm'              => 1,
    'lib/Test2/Harness/IPC/Protocol/IPSocket/Connection.pm'   => 1,
    'lib/Test2/Harness/IPC/Protocol/UnixSocket.pm'            => 1,
    'lib/Test2/Harness/IPC/Protocol/UnixSocket/Connection.pm' => 1,
);

my $runner = Parallel::Runner->new(
    $ENV{T2_HARNESS_MY_JOB_CONCURRENCY} // 2,
    iteration_callback => sub { cull() },
);

my $pid = $$;
find({wanted => \&wanted, no_chdir => 1}, 'lib/');

sub wanted {
    die "LEAK!" unless $$ == $pid;
    my $file = $File::Find::name;
    return unless $file =~ m/\.pm$/;

    return if $SKIP{$file};

    $runner->run(sub {
        local $ENV{T2_HARNESS_PIPE_COUNT} = -1;
        subtest $file => sub {
            $file =~ s{^.*lib/}{}g;
            my @warnings;

            if ($file =~ m{(MySQL|PostgreSQL|SQLite)}) {
                ok(eval { require "App/Yath/Schema/$1.pm" }, "Load necessary schema '$1'", $@);
            }
            elsif ($file =~ m{App/Yath/Schema\.pm$} || $file =~ m{Schema/(Overlay|Result)}) {
                ok(eval { require App::Yath::Schema::PostgreSQL }, "Load schema");
            }

            my $ok = eval { local $SIG{__WARN__} = sub { push @warnings => @_ }; require($file); 1 };
            my $err = $@;
            if ($err =~ m/^Can't locate / || $err =~ m/version \S+ required--this is only version/) {
                skip_all $err;
                return;
            }

            {
                no warnings 'once';
                ok($ok, "require $file (" . ($App::Yath::Schema::LOADED // 'undef') . ")", $ok ? () : $err);
            }
            ok(!@warnings, "No Warnings", @warnings);

            return if $file =~ m{Test2/Harness/UI/Schema};

            my $mod = file2mod($file);
            my $sym = "$mod\::VERSION";
            no strict 'refs';
            is($$sym, $Test2::Harness::VERSION, "Package $mod ($file) has the version number");
        };
    }, 1);
};

$runner->finish();

done_testing;
