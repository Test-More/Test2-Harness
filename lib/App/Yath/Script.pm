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

our $VERSION = '2.000016';

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

    my $local_vers = install_local_lib();

    $exec = 1 if find_alt_script();

    my ($config, $user_config, $version) = find_rc_files($cli_version);
    $version //= $local_vers;

    # Pre-parse the global section of the rc files for dev-libs flags
    # so a user can put `-D` (etc) at the top of .yath.rc instead of on
    # every CLI invocation. Only the global section is parsed -- command
    # sections are reserved for the per-command parser since this layer
    # has no idea which command is about to run. Run before the regular
    # CLI -D pass so `T2_HARNESS_INCLUDES` carries everything across the
    # re-exec triggered by either source.
    $exec = 1 if parse_rc_dev_libs($config, $user_config);
    $exec = 1 if parse_new_dev_libs();

    do_exec($argv) if $exec;

    $MOD = defined($version) ? load_yath_module($version) : load_latest_yath_module();

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
    return _install_dev_libs(_collect_dev_libs(@ARGV));
}

sub parse_rc_dev_libs {
    my @files = grep { defined && length } @_;
    return 0 unless @files;

    my @args;
    for my $file (@files) {
        next unless -f $file;
        push @args => _rc_global_tokens($file);
    }

    return _install_dev_libs(_collect_dev_libs(@args));
}

# Walk a list of argv-style tokens looking for -D / --dev-lib(s) flags.
# Returns the list of paths to add to @INC.
sub _collect_dev_libs {
    my @args = @_;

    my @add;
    for my $arg (@args) {
        last if $arg eq '::';
        last if $arg eq '--';

        next unless $arg =~ m/^(?:-D|--dev-libs?)(?:=(.+))?$/;
        my $val = $1;

        unless (defined $val && length $val) {
            push @add => map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch';
            next;
        }

        for my $path (split /,/, $val) {
            if ($path =~ m/\*/) { push @add => glob($path) }
            else                { push @add => $path }
        }
    }

    return @add;
}

# Dedup against @INC and prepend. Returns 1 if anything was added.
sub _install_dev_libs {
    my @add = @_;
    return 0 unless @add;

    my %seen = map { ($_ => 1, clean_path($_) => 1) } @INC;
    @add = grep { !($seen{$_} || $seen{clean_path($_)}) } @add;
    return 0 unless @add;

    unshift @INC => @add;
    return 1;
}

