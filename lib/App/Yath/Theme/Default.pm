package App::Yath::Theme::Default;
use strict;
use warnings;

use parent 'App::Yath::Theme';

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase;

sub DEFAULT_BASE_COLORS() {
    return (
        reset      => 'reset',
        blob       => 'bold bright_black on_white',
        tree       => 'bold bright_white',
        tag_border => 'bold bright_white',
    );
}

sub DEFAULT_STATE_COLORS() {
    return (
        passed  => 'green',
        failed  => 'red',
        running => 'cyan',
        todo    => 'yellow',
    );
}

sub DEFAULT_STATUS_COLORS() {
    return (
        default => 'cyan',
        spinner => 'bold bright_green',
        border  => 'bold bright_white',
        message => 'yellow',
        message_a => 'bold bright_yellow',
        message_b => 'yellow',
        sub_message => 'reset',
        command => 'cyan',
    );
}

sub DEFAULT_TAG_COLORS() {
    return (
        'debug'    => 'red',
        'diag'     => 'yellow',
        'error'    => 'red',
        'fatal'    => 'bold red',
        'fail'     => 'red',
        'halt'     => 'bold red',
        'pass'     => 'green',
        '! pass !' => 'cyan',
        'todo'     => 'cyan',
        'no  plan' => 'yellow',
        'skip'     => 'bold cyan',
        'skip all' => 'bold white on_blue',
        'stderr'   => 'yellow',
        'run info' => 'bold bright_blue',
        'job info' => 'bold bright_blue',
        'run  fld' => 'bold bright_blue',
        'launch'   => 'bold bright_white',
        'retry'    => 'bold bright_white',
        'passed'   => 'bold bright_green',
        'to retry' => 'bold bright_yellow',
        'failed'   => 'bold bright_red',
        'reason'   => 'magenta',
        'timeout'  => 'magenta',
        'time'     => 'blue',
        'memory'   => 'blue',
    );
}

sub DEFAULT_FACET_COLORS() {
    return (
        time    => 'blue',
        memory  => 'blue',
        about   => 'magenta',
        amnesty => 'cyan',
        assert  => 'bold bright_white',
        control => 'bold red',
        error   => 'yellow',
        info    => 'yellow',
        meta    => 'magenta',
        parent  => 'magenta',
        trace   => 'bold red',
    );
}

# These colors all look decent enough to use, ordered to avoid putting similar ones together
sub DEFAULT_JOB_COLORS() {
    return (
        'bold green on_blue',
        'bold blue on_white',
        'bold black on_cyan',
        'bold green on_bright_black',
        'bold dark blue on_white',
        'bold black on_green',
        'bold cyan on_blue',
        'bold black on_white',
        'bold white on_cyan',
        'bold cyan on_bright_black',
        'bold white on_green',
        'bold bright_black on_white',
        'bold white on_blue',
        'bold bright_cyan on_green',
        'bold blue on_cyan',
        'bold white on_bright_black',
        'bold bright_black on_green',
        'bold bright_green on_blue',
        'bold bright_blue on_white',
        'bold bright_white on_bright_black',
        'bold yellow on_blue',
        'bold bright_black on_cyan',
        'bold bright_green on_bright_black',
        'bold blue on_green',
        'bold bright_cyan on_blue',
        'bold bright_blue on_cyan',
        'bold dark bright_white on_bright_black',
        'bold bright_blue on_green',
        'bold dark bright_blue on_white',
        'bold bright_white on_blue',
        'bold bright_cyan on_bright_black',
        'bold bright_white on_cyan',
        'bold bright_white on_green',
        'bold bright_yellow on_blue',
        'bold dark bright_cyan on_bright_black',
    );
}

sub DEFAULT_BORDERS {
    return (
        'default' => ['[', ']'],
        'amnesty' => ['{', '}'],
        'info'    => ['(', ')'],
        'error'   => ['<', '>'],
        'parent'  => [' ', ' '],
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Theme::Default - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

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

=cut POD NEEDS AUDIT

