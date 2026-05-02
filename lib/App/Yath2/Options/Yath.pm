package App::Yath2::Options::Yath;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util qw/find_libraries mod2file fqmod/;
use Test2::Harness2::Util qw/clean_path/;
use App::Yath::Script qw/find_in_updir/;

use Cwd();
use File::Spec();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Harness',
);

option_group {group => 'yath', category => 'Yath Options'} => sub {
    option project => (
        type        => 'Scalar',
        alt         => ['project-name'],
        description => 'Label for your current project/codebase. Best set in a .yath.rc file. Defaults via the fallback chain documented in App::Yath2::Options::Yath.',
    );

    option user => (
        type => 'Scalar',
        description => 'Username to associate with logs, database entries, and yath servers.',
        from_env_vars => [qw/YATH_USER USER/],
    );

    option base_dir => (
        type        => 'Scalar',
        description => "Root directory for the project being tested (usually where .yath.rc lives)",
        default     => sub {
            for my $dfile ('.yath.rc', '.yath.user.rc', '.git', '.svn', '.cvs') {
                my $base_file = find_in_updir($dfile) or next;
                my ($v, $d) = File::Spec->splitpath($base_file);
                return clean_path(File::Spec->catpath($v, $d));
            }

            return clean_path(Cwd::getcwd());
        },
    );

    option 'show-opts' => (
        type => 'Auto',
        autofill => 1,
        description => 'Exit after showing what yath thinks your options mean',
        short_examples => ['', '=group'],
        long_examples  => ['', '=group'],
    );

    option version => (
        type => 'Bool',
        short       => 'V',
        description => "Exit after showing a helpful usage message",
    );

    option scan_options => (
        type => 'BoolMap',

        clear => sub { {options => 0} },
        pattern => qr/scan-(.+)/,

        description => 'Yath will normally scan plugins for options. Some commands scan other libraries (finders, resources, renderers, etc) for options. You can use this to disable all scanning, or selectively disable/enable some scanning.',
        notes => 'This is parsed early in the argument processing sequence, before options that may be earlier in your argument list.',
    );

    my $INC_SEEN;
    option dev_libs => (
        type        => 'AutoPathList',
        short       => 'D',
        name        => 'dev-lib',

        autofill => sub { map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch' },

        description => 'This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',
        notes => "This option can cause yath to use exec() to reload itself with the correct libraries in place. Each occurence of this argument can cause an additional exec() call. Use --dev-libs-verbose BEFORE any -D calls to see the exec() calls.",

        long_examples  => ['', '=lib', '="lib/*"'],
        short_examples => ['', 'lib', '=lib', 'lib', '"lib/*"'],

        trigger => sub {
            my $opt = shift;
            my %params = @_;
            return unless $params{action} eq 'set';

            $INC_SEEN //= {map {($_ => 1, clean_path($_) => 1)} @INC};

            my @missing;
            for my $lib (@{$params{val}}) {
                next if $INC_SEEN->{$lib} || $INC_SEEN->{clean_path($lib)};
                push @missing => $lib;
            }

            return unless @missing;

            my $settings = $params{settings};
            if ($settings->yath->dev_libs_verbose) {
                print STDERR "Developer library paths were specified but missing from \@INC... re-launching yath with proper include paths...\n";
                print STDERR "  -> $_\n" for @missing;
                print STDERR "\n";
            }

            my %default = map {($_ => 1, clean_path($_) => 1)} grep { $_ } split /\n/, `$^X -e 'print "\$_\n" for \@INC'`;
            my @add = map { "-I$_" } grep { !$default{$_} } map {clean_path($_)} @INC, @missing;
            exec($^X, @add, $settings->yath->script, @{$settings->yath->orig_argv // []});
        },

        normalize => \&clean_path,
    );

    option dev_libs_verbose => (
        type => 'Bool',
        default => 0,
        description => 'Be verbose and announce that yath will re-exec in order to have the correct includes (normally yath will just call exec() quietly)',
    );

    option help => (
        type           => 'Auto',
        autofill       => 1,
        short          => 'h',
        description    => "exit after showing help information",
        short_examples => ['', '=Group'],
        long_examples  => ['', '=Group'],
    );

    option plugins => (
        type  => 'Map',
        short => 'p',
        alt   => ['plugin'],

        description      => 'Load a yath plugin.',
        mod_adds_options => 1,

        normalize => sub {
            my ($class, $args) = @_;

            $class = fqmod($class, 'App::Yath2::Plugin');

            $args = $args ? [split ',', $args] : [];

            return $class => $args;
        },
    );
};

# Project-name fallback chain. Fires only when --project (or
# .yath.rc's project field) was not set. In order:
#
#   1. Final component of the directory holding the active .yath.rc
#      / .yath.user.rc (or any versioned variant). The rc-file paths
#      are already resolved by App::Yath::Script::V2::do_begin and
#      handed in via $settings->yath->config_file /
#      user_config_file.
#
#   2. Walk-up from cwd looking for one of .git, .svn, .cvs, lib, or
#      t. Stop at $HOME or '/' (do not count either as a project
#      dir). The walk only visits cwd, ../, ../../, etc; we do not
#      descend into subdirectories.
#
#   3. The basename of the current directory itself.
#
#   4. The literal sentinel '__UNKNOWN__' when cwd is '/' or '$HOME'.
option_post_process 0 => sub {
    my ($options, $state) = @_;
    my $settings = $state->{settings};
    return if defined $settings->yath->project && length $settings->yath->project;

    $settings->yath->create_option(project => _resolve_project_name($settings));
    return;
};

sub _resolve_project_name {
    my ($settings) = @_;

    for my $rc_field (qw/config_file user_config_file/) {
        my $path = $settings->yath->$rc_field;
        next unless defined $path && length $path;
        my ($v, $d) = File::Spec->splitpath($path);
        my $dir = clean_path(File::Spec->catpath($v, $d));
        my $name = _basename_or_undef($dir);
        return $name if defined $name;
    }

    my $cwd  = clean_path($settings->yath->cwd // Cwd::getcwd());
    my $home = defined $ENV{HOME} ? clean_path($ENV{HOME}) : undef;

    return '__UNKNOWN__'
        if $cwd eq '/'
        || (defined $home && $cwd eq $home);

    if (my $found = _walk_up_for_project($cwd, $home)) {
        return $found;
    }

    return _basename_or_undef($cwd) // '__UNKNOWN__';
}

# Walk cwd / ../ / ../../ / ... looking for any project marker:
# .git, .svn, .cvs, lib, t. Stops one step before $HOME or '/'.
# Returns the basename of the matching directory, or undef.
sub _walk_up_for_project {
    my ($start, $home) = @_;

    my %seen;
    my $dir = $start;
    while (1) {
        last unless defined $dir && length $dir;
        last if $seen{$dir}++;
        last if $dir eq '/';
        last if defined $home && $dir eq $home;

        for my $marker (qw/.git .svn .cvs lib t/) {
            if (-e File::Spec->catfile($dir, $marker)) {
                return _basename_or_undef($dir);
            }
        }

        my $up = clean_path(File::Spec->catdir($dir, File::Spec->updir));
        last if $up eq $dir;
        $dir = $up;
    }

    return undef;
}

sub _basename_or_undef {
    my ($dir) = @_;
    return undef unless defined $dir && length $dir;
    my @parts = grep { length } File::Spec->splitdir($dir);
    return undef unless @parts;
    return $parts[-1];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Yath - Core yath options

=head1 DESCRIPTION

Core yath command options.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
