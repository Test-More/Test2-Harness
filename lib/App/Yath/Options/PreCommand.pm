package App::Yath::Options::PreCommand;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Harness::Util qw/mod2file clean_path/;

use App::Yath::Options;

option_group {prefix => 'yath'} => sub {
    option plugins => (
        type  => 'm',
        short => 'p',
        alt  => ['plugin'],

        pre_command => 1,

        category       => 'Plugins',
        long_examples  => [' PLUGIN', ' +App::Yath::Plugin::PLUGIN', ' PLUGIN=arg1,arg2,...'],
        short_examples => ['PLUGIN'],
        description    => 'Load a yath plugin.',

        action => \&plugin_action,
    );

    option no_scan_plugins => (
        type => 'b',
        pre_command => 1,

        category => 'Plugins',
        description => 'Normally yath scans for and loads all App::Yath::Plugin::* modules in order to bring in command-line options they may provide. This flag will disable that. This is useful if you have a naughty plugin that it loading other modules when it should not.',
    );

    option dev_libs => (
        type  => 'D',
        short => 'D',
        name  => 'dev-lib',

        pre_command => 1,

        category    => 'Developer',
        description => 'Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',

        long_examples  => ['', '=lib'],
        short_examples => ['', '=lib', 'lib'],

        normalize => \&normalize_dev_libs,
        action    => \&dev_libs_action,
    );
};

sub plugin_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

    my ($class, $args) = split /=/, $norm, 2;
    $args = [split ',', $args] if $args;

    $class = "App::Yath::Plugin::$class"
        unless $class =~ s/^\+//;

    my $file = mod2file($class);
    require $file;

    my $plugin = $args ? $class->new(@$args) : $class;

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

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::PreCommand - Options for yath before command is specified.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
