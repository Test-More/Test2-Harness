package App::Yath2::Command::which;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Spec ();

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath which` prints the script + module paths yath is running from.
# Useful for confirming that a developer is exercising the checkout
# they think they are, or for debugging PERL5LIB / perlbrew setups.
sub run {
    my $self = shift;

    my $script = $self->{+SCRIPT} // $0;

    # Report both the launcher (scripts/yath) and the loaded
    # App::Yath2 module path so the user sees where the code is
    # coming from end-to-end.
    my $app_file = $INC{'App/Yath2.pm'} // '(not loaded)';
    my $h2_file  = $INC{'Test2/Harness2.pm'};

    # Test2::Harness2 loads lazily via the test command; show "(not
    # loaded)" when a caller runs just `yath which` without touching
    # it first.
    $h2_file //= _try_inc_for('Test2/Harness2.pm') // '(not loaded)';

    print "script:         ", File::Spec->rel2abs($script), "\n";
    print "App::Yath2:     ", $app_file,                    "\n";
    print "Test2::Harness2 ", $h2_file,                     "\n";

    return 0;
}

sub _try_inc_for {
    my ($rel) = @_;
    for my $dir (@INC) {
        next unless -d $dir;
        my $full = File::Spec->catfile($dir, $rel);
        return $full if -f $full;
    }
    return undef;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::which - Print the yath script and module
paths the current invocation is using.

=head1 DESCRIPTION

Writes three lines to STDOUT:

    script:          /abs/path/to/scripts/yath
    App::Yath2:      /abs/path/to/lib/App/Yath2.pm
    Test2::Harness2  /abs/path/to/lib/Test2/Harness2.pm

Useful for confirming which checkout / install a developer is
running. Takes no arguments.

=cut
