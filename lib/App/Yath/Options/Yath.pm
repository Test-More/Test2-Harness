package App::Yath::Options::Yath;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/find_libraries mod2file fqmod/;
use Test2::Harness::Util::Minimal qw/find_in_updir clean_path/;

use Cwd();
use File::Spec();

use Getopt::Yath;

option_group {group => 'yath', category => 'Yath Options'} => sub {
    option project => (
        type        => 'Scalar',
        alt         => ['project-name'],
        description => 'This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file.',
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

    option dev_libs => (
        type        => 'AutoList',
        short       => 'D',
        name        => 'dev-lib',

        autofill => sub { map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch' },

        description => 'Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',

        long_examples  => ['', '=lib'],
        short_examples => ['', 'lib', '=lib', 'lib'],

        normalize => \&clean_path,

        trigger => sub {
            my $opt = shift;
            my %params = @_;

            return unless $params{action} eq 'set';

            my $ref = $params{ref};
            my $val = $params{val};
            my %seen = map { $_ => 1 } @{$$ref};
            my @new = grep { !$seen{$_} } @$val;

            return unless @new;

            warn <<"            EOT" for @new;
dev-lib '$_' added to \@INC late, it is possible some yath libraries were already loaded from other paths.
(Maybe you need to move the -D or --dev-lib argument(s) to be earlier in your command line or config file?)
            EOT
        },

        notes => 'This is parsed early in the argument processing sequence, before options that may be earlier in your argument list.',
    );

    option help => (
        type           => 'Auto',
        autofill       => 1,
        short          => 'h',
        description    => "exit after showing help information",
        short_examples => ['', '=Category', '="Category with space"'],
        long_examples  => ['', '=Category', '="Category with space"'],
    );

    option plugins => (
        type  => 'Map',
        short => 'p',
        alt   => ['plugin'],

        description      => 'Load a yath plugin.',
        mod_adds_options => 1,

        normalize => sub {
            my ($class, $args) = @_;

            $class = fqmod('App::Yath::Plugin', $class);
            my $file = mod2file($class);
            require $file;

            $args = $args ? [split ',', $args] : [];

            return $class => $args;
        },
    );

    option load_settings => (
        type => 'Scalar',
        description => 'This is used internally to pass settings to sub-commands',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Yath - Core yath options

=head1 DESCRIPTION

Core yath command options.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2023 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
