package App::Yath::Script;
use strict;
use warnings;

use Cwd qw/realpath/;
use Carp qw/confess/;
use File::Spec();

use Importer Importer => 'import';

our @EXPORT_OK = (
    qw{
        script
        module

        do_exec

        clean_path
        find_in_updir
        find_rc_updir
        mod2file
    },
);

our $VERSION = '2.000011';

our ($SCRIPT, $MOD);

sub script { $SCRIPT }
sub module { $MOD }

sub do_begin {
    # Check for an explicit version as the very first argument (V# or v#).
    # Strip it from @ARGV before anything else sees it.
    my $cli_version;
    if (@ARGV && $ARGV[0] =~ /^[Vv](\d+)$/) {
        $cli_version = int($1);
        shift @ARGV;
    }

    my $argv = [@ARGV];
    my @caller = caller();

    my $exec = 0;

    $SCRIPT = clean_path($caller[1]);
    $ENV{YATH_SCRIPT} = $SCRIPT;

    inject_includes();

    $exec = 1 if seed_hash();
    $exec = 1 if find_alt_script();
    $exec = 1 if parse_new_dev_libs();

    do_exec($argv) if $exec;

    my $version;
    my ($config, $user_config);

    if (defined $cli_version) {
        # Explicit version on CLI -- only look for versioned RC files.
        # Accept both .yath.v#.rc and .yath.V#.rc.
        $config      = find_in_updir(".yath.v${cli_version}.rc")      // find_in_updir(".yath.V${cli_version}.rc");
        $user_config = find_in_updir(".yath.user.v${cli_version}.rc") // find_in_updir(".yath.user.V${cli_version}.rc");
        $version     = $cli_version;
    }
    else {
        my $config_version;
        ($config, $config_version) = find_rc_updir('.yath');

        my $user_version;
        ($user_config, $user_version) = find_rc_updir('.yath.user');

        # .yath.user(.v#).rc version takes precedence over .yath(.v#).rc
        $version = $user_version // $config_version;
    }

    if (defined $version) {
        warn "Warning: Version '0' is for validating the yath script only, it should not be used for any real testing.\n"
            if $version == 0;

        $MOD = "App::Yath::Script::V${version}";

        my $file = mod2file($MOD);
        eval { require $file; 1 } or die "Could not load $MOD: $@";
    }
    else {
        # No config file found -- scan @INC for available V# modules and
        # try the highest version first so we default to the latest.
        my %found;
        for my $inc (@INC) {
            next if ref $inc;
            my $dir = File::Spec->catdir($inc, 'App', 'Yath', 'Script');
            next unless -d $dir;
            opendir(my $dh, $dir) or next;
            for my $entry (readdir $dh) {
                $found{$1} = 1 if $entry =~ /^V(\d+)\.pm$/;
            }
            closedir $dh;
        }

        # V0 is for script validation only, never auto-select it
        delete $found{0};

        my @err;
        for my $v (sort { $b <=> $a } keys %found) {
            my $mod = "App::Yath::Script::V${v}";

            my $file = mod2file($mod);
            if (eval { require $file; 1 }) {
                $MOD = $mod;
                last;
            }

            push @err => $@;
        }

        die join "\n" => (
            "No Test2::Harness (App::Yath) versions appear to be installed...",
            @err,
        ) unless $MOD;
    }

    die "Could not find a App::Yath::Script::V{X} module to use...\n"
        unless $MOD;

    $MOD->do_begin(
        script      => $SCRIPT,
        argv        => $argv,
        config      => $config,
        user_config => $user_config,
    );
}

sub do_runtime { $MOD->do_runtime(@_) }

sub do_exec {
    my ($argv) = @_;
    $ENV{T2_HARNESS_INCLUDES} = join ';' => @INC;
    exec($^X, $SCRIPT, @$argv);
}

sub find_alt_script {
    my $script = './scripts/yath';
    return 0 unless -f $script;
    return 0 unless -x $script;

    $script = clean_path($script);

    return 0 if $script eq clean_path($SCRIPT);

    $SCRIPT = $script;

    return 1;
}

sub parse_new_dev_libs {
    my @add;
    for my $arg (@ARGV) {
        last if $arg eq '::';
        last if $arg eq '--';

        next unless $arg =~ m/^(?:-D|--dev-libs?)(?:=(.+))?$/;
        my $arg = $1;

        unless ($arg) {
            push @add => map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch';
            next;
        }

        for my $path (split /,/, $arg) {
            if ($path =~ m/\*/) {
                push @add => glob($path);
            }
            else {
                push @add => $path;
            }
        }
    }

    return 0 unless @add;

    my %seen = map { ($_ => 1, clean_path($_) => 1) } @INC;
    @add = grep { !($seen{$_} || $seen{clean_path($_)}) } @add;
    return 0 unless @add;

    unshift @INC => @add;
    return 1;
}

sub inject_includes {
    return unless $ENV{T2_HARNESS_INCLUDES};
    @INC = split /;/, $ENV{T2_HARNESS_INCLUDES};
}

