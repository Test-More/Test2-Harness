use Test2::V0 -target => 'Test2::Harness::Util::Minimal';

use Test2::Tools::GenTemp qw/gen_temp/;
use Cwd qw/cwd/;

use File::Spec;

use Test2::Harness::Util::Minimal qw{
    clean_path
    find_in_updir
    pre_process_args
    scan_config
};

imported_ok qw{
    clean_path
    find_in_updir
    pre_process_args
    scan_config
};

my $initial_dir = cwd();

subtest find_in_updir => sub {
    my $tmp = gen_temp(
        thefile => 'xxx',
        nest => {
            nest_a => { thefile => 'xxx' },
            nest_b => {},
        },
    );

    chdir(File::Spec->catdir($tmp, 'nest', 'nest_a')) or die "$!";
    my $file = File::Spec->catfile($tmp, 'nest', 'nest_a', 'thefile');
    like(find_in_updir('thefile'), qr{\Q$file\E$}, "Found file in expected spot");

    chdir(File::Spec->catdir($tmp, 'nest', 'nest_b')) or die "$!";
    $file = File::Spec->catfile($tmp, 'thefile');
    like(find_in_updir('thefile'), qr{\Q$file\E$}, "Found file in expected spot");

    chdir($initial_dir);
};

done_testing;
