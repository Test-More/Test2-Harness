package App::Yath::Script;
use strict;
use warnings;

our $VERSION = '2.000005';

use Cwd;
use File::Spec;
use Time::HiRes qw/time/;
use Test2::Harness::Util qw/find_in_updir clean_path/;
use Getopt::Yath::Settings;
use App::Yath;

sub script { $App::Yath::Script::SCRIPT }

$Test2::Harness::Util::USING_ALT //= 0;
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
    die "Recursion detected when using alternate $app_name script" if $Test2::Harness::Util::USING_ALT++;

    print "\n *** Found alternate $app_name script in '$check_path', switching to it ***\n\n";

    require goto::file;
    goto::file->import($check_path);
}

sub run {
    my ($script, $argv) = @_;

    $script = clean_path($script);
    $App::Yath::Script::SCRIPT //= $script;

    $argv //= [];

    my $settings_data = args_to_settings_data($script, $argv);

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
    my ($script, $argv) = @_;

    my $orig_argv      = [@$argv];
    my $orig_tmp       = File::Spec->tmpdir();
    my $orig_tmp_perms = ((stat($orig_tmp))[2] & 07777);
    my $orig_inc       = [@INC];
    my $orig_sig       = {%SIG};

    my $config_file      = find_in_updir('.yath.rc');
    my $user_config_file = find_in_updir('.yath.user.rc');

    my $base_file = $config_file || $user_config_file;
    unless ($base_file) {
        for my $scm ('.git', '.svn', '.cvs') {
            $base_file = find_in_updir($scm);
            last if $base_file;
        }
    }

    my $cwd = clean_path(Cwd::getcwd());

    my $base_dir;
    if ($base_file) {
        my ($v, @d) = File::Spec->splitpath($base_file);
        pop @d;
        $base_dir = clean_path(File::Spec->catpath($v, @d));
    }
    elsif ($cwd) {
        my ($v, @d) = File::Spec->splitpath($cwd);
        $base_dir = clean_path(File::Spec->catpath($v, @d));
    }

    $ENV{SYSTEM_TMPDIR} = $orig_tmp;

    return {
        yath => {
            script => $script,

            script_version => $VERSION,

            scan_options => {},

            config_file      => $config_file      || '',
            user_config_file => $user_config_file || '',

            base_dir  => $base_dir,
            new_argv  => $argv,
            orig_argv => $orig_argv,
            orig_inc  => $orig_inc,
            orig_tmp  => $orig_tmp,

            orig_tmp_perms => $orig_tmp_perms,

            cwd   => $cwd,
            start => time(),
        },
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