sub seed_hash {
    return 0 if $ENV{PERL_HASH_SEED};

    my @ltime = localtime;
    my $seed = sprintf('%04d%02d%02d', 1900 + $ltime[5], 1 + $ltime[4], $ltime[3]);
    print "PERL_HASH_SEED not set, setting to '$seed' for more reproducible results.\n";

    $ENV{PERL_HASH_SEED} = $seed;

    return 1;
}

sub clean_path {
    my ( $path, $absolute ) = @_;

    confess "No path was provided to clean_path()" unless $path;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

sub find_rc_updir {
    my ($prefix) = @_;

    my $versioned_pattern = qr/^\Q$prefix\E\.[Vv](\d+)\.rc$/;
    my $plain_name        = "$prefix.rc";

    my $abs = eval { realpath(File::Spec->rel2abs('.')) };
    my %seen;
    while ($abs && !$seen{$abs}++) {
        # Priority 1: plain name that is a symlink to a versioned file.
        my $plain_path = File::Spec->catfile($abs, $plain_name);
        if (-l $plain_path && -f $plain_path) {
            my $target = readlink($plain_path) // '';
            if ((File::Spec->splitpath($target))[2] =~ $versioned_pattern) {
                return ($plain_path, int($1));
            }
        }

        # Priority 2: explicitly versioned file (.yath.v#.rc).
        if (opendir(my $dh, $abs)) {
            for my $entry (readdir $dh) {
                if ($entry =~ $versioned_pattern) {
                    my $v    = int($1);
                    my $path = File::Spec->catfile($abs, $entry);
                    closedir $dh;
                    return ($path, $v);
                }
            }
            closedir $dh;
        }

        # Priority 3: plain unversioned file, default to V1.
        if (-f $plain_path) {
            return ($plain_path, 1);
        }

        $abs = eval { realpath(File::Spec->catdir($abs, '..')) };
    }

    return;
}

sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -e $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -e $check;
    }

    return;
}

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script - Script initialization and utility functions for Test2::Harness

=head1 SYNOPSIS

The C<yath> script uses this module as its entry point:

    #!/usr/bin/perl
    use strict;
    use warnings;

    BEGIN {
        return if $^C;
        require App::Yath::Script;
        App::Yath::Script::do_begin();
    }

    exit(App::Yath::Script::do_runtime());

=head1 DESCRIPTION

This module provides the initial entry point for the C<yath> script. It handles
script discovery, configuration loading, version detection, and delegation to
version-specific script modules (C<App::Yath::Script::V{X}>).

During the C<BEGIN> phase, C<do_begin()> locates C<.yath.rc> and
C<.yath.user.rc> configuration files, determines the harness version to use,
and delegates to the appropriate C<App::Yath::Script::V{X}> module. At
runtime, C<do_runtime()> hands off execution to that module.

=head2 Version Detection

When no configuration file is found, the latest installed
C<App::Yath::Script::V{X}> module is used automatically (C<V0> is excluded
from auto-detection since it is reserved for script validation).

The version is determined by the configuration filename using the following
priority (highest first) in each directory searched:

=over 4

=item 1.

A C<.yath.rc> symlink whose target filename matches C<.yath.v#.rc> -- the
version is extracted from the target name. This lets projects keep a stable
C<.yath.rc> name while pointing at the versioned file.

=item 2.

An explicitly versioned file C<.yath.v#.rc> (e.g. C<.yath.v2.rc>).

=item 3.

A plain C<.yath.rc> (not a symlink to a versioned file) -- defaults to B<1>
for backwards compatibility with existing L<Test2::Harness> projects.

=back

The same priority applies to user-level configuration (C<.yath.user.rc> /
C<.yath.user.v#.rc>).

If both project-level and user-level configuration files specify a version,
the user-level version takes precedence. This allows individual developers to
override the project-level version when needed.

=head1 PRIMARY API

These are the main entry points used by the C<yath> script:

=over 4

=item do_begin()

Called during C<BEGIN>. Discovers the script path, injects include paths,
seeds C<PERL_HASH_SEED> for reproducibility, loads C<.yath.rc> /
C<.yath.user.rc> configuration files, determines the harness version, and
delegates to C<App::Yath::Script::V{X}-E<gt>do_begin(...)>.

=item $exit = do_runtime()

Called after C<BEGIN>. Delegates to C<App::Yath::Script::V{X}-E<gt>do_runtime()>
and returns the exit code.

=back

=head1 EXPORTS

All exports are optional (via L<Importer>).

=over 4

=item $script_file = script()

Returns the path to the currently executing script file.

=item $yath_module = module()

Returns the name of the currently loaded C<App::Yath::Script::V{X}> module.

=item do_exec(\@argv)

Re-executes the current script with the given arguments. Sets the
C<T2_HARNESS_INCLUDES> environment variable to preserve the current C<@INC>.

=item $clean_path = clean_path($path)

=item $clean_path = clean_path($path, $absolute)

Converts a path to an absolute, normalized form. By default resolves symbolic
links using C<realpath>. Pass a false second argument to skip realpath
resolution.

=item $full_path = find_in_updir($file)

Searches for a file starting from the current directory and moving up through
parent directories until found. Returns the full path to the file or C<undef>
if not found.

=item $file = mod2file($mod)

Converts a module name (e.g., C<App::Yath::Script>) to a file path
(e.g., C<App/Yath/Script.pm>).

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
