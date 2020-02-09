package Test2::Harness::Plugin;
use strict;
use warnings;

our $VERSION = '1.000000';

sub munge_search {}

sub claim_file {}

sub munge_files {}

sub inject_run_data {}

sub setup {}

sub teardown {}

sub TO_JSON { ref($_[0]) || "$_[0]" }

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Plugin - Base class for Test2::Harness plugins.

=head1 DESCRIPTION

This class holds the methods specific to L<Test2::Harness> which
is the backend. Most of the time you actually want to subclass
L<App::Yath::Plugin> which subclasses this class, and holds additional methods
that apply to yath (the UI layer).

=head1 SYNOPSIS

You probably want to subclass L<App::Yath::Plugin> instead. This class here
mainly exists to separate concerns, but is not something you should use
directly.

    package Test2::Harness::Plugin::MyPlugin;

    use parent 'Test2::Harness::Plugin';

    # ... Define methods

    1;

=head1 METHODS

=over 4

=item $plugin->munge_search($input, $default_search, $settings)

C<$input> is an arrayref of files and/or directories provided at the command
line.

C<$default_search> is an arrayref with the default files/directories pulled in
when nothing is specified at the command ine.

C<$settings> is an instance of L<Test2::Harness::Settings>

=item $plugin->claim_file

=item $plugin->munge_files

=item $plugin->inject_run_data

=item $plugin->setup

=item $plugin->teardown

=item $plugin->TO_JSON

This is here as a bare minimum serialization method. It returns the plugin
class name.

=back

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
