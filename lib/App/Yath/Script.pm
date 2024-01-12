package App::Yath::Script;
use strict;
use warnings;

our $VERSION = '2.000000';

use Cwd;
use File::Spec;
use Time::HiRes qw/time/;
use Test2::Harness::Util::Minimal qw/pre_process_args find_in_updir scan_config clean_path/;

sub script { $App::Yath::Script::SCRIPT }

$Test2::Harness::Util::Minimal::USING_ALT //= 0;
sub goto_alt_script {
    my ($app_name, $curr_path, $check_path) = @_;

    my @caller0 = caller(0);
    my @caller1 = caller(1);

    die "goto_alt_script() must be called in a BEGIN block at $caller0[1] line $caller0[2].\n" unless @caller1 && $caller1[3] && $caller1[3] =~ m/BEGIN/;
    die "goto_alt_script() must be called in package 'main' at $caller0[1] line $caller0[2].\n" unless @caller0 && $caller0[0] && $caller0[0] eq 'main';

    return unless -e $check_path;
    return unless -x $check_path;

    return if clean_path($curr_path) eq clean_path($check_path);

    # Unlikely, but if any logic above is broken it can happen
    die "Recursion detected when using alternate $app_name script" if $Test2::Harness::Util::Minimal::USING_ALT++;

    print "\n *** Found alternate $app_name script in '$check_path', switching to it ***\n\n";

    require goto::file;
    goto::file->import($check_path);
}

sub run {
    my ($script, $argv) = @_;

    $App::Yath::Script::SCRIPT //= clean_path($script);

    $argv //= [];

    my $settings_data = args_to_settings_data($argv);

    setup_env(
        sys_tmp => $settings_data->{yath}->{orig_tmp},
        prefix  => $settings_data->{harness}->{procname_prefix},
    );

    # This also loads App::Yath and Getopt::Yath::Settings;
    setup_inc($settings_data->{yath}->{dev_libs} //= []);

    my $script_version = $VERSION;
    my $app_version    = $App::Yath::VERSION;
    die "yath script ($App::Yath::Script::SCRIPT) has a different version than App::Yath ($INC{'App/Yath.pm'})\n     Script: $script_version\n  App::Yath: $app_version\n\n"
        unless $script_version == $app_version;

    my $settings = Getopt::Yath::Settings->new(%$settings_data);

    my $app = App::Yath->new(
        settings => $settings,
        argv     => $argv,
    );

    return $app->run();
}

sub args_to_settings_data {
    my ($argv) = @_;

    my $orig_argv      = [@$argv];
    my $orig_tmp       = File::Spec->tmpdir();
    my $orig_tmp_perms = ((stat($orig_tmp))[2] & 07777);
    my $orig_inc       = [@INC];
    my $orig_sig       = {%SIG};

    my $config_file      = find_in_updir('.yath.rc');
    my $user_config_file = find_in_updir('.yath.user.rc');

    my $dev_libs = [];
    my $prefix;

    for my $list ($argv, map { scan_config($_) } grep { $_ && -e $_ } $user_config_file, $config_file) {
        my $parsed = pre_process_args($list);
        push @{$dev_libs} => @{$parsed->{dev_libs}};
        $prefix = $parsed->{prefix} if defined($parsed->{prefix}) && length($parsed->{prefix});
    }

    $prefix //= 'yath';
    $prefix .= "-yath" unless $prefix =~ m/(-|\b)yath(-|\b)/;

    my $base_file = $config_file || $user_config_file;
    unless ($base_file) {
        for my $scm ('.git', '.svn', '.cvs') {
            $base_file = find_in_updir($scm);
            last if $base_file;
        }
    }

    my $cwd = clean_path(Cwd::getcwd());

    my $base_dir;
    if ($cwd) {
        my ($v, $d) = File::Spec->splitpath($cwd);
        $base_dir = clean_path(File::Spec->catpath($v, $d));
    }

    return {
        yath => {
            script => clean_path(__FILE__),

            script_version => $VERSION,

            scan_options => {},

            config_file      => $config_file      || '',
            user_config_file => $user_config_file || '',

            base_dir  => $base_dir,
            dev_libs  => $dev_libs,
            new_argv  => $argv,
            orig_argv => $orig_argv,
            orig_inc  => $orig_inc,
            orig_tmp  => $orig_tmp,

            orig_tmp_perms => $orig_tmp_perms,

            cwd   => $cwd,
            start => time(),
        },
        harness => {
            procname_prefix => $prefix,
        },
    };
}

sub setup_env {
    my %params = @_;

    my $sys_tmp = $params{sys_tmp};
    my $prefix  = $params{prefix};

    $ENV{T2_HARNESS_PROC_PREFIX} = $prefix;
    $ENV{SYSTEM_TMPDIR} //= $sys_tmp;
}

sub setup_inc {
    my ($dev_libs) = @_;

    my %seen = map { ($_ => 1) } @INC;
    unshift @INC => grep { !$seen{$_}++ } @$dev_libs;

    # Reload Test2::Harness::Util::Minimal with @INC set up.
    Test2::Harness::Util::Minimal::RELOAD();

    require Getopt::Yath::Settings;
    require App::Yath;

    # Make sure yath module paths are in dev_libs
    push @$dev_libs => grep { !$seen{$_}++ } map { $INC{$_} =~ m{^(.*)\Q$_\E$} ? clean_path($1) : () } 'App/Yath.pm', 'Getopt/Yath/Settings.pm';
}

1;
