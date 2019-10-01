use Test2::V0;

__END__

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
