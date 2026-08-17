package App::Yath::Script::V1;
use strict;
use warnings;

our $VERSION = '1.000174';

my ($RUN_SUB, @DEVLIBS, $NO_PLUGINS);

sub do_begin {
    my $class  = shift;
    my %params = @_;

    my $script      = $params{script};
    my $argv        = $params{argv};
    my $config_file = $params{config};
    my $user_config_file = $params{user_config};

    local $.;

    my $ORIG_TMP;
    my $ORIG_TMP_PERMS;
    my %ORIG_SIG = map { defined($SIG{$_}) ? ($_ => "$SIG{$_}") : () } keys %SIG;
    my @ORIG_ARGV = @$argv;
    # Skip @INC hook refs (coderef / arrayref / blessed); they can't cross exec via -I nor round-trip JSON.
    my @ORIG_INC = grep { !ref($_) } @INC;
    my %CONFIG;

    @ARGV = @$argv;

    # ==START TESTABLE CODE PARSE_CONFIG_FILES==

    my (@CONFIG_ARGS, @TO_CLEAN);
    for my $file ($config_file, $user_config_file) {
        next unless $file && -f $file;

        my $cmd;
        open(my $fh, '<', $file) or die "Could not open config file '$file' for reading: $!";
        while (my $line = <$fh>) {
            chomp($line);
            $cmd = $1 and next if $line =~ m/^\[(.*)\]$/;
            $line =~ s/;.*$//g;
            $line =~ s/^\s*//g;
            $line =~ s/\s*$//g;
            next unless length($line);

            my ($key, $eq, $val);
            if ($line =~ m/^(-\S)((?:rel|glob|relglob)\(.*\))$/) {   # Handle things like -Irel(...)
                $key = $1;
                $eq  = '';
                $val = $2;
            }
            else {
                ($key, $eq, $val) = split /(=|\s+)/, $line, 2;  # Covers most cases
            }

            my $is_pre;
            if ($key =~ m/^-D/ || $key eq '--dev-lib') {
                $eq = '=' if $val;
                $is_pre = 1;
            }

            if ($key eq '--no-scan-plugins') {
                $is_pre = 1;
            }

            my $need_to_clean;
            if ($val && $val =~ s/(^|=)\s*rel\(\s*//) {
                die "Syntax error in $file line $.: Expected ')'\n" unless $val =~ s/\s*\)$//;
                my $path = $file;
                $path =~ s{[^/]*$}{}g;
                $val           = "${path}${val}";
                $need_to_clean = 1;
            }

            my @all;

            if ($val && $val =~ s/(^|=)\s*(rel)?glob\(\s*//) {
                my $rel = $2;

                die "Syntax error in $file line $.: Expected ')'\n" unless $val =~ s/\s*\)$//;

                my $path = '';
                if ($rel) {
                    $path = $file;
                    $path =~ s{[^/]*$}{}g;
                }

                # Avoid loading File::Glob in this process...
                my $out = `$^X -e 'print join "\\n" => glob("${path}${val}")'`;
                my @vals = split /\n/, $out;
                @all = map {[$key, $eq, $_, 1]} @vals;
            }
            else {
                @all = ([$key, $eq, $val, $need_to_clean]);
            }

            for my $set (@all) {
                my ($key, $eq, $val, $need_to_clean) = @$set;
                $eq //= '';

                my @parts = $eq eq '=' ? ("${key}${eq}${val}") : (grep { defined $_ } $key, $val);

                if ($is_pre) {
                    push @CONFIG_ARGS => @parts;
                }
                else {
                    $cmd //= '~';
                    push @{$CONFIG{$cmd}} => @parts;
                    push @TO_CLEAN => [$cmd, $#{$CONFIG{$cmd}}, $key, $eq, $val] if $need_to_clean;
                }
            }
        }
        close($fh);
    }

    unshift @ARGV => @CONFIG_ARGS;

    # ==END TESTABLE CODE PARSE_CONFIG_FILES==
    # ==START TESTABLE CODE PRE_PARSE_D_ARGS==

    my (@libs, %done, @args, $maybe_exec);
    while (@ARGV) {
        my $arg = shift @ARGV;

        if ($arg eq '--' || $arg eq '::') {
            push @args => $arg;
            last;
        }

        if ($arg eq '--no-dev-lib') {
            @libs = ();
            %done = ();
            next;
        }

        if ($arg =~ m{^(?:(?:-D=?|--dev-lib=)(.*)|--dev-lib)$}) {
            my @add = $1 ? ($1) : ();
            unless (@add) {
                @add        = ('lib', 'blib/lib', 'blib/arch');
                $maybe_exec = $arg;
            }

            push @libs => grep { !$done{$_}++ } @add;
            next;
        }

        if ($arg eq '--no-scan-plugins') {
            $NO_PLUGINS = 1;
            next;
        }

        push @args => $arg;
    }
    @ARGV = (@args, @ARGV);

    unshift @INC => @libs;
    @DEVLIBS = @libs;

    # ==END TESTABLE CODE PRE_PARSE_D_ARGS==

    # Now it is safe/ok to load things.
    require Cwd;
    require File::Spec;

    $ORIG_TMP = File::Spec->tmpdir();
    $ORIG_TMP_PERMS = ((stat($ORIG_TMP))[2] & 07777);

    # ==START TESTABLE CODE CLEANUP_PATHS==

    if (@libs || @TO_CLEAN) {
        for (my $i = 0; $i < @libs; $i++) {
            $DEVLIBS[$i] = $INC[$i] = Cwd::realpath($INC[$i]) // File::Spec->rel2abs($INC[$i]);
        }

        for my $clean (@TO_CLEAN) {
            my ($cmd, $idx, $key, $eq, $val) = @$clean;
            $val = Cwd::realpath($val) // File::Spec->rel2abs($val);

            if ($eq eq '=') {
                $CONFIG{$cmd}->[$idx] = "${key}${eq}${val}";
            }
            else {
                $CONFIG{$cmd}->[$idx] = $val;
            }
        }
    }

    # ==END TESTABLE CODE CLEANUP_PATHS==
    # ==START TESTABLE CODE CREATE_APP==

    require App::Yath;
    require Time::HiRes;
    require Test2::Harness::Settings;

    my %mixin = (config_file => '', user_config_file => '');
    $mixin{config_file}      = Cwd::realpath($config_file)      // File::Spec->rel2abs($config_file)      if $config_file;
    $mixin{user_config_file} = Cwd::realpath($user_config_file) // File::Spec->rel2abs($user_config_file) if $user_config_file;

    my $settings = Test2::Harness::Settings->new(
        harness => {
            orig_tmp         => $ORIG_TMP,
            orig_tmp_perms   => $ORIG_TMP_PERMS,
            orig_sig         => \%ORIG_SIG,
            orig_argv        => \@ORIG_ARGV,
            orig_inc         => \@ORIG_INC,
            script           => $script,
            no_scan_plugins  => $NO_PLUGINS,
            dev_libs         => \@DEVLIBS,
            start            => Time::HiRes::time(),
            version          => $App::Yath::VERSION,
            cwd              => Cwd::getcwd(),
            %mixin,
        },
    );

    my $app = App::Yath->new(
        argv    => \@ARGV,
        config  => \%CONFIG,
        settings => $settings,
    );

    $app->generate_run_sub('App::Yath::Script::V1::_run');

    # ==END TESTABLE CODE CREATE_APP==

    # Reset these if we got this far.
    $? = 0;
    $@ = '';
}

sub do_runtime {
    my $class = shift;
    return _run();
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V1 - V1 (Legacy) yath script handler for Test2::Harness

=head1 DESCRIPTION

This is the V1 script handler for L<Test2::Harness>. It is used by
L<App::Yath::Script> when a C<.yath.rc> file with no version marker (or an
explicit C<# V1> marker) is found, or when V1 is the highest installed version.

This module contains the logic that was previously embedded directly in the
C<scripts/yath> script of L<Test2::Harness>.

=head1 METHODS

=over 4

=item $class->do_begin(%params)

Called during the C<BEGIN> phase. Parses configuration files, processes C<-D>
and C<--no-scan-plugins> arguments, sets up C<@INC>, and initializes
L<App::Yath>.

Parameters:

=over 4

=item script => $path

Path to the executing script.

=item argv => \@argv

Original command line arguments.

=item config => $path

Path to the C<.yath.rc> file, or C<undef>.

=item user_config => $path

Path to the C<.yath.user.rc> file, or C<undef>.

=back

=item $exit = $class->do_runtime()

Called after C<BEGIN>. Executes the yath command and returns the exit code.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
