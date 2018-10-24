package App::Yath::Command::projects;
use strict;
use warnings;

our $VERSION = '0.001070';

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase;

sub group           { ' test' }
sub always_keep_dir { 0 }
sub has_display     { 1 }
sub has_jobs        { 1 }
sub has_logger      { 1 }
sub has_runner      { 1 }
sub manage_runner   { 1 }

sub summary { "Run tests for multiple projects" }
sub cli_args { "[--] projects_dir [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
This command will run all the tests for each project within a parent directory.
    EOT
}

sub make_run_from_settings {
    my $self = shift;

    # Add the Author Testing search paths if enabled
    my $settings       = $self->{+SETTINGS} ||= {};
    my @default_search = @{$settings->{default_search}};
    if ($ENV{AUTHOR_TESTING} || $settings->{env_vars}{AUTHOR_TESTING}) {
        push @default_search, @{$settings->{default_at_search}};
    }

    # Go set up our test runner.
    return $self->SUPER::make_run_from_settings(
        projects       => 1,
        default_search => \@default_search,
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::projects

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
