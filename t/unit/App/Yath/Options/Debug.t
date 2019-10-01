use Test2::V0;

__END__

package App::Yath::Options::Debug;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Harness::Util::JSON qw/encode_pretty_json/;
use Test2::Util::Table qw/table/;
use Test2::Harness::Util qw/find_libraries mod2file/;

use App::Yath::Options;

option_group {prefix => 'debug', category => 'Help and Debugging'} => sub {
    option dummy => (
        short       => 'd',
        description => 'Dummy run, do not actually execute anything',
        default     => sub { $ENV{T2_HARNESS_DUMMY} || 0 },
    );

    option keep_dirs => (
        short       => 'k',
        alt         => ['keep_dir'],
        description => 'Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.',
        default     => 0,
    );

    option 'show-opts' => (
        description         => 'Exit after showing what yath thinks your options mean',
        post_process        => \&_post_process_show_opts,
        post_process_weight => 99999,
        pre_command         => 1,
    );

    option version => (
        short        => 'V',
        description  => "Exit after showing a helpful usage message",
        post_process => \&_post_process_version,
        pre_command  => 1,
    );

    option help => (
        short        => 'h',
        description  => "exit after showing help information",
        post_process => \&_post_process_help,
    );
};

sub _post_process_help {
    my %params = @_;

    return unless $params{settings}->debug->help;

    if (my $cmd = $params{command}) {
        print $cmd->cli_help(%params);
    }
    else {
        print __PACKAGE__->cli_help(%params);
    }

    exit 0;
}

sub _post_process_show_opts {
    my %params = @_;

    return unless $params{settings}->debug->show_opts;

    my $settings = $params{settings};

    print "\nCommand selected: " . $params{command}->name . "  (" . ref($params{command}) . ")\n" if $params{command};

    my $args = $params{args};
    print "\nCommand args: " . join(', ' => @$args) . "\n" if @$args;

    my $out = encode_pretty_json($settings);

    print "\nCurrent command line and config options result in these settings:\n";
    print "$out\n";

    exit 0;
}

sub _post_process_version {
    my %params = @_;

    return unless $params{settings}->debug->version;

    require App::Yath;
    my $out = <<"    EOT";

Yath version: $App::Yath::VERSION

Extended Version Info
    EOT

    my $plugin_libs = find_libraries('App::Yath::Plugin::*');

    my @vers = (
        [perl        => $^V],
        ['App::Yath' => App::Yath->VERSION],
        (
            map {
                eval { require(mod2file($_)); 1 }
                    ? [$_ => $_->VERSION // 'N/A']
                    : [$_ => 'N/A']
            } qw/Test2::API Test2::Suite Test::Builder/
        ),
        (
            map {
                eval { require($plugin_libs->{$_}); 1 }
                    && [$_ => $_->VERSION // 'N/A']
            } sort keys %$plugin_libs
        ),
    );

    $out .= join "\n" => table(
        header => [qw/COMPONENT VERSION/],
        rows   => \@vers,
    );

    print "$out\n\n";

    exit 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Debug - Debug options for Yath

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
