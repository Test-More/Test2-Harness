package App::Yath2::Options::Yath;
use strict;
use warnings;

our $VERSION = '2.000011';

# TODO: Stage 6 — restore find_libraries import when that Util helper is ported
use Test2::Harness2::Util qw/mod2file fqmod/;
# TODO: Stage 6 — restore find_in_updir import when that Util helper is ported
use Test2::Harness2::Util qw/clean_path/;

use Cwd();
use File::Spec();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Harness',
);

option_group {group => 'yath', category => 'Yath Options'} => sub {
    # TODO: Stage 6 — activate --project when project labelling is wired
    # option project => (
    #     type        => 'Scalar',
    #     alt         => ['project-name'],
    #     description => 'This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file.',
    # );

    # TODO: Stage 6 — activate --user when user metadata is wired
    # option user => (
    #     type => 'Scalar',
    #     description => 'Username to associate with logs, database entries, and yath servers.',
    #     from_env_vars => [qw/YATH_USER USER/],
    # );

    # TODO: Stage 6 — activate --base-dir when find_in_updir helper is ported
    # option base_dir => (
    #     type        => 'Scalar',
    #     description => "Root directory for the project being tested (usually where .yath.rc lives)",
    #     default     => sub {
    #         for my $dfile ('.yath.rc', '.yath.user.rc', '.git', '.svn', '.cvs') {
    #             my $base_file = find_in_updir($dfile) or next;
    #             my ($v, $d) = File::Spec->splitpath($base_file);
    #             return clean_path(File::Spec->catpath($v, $d));
    #         }
    #
    #         return clean_path(Cwd::getcwd());
    #     },
    # );

    # TODO: Stage 6 — activate --show-opts when introspection commands return
    # option 'show-opts' => (
    #     type => 'Auto',
    #     autofill => 1,
    #     description => 'Exit after showing what yath thinks your options mean',
    #     short_examples => ['', '=group'],
    #     long_examples  => ['', '=group'],
    # );

    option version => (
        type        => 'Bool',
        short       => 'V',
        description => "Exit after showing a helpful usage message",
    );

    # TODO: Stage 7 — activate --scan-options when plugin scanning returns
    # option scan_options => (
    #     type => 'BoolMap',
    #
    #     clear => sub { {options => 0} },
    #     pattern => qr/scan-(.+)/,
    #
    #     description => 'Yath will normally scan plugins for options. Some commands scan other libraries (finders, resources, renderers, etc) for options. You can use this to disable all scanning, or selectively disable/enable some scanning.',
    #     notes => 'This is parsed early in the argument processing sequence, before options that may be earlier in your argument list.',
    # );

    my $INC_SEEN;
    option dev_libs => (
        type  => 'AutoPathList',
        short => 'D',
        name  => 'dev-lib',

        autofill => sub {
            map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch';
        },

        description => 'This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',
        notes       => "This option can cause yath to use exec() to reload itself with the correct libraries in place. Each occurence of this argument can cause an additional exec() call. Use --dev-libs-verbose BEFORE any -D calls to see the exec() calls.",

        long_examples  => ['', '=lib', '="lib/*"'],
        short_examples => ['', 'lib',  '=lib', 'lib', '"lib/*"'],

        trigger => sub {
            my $opt    = shift;
            my %params = @_;
            return unless $params{action} eq 'set';

            $INC_SEEN //= {map { ($_ => 1, clean_path($_) => 1) } @INC};

            my @missing;
            for my $lib (@{$params{val}}) {
                next if $INC_SEEN->{$lib} || $INC_SEEN->{clean_path($lib)};
                push @missing => $lib;
            }

            return unless @missing;

            my $settings = $params{settings};

            # The re-exec depends on the yath script path and the
            # original argv that App::Yath::Script::V2 captures before
            # dispatch. Stage 4's minimal App::Yath2 does not register
            # 'script' / 'orig_argv' on the yath group yet (that comes
            # with the full dispatcher wire-up in a later stage). When
            # either is missing we can still populate @INC with the
            # requested paths -- the autofill normalize has already
            # added them -- and skip the re-exec. The user gets the
            # paths in @INC; they just don't get the belt-and-braces
            # interpreter relaunch that guarantees ordering in front
            # of every other module load.
            my $yath        = $settings->yath;
            my $have_script = exists $yath->{script};
            my $have_orig   = exists $yath->{orig_argv};
            return unless $have_script && $have_orig;

            if ($yath->dev_libs_verbose) {
                print STDERR "Developer library paths were specified but missing from \@INC... re-launching yath with proper include paths...\n";
                print STDERR "  -> $_\n" for @missing;
                print STDERR "\n";
            }

            my %default = map { ($_ => 1, clean_path($_) => 1) } grep { $_ } split /\n/, `$^X -e 'print "\$_\n" for \@INC'`;
            my @add     = map { "-I$_" } grep { !$default{$_} } map { clean_path($_) } @INC, @missing;
            exec($^X, @add, $yath->script, @{$yath->orig_argv // []});
        },

        normalize => \&clean_path,
    );

    option dev_libs_verbose => (
        type        => 'Bool',
        default     => 0,
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