# Tokenize the global section of an rc file into argv-style tokens.
# Stops at the first [section] marker. `--foo` and `--foo=bar` lines
# yield one token; `--foo bar` lines yield two, matching the format
# App::Yath2::ConfigFile uses for command sections.
sub _rc_global_tokens {
    my ($file) = @_;

    my @args;
    open(my $fh, '<', $file) or return;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\s*[#;].*//;
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless length $line;
        last if $line =~ /^\[/;

        if ($line =~ /^(\S+)\s+(.+)$/) {
            push @args => ($1, $2);
        }
        else {
            push @args => $line;
        }
    }
    close($fh);

    return @args;
}

# Locate the project- and user-level rc files plus the version number
# they imply. Returns ($config, $user_config, $version), each of which
# may be undef. When $cli_version is defined the caller's explicit
# version always wins; only versioned rc files matching that version
# are looked up.
sub find_rc_files {
    my ($cli_version) = @_;

    if (defined $cli_version) {
        # Explicit version on CLI: prefer matching versioned rc files,
        # but fall back to plain .yath.rc / .yath.user.rc when no
        # versioned match exists. Accept both .yath.v#.rc and
        # .yath.V#.rc.
        my $config = find_in_updir(".yath.v${cli_version}.rc")
                  // find_in_updir(".yath.V${cli_version}.rc")
                  // find_in_updir(".yath.rc");
        my $user_config = find_in_updir(".yath.user.v${cli_version}.rc")
                       // find_in_updir(".yath.user.V${cli_version}.rc")
                       // find_in_updir(".yath.user.rc");
        return ($config, $user_config, $cli_version);
    }

    my ($config,      $config_version) = find_rc_updir('.yath');
    my ($user_config, $user_version)   = find_rc_updir('.yath.user');

    # .yath.user(.v#).rc version takes precedence over .yath(.v#).rc.
    # Either may be undef (plain unversioned rc); when both are undef
    # the caller falls back to install_local_lib's version, then to
    # load_yath_module's @INC scan.
    my $version = $user_version // $config_version;

    return ($config, $user_config, $version);
}

# Load and return the App::Yath::Script::V{X} module to delegate to.
# Dies if the requested module fails to load. V0 is reserved for
# script validation and emits a warning when explicitly requested.
sub load_yath_module {
    my ($version) = @_;

    warn "Warning: Version '0' is for validating the yath script only, it should not be used for any real testing.\n"
        if $version == 0;

    my $mod  = "App::Yath::Script::V${version}";
    my $file = mod2file($mod);
    eval { require $file; 1 } or die "Could not load $mod: $@";
    return $mod;
}

# Scan @INC for installed App::Yath::Script::V#.pm modules and return
# the version numbers sorted highest-first. V0 is excluded since it is
# reserved for script validation and must never be auto-selected.
sub find_installed_versions {
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
    delete $found{0};
    return sort { $b <=> $a } keys %found;
}

# Final fallback when no version was captured from CLI, rc files, or a
# local checkout. Tries each installed App::Yath::Script::V# module
# from highest to lowest until one loads. Dies with the collected load
# errors if none succeed (or if none are installed).
sub load_latest_yath_module {
    my @vers = find_installed_versions();

    die "No App::Yath (App::Yath::Script::V#) modules appear to be installed.\n"
        unless @vers;

    my @err;
    for my $v (@vers) {
        my $mod  = "App::Yath::Script::V${v}";
        my $file = mod2file($mod);
        return $mod if eval { require $file; 1 };
        push @err => $@;
    }

    die join "\n" => (
        "No Test2::Harness (App::Yath) versions could be loaded:",
        @err,
    );
}

sub inject_includes {
    return unless $ENV{T2_HARNESS_INCLUDES};
    @INC = split /;/, $ENV{T2_HARNESS_INCLUDES};
}

# Scan ./lib/App/Yath/Script for V#.pm modules and return the highest
# version found, or undef when no such modules are present. Used by
# install_local_lib() to detect a working-copy checkout that ships its
# own versioned script module.
sub find_local_version {
    my $local_path = File::Spec->catdir(File::Spec->curdir, 'lib', 'App', 'Yath', 'Script');
    return undef unless -d $local_path;
    opendir(my $dh, $local_path) or return undef;

    my $vers;
    for my $file (readdir($dh)) {
        next unless $file =~ m/^V(\d+)\.pm$/;
        my $n = int($1);
        $vers = $n if !defined($vers) || $n > $vers;
    }
    closedir $dh;

    return $vers;
}

# If the cwd contains ./lib/App/Yath/Script/V#.pm modules, ensure ./lib
# is at the front of @INC so they take precedence over any installed
# copy. Returns the highest local version found, or undef if no local
# modules exist. Idempotent: a re-exec that already has ./lib in @INC
# (via T2_HARNESS_INCLUDES) does not re-print or re-unshift.
sub install_local_lib {
    my $local_vers = find_local_version();
    return undef unless defined $local_vers;

    my $lib_path = clean_path(File::Spec->catdir(File::Spec->curdir, 'lib'));
    return $local_vers if grep { clean_path($_) eq $lib_path } @INC;

    print "Detected App::Yath::Script::V# modules in local ./lib, adding '$lib_path' to the front of \@INC.\n";
    unshift @INC => $lib_path;

    return $local_vers;
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

        # Priority 2: explicitly versioned file -- highest version wins.
        if (opendir(my $dh, $abs)) {
            my ($best_ver, $best_entry);
            for my $entry (readdir $dh) {
                next unless $entry =~ $versioned_pattern;
                my $v = int($1);
                if (!defined($best_ver) || $v > $best_ver) {
                    $best_ver   = $v;
                    $best_entry = $entry;
                }
            }
            closedir $dh;
            if (defined $best_ver) {
                return (File::Spec->catfile($abs, $best_entry), $best_ver);
            }
        }

        # Priority 3: plain unversioned file -- no version captured, the
        # caller (find_rc_files / install_local_lib / load_yath_module)
        # decides what version to use.
        if (-f $plain_path) {
            return ($plain_path, undef);
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

A version may come from any of these sources, in priority order: an
explicit C<V#> / C<v#> as the first CLI argument, the rc files found
walking upward from the cwd, a working-copy checkout under
C<./lib/App/Yath/Script/V#.pm>, or finally the highest
C<App::Yath::Script::V#> module installed in C<@INC>. C<V0> is reserved
for script validation, is never auto-selected, and must be requested
explicitly.

When walking upward, each directory is scanned in this order:

=over 4

=item 1.

A C<.yath.rc> symlink whose target filename matches C<.yath.v#.rc> /
C<.yath.V#.rc> -- the version is extracted from the target name. This
lets projects keep a stable C<.yath.rc> name while pointing at the
versioned file.

=item 2.

Explicitly versioned files C<.yath.v#.rc> / C<.yath.V#.rc> -- the
highest version present in the directory wins, both for the chosen rc
file and the captured version.

=item 3.

A plain C<.yath.rc> (not a symlink to a versioned file) -- the rc file
is used but B<no version is captured>; the caller falls through to the
checkout / C<@INC> sources above.

=back

The same priority applies to user-level configuration (C<.yath.user.rc>
/ C<.yath.user.v#.rc>).

If both project-level and user-level rc files capture a version, the
user-level version takes precedence. This allows individual developers
to override the project-level version when needed.

When an explicit C<V#> is given on the CLI, the lookup prefers a
matching versioned rc file but falls back to a plain C<.yath.rc> /
C<.yath.user.rc> if no versioned file is found.

=head1 PRIMARY API

These are the main entry points used by the C<yath> script:

=over 4

=item do_begin()

Called during C<BEGIN>. Discovers the script path, injects include paths,
loads C<.yath.rc> / C<.yath.user.rc> configuration files, determines the
harness version, and delegates to
C<App::Yath::Script::V{X}-E<gt>do_begin(...)>.

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
