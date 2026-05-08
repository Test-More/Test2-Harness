use Test2::V0;

use File::Spec;

use App::Yath::Tester qw/yath/;

use App::Yath::Util qw/find_yath/;
find_yath();

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $hook_dir = File::Spec->rel2abs($dir);
my $target   = File::Spec->catfile($hook_dir, 'simple.tx');

# Each fixture injects one of the three @INC hook forms documented in
# perlvar "@INC": blessed object, coderef, arrayref. Without filtering,
# the ref would be snapshotted into settings->harness->orig_inc, crash
# JSON encoding in write_settings_to, and inject "HASH(0x...)" /
# "CODE(0x...)" / "ARRAY(0x...)" garbage paths into child -I flags.
my @cases = (
    {
        name   => 'blessed object hook',
        module => 'FakeHook',
        ref_re => qr/FakeHook=HASH\(/,
    },
    {
        name   => 'coderef hook',
        module => 'CoderefHook',
        ref_re => qr{/CODE\(0x},
    },
    {
        name   => 'arrayref hook',
        module => 'ArrayrefHook',
        ref_re => qr{/ARRAY\(0x},
    },
);

for my $case (@cases) {
    yath(
        command => 'test',
        args    => [$target],
        env     => {
            PERL5OPT => "-I$hook_dir -M$case->{module}",
        },
        exit    => 0,
        test    => sub {
            my $out = shift;
            unlike(
                $out->{output},
                qr/encountered object/,
                "$case->{name}: no JSON encode error",
            );
            unlike(
                $out->{output},
                $case->{ref_re},
                "$case->{name}: no stringified ref leaked into output",
            );
        },
    );
}

done_testing;
