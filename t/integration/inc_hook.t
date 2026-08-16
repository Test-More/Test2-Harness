use Test2::V0;

use File::Spec;
use File::Temp qw/tempdir/;

use App::Yath::Tester qw/yath/;

use App::Yath::Util qw/find_yath/;
find_yath();    # cache result before we chdir

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $hook_dir = File::Spec->rel2abs($dir);
my $target   = File::Spec->catfile($hook_dir, 'simple.tx');

# Run where the rc search, which walks up from cwd, finds no .yath.rc, keeping
# the project rc's -D and -I settings out of the @INC this file inspects.
chdir(tempdir(CLEANUP => 1, TMPDIR => 1)) or die "Could not chdir to a temp dir: $!";

# One fixture per @INC hook form documented in perlvar "@INC". Unfiltered, the
# blessed hook aborts the run when the settings are JSON encoded, and all three
# reach child -I flags as nonexistent 'CODE(0x...)' style paths.
my @cases = (
    {name => 'blessed object hook', module => 'FakeHook',     ref_re => qr/FakeHook=HASH\(/},
    {name => 'coderef hook',        module => 'CoderefHook',  ref_re => qr{/CODE\(0x}},
    {name => 'arrayref hook',       module => 'ArrayrefHook', ref_re => qr{/ARRAY\(0x}},
);

for my $case (@cases) {
    yath(
        command => 'test',
        args    => ['-v', $target],
        env     => {PERL5OPT => "-I$hook_dir -M$case->{module}"},
        exit    => 0,
        test    => sub {
            my $out = shift;

            unlike($out->{output}, qr/encountered object|JSON can only represent/, "$case->{name}: no JSON encode error");

            unlike($out->{output}, $case->{ref_re}, "$case->{name}: no stringified hook in the reported \@INC");
        },
    );
}

done_testing;
