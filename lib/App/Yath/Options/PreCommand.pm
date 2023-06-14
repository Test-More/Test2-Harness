package App::Yath::Options::PreCommand;
use strict;
use warnings;

our $VERSION = '1.000154';

use App::Yath::Util qw/find_pfile/;
use Test2::Harness::Util qw/mod2file clean_path/;

use App::Yath::Options;

option_group {prefix => 'harness', pre_command => 1} => sub {
    option plugins => (
        type  => 'm',
        short => 'p',
        alt  => ['plugin'],

        category       => 'Plugins',
        long_examples  => [' PLUGIN', ' +App::Yath::Plugin::PLUGIN', ' PLUGIN=arg1,arg2,...'],
        short_examples => ['PLUGIN'],
        description    => 'Load a yath plugin.',

        action => \&plugin_action,
    );

    option no_scan_plugins => (
        type => 'b',

        category => 'Plugins',
        description => 'Normally yath scans for and loads all App::Yath::Plugin::* modules in order to bring in command-line options they may provide. This flag will disable that. This is useful if you have a naughty plugin that is loading other modules when it should not.',
    );

    option project => (
        type        => 's',
        alt         => ['project-name'],
        category    => 'Environment',
        description => 'This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file. This is necessary for a persistent runner.',
    );

    option persist_dir => (
        type        => 's',
        category    => 'Environment',
        description => 'Where to find persistence files.',
        normalize   => \&clean_path,
    );

    option persist_file => (
        type        => 's',
        category    => 'Environment',
        alt         => ['pfile'],
        normalize   => \&clean_path,
        description => "Where to find the persistence file. The default is /{system-tempdir}/project-yath-persist.json. If no project is specified then it will fall back to the current directory. If the current directory is not writable it will default to /tmp/yath-persist.json which limits you to one persistent runner on your system.",
    );

    option dev_libs => (
        type  => 'D',
        short => 'D',
        name  => 'dev-lib',

        category    => 'Developer',
        description => 'Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',

        long_examples  => ['', '=lib'],
        short_examples => ['', '=lib', 'lib'],

        normalize => \&normalize_dev_libs,
        action    => \&dev_libs_action,
    );

    post \&post_process;
};

sub plugin_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings, $handler, $options) = @_;

    my ($class, $args) = split /=/, $norm, 2;
    $args = [split ',', $args] if $args;

    $class = "App::Yath::Plugin::$class"
        unless $class =~ s/^\+//;

    return if grep { $class eq (ref($_) || $_) } @{$settings->harness->plugins};

    my $file = mod2file($class);
    require $file;

    $options->include_from($class) if $class->can('options');

    my $plugin = $class->can('new') ? $class->new(@{$args // []}) : $class;

    $handler->($slot, $plugin);
}

sub normalize_dev_libs {
    my $val = shift;

    return $val if $val eq '1';

    return clean_path($val);
}

sub dev_libs_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

    my %seen = map { $_ => 1 } @{$$slot};

    my @new = grep { !$seen{$_}++ } ($norm eq '1') ? (map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch') : ($norm);

    return unless @new;

    warn <<"    EOT" for @new;
dev-lib '$_' added to \@INC late, it is possible some yath libraries were already loaded from other paths.
(Maybe you need to move the -D or --dev-lib argument(s) to be earlier in your command line or config file?)
    EOT

    unshift @INC   => @new;
    unshift @{$$slot} => @new;
}

sub post_process {
    my %params   = @_;
    my $settings = $params{settings};

    $settings->harness->field(persist_file => find_pfile($settings, vivify => 1, no_checks => 1))
        unless defined $settings->harness->persist_file;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::PreCommand - Options for yath before command is specified.

=head1 DESCRIPTION

This is qhere many pe-commnd options are defined.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
