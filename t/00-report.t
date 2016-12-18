use Test2::Tools::Basic;
use Test2::Util::Table qw/table/;
use Test2::Harness::Parser::EventStream;

use Test2::Util qw/CAN_FORK CAN_REALLY_FORK CAN_THREAD/;

diag "\nDIAGNOSTICS INFO IN CASE OF FAILURE:\n";
diag(join "\n", table(rows => [[ 'perl', $] ]]));

diag(
    join "\n",
    table(
        header => [qw/CAPABILITY SUPPORTED/],
        rows   => [
            ['CAN_FORK',        CAN_FORK        ? 'Yes' : 'No'],
            ['CAN_REALLY_FORK', CAN_REALLY_FORK ? 'Yes' : 'No'],
            ['CAN_THREAD',      CAN_THREAD      ? 'Yes' : 'No'],
        ],
    )
);

diag(
    join "\n",
    table(
        header => ['USE JSON', 'VERSION'],
        rows   => [
            [ Test2::Harness::Parser::EventStream->JSON, Test2::Harness::Parser::EventStream->JSON->VERSION ],
        ],
    )
);


{
    my @depends = qw{
        Test2 Test2::Suite Test2::AsyncSubtest B Carp File::Spec File::Temp
        List::Util PerlIO Scalar::Util Storable Test::Harness overload utf8
        IO::Handle File::Find Getopt::Long IPC::Open3 POSIX Symbol
        Term::ANSIColor Time::HiRes JSON::MaybeXS Win32::Console::ANSI JSON::PP
        JSON::XS Cpanel::JSON::XS IO::Tty IO::Pty
    };

    my @rows;
    for my $mod (sort @depends) {
        my $installed = eval "require $mod; $mod->VERSION";
        push @rows => [ $mod, $installed || "N/A" ];
    }

    my @table = table(
        header => [ 'DEPENDENCY', 'VERSION' ],
        rows => \@rows,
    );

    diag(join "\n", @table);
}

pass;
done_testing;
