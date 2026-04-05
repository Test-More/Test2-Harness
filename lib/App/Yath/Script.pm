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
        mod2file
    },
);

our $VERSION = '2.000011';

our ($SCRIPT, $MOD);

sub script { $SCRIPT }
sub module { $MOD }

sub do_begin {
    my $argv = [@ARGV];
    my @caller = caller();

    my $exec = 0;

    $SCRIPT = clean_path($caller[1]);

    inject_includes();

    $exec = 1 if seed_hash();
    $exec = 1 if find_alt_script();
    $exec = 1 if parse_new_dev_libs();

    do_exec($argv) if $exec;

    my $config      = find_in_updir('.yath.rc');
    my $user_config = find_in_updir('.yath.user.rc');

    my $version;
    for my $conf ($config, $user_config) {
        next unless $conf && -f $conf;

        # Default to 1 if we have a .yath.rc but no version
        $version //= 1;

        open(my $fh, '<', $conf) or die "Failed to open config file '$conf': $!";
        my $line = <$fh>;
        close($fh);

        next unless $line =~ m/^(?:#|;)\s*V(\d+)$/i;
        $version = int($1);
    }

    if (defined $version) {
        warn "Warning: Version '0' is for validating the yath script only, it should not be used for any real testing.\n"
            if $version == 0;

        $MOD = "App::Yath::Script::V${version}";

        my $file = mod2file($MOD);
        eval { require $file; 1 } or die "Could not load $MOD: $@";
    }
    else {
        my @err;
        for my $v (reverse 1 .. 2) {
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

=head1 DESCRIPTION

This module provides the initial entry point for the yath script. It handles
script discovery, configuration loading, version detection, and delegation to
version-specific script modules (App::Yath::Script::V{X}).

It also provides utility functions for path manipulation, finding files in
parent directories, and module-to-file conversion.

=head1 EXPORTS

=over 4

=item $script_file = script()

Returns the path to the currently executing script file.

=item $yath_module = module()

Returns the name of the currently loaded App::Yath::Script::V{X} module.

=item do_exec(\@ARGV)

Re-executes the current script with the given arguments. Sets
C<T2_HARNESS_INCLUDES> environment variable to preserve the current C<@INC>.

=item $clean_path = clean_path($unclean_path)

=item $clean_path = clean_path($unclean_path, 0)

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

=pod
