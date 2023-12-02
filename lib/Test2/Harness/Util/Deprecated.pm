package Test2::Harness::Util::Deprecated;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/confess cluck carp/;

use vars qw/$IGNORE_IMPORT/;

sub import {
    my $class = shift;
    my %params = @_;
    my ($mod, $file, $line) = caller();

    my $append = delete($params{append});
    my $delegate = delete($params{delegate});
    my $replaced = delete($params{replaced}) // $delegate;
    my $fatal    = delete($params{fatal})    // ($delegate ? 0 : 1);
    my $inject   = delete($params{inject})   // ($delegate ? 0 : 1);

    my $replaced_is_list = 0;
    if ($replaced) {
        if (ref($replaced) eq 'ARRAY') {
            $replaced_is_list = @$replaced > 1 ? 1 : 0;
            $replaced = join(", " => map { "'$_'" } @$replaced);
        }
        else {
            $replaced = "'$replaced'";
        }
    }

    $inject = 0 if delete $params{no_inject};

    my $out = "Module '$mod' has been deprecated";
    $out .= ", it has been replaced by: $replaced" if $replaced;
    $out .= "\n";

    if ($delegate) {
        $out .= "Currently '$mod' module will automatically delegate to '$delegate' (via inheritence), but this could change in the future.\n";

        no strict 'refs';
        push @{"$mod\::ISA"} => $delegate;
    }

    if ($replaced) {
        my $alt = " or another alternative";
        $alt = ",$alt" if $replaced_is_list;
        $out .= "You " . ($delegate ? 'should' : 'must') . " switch to using ${replaced}${alt} if you wish to maintain this functionality.\n";
    }

    if ($append) {
        chomp($append);
        $out .= "$append\n";
    }

    $out .= "Deprecated module '$mod' was loaded";

    my $action = sub {
        local $Carp::CarpInternal{$class} = 1;
        local $Carp::CarpInternal{$mod} = 1;
        $fatal ? confess($out) : cluck($out);
    };

    if ($inject) {
        no strict 'refs';
        *{"$mod\::$_"} = $action for qw/new init can isa does DOES meta options/;
        *{"$mod\::import"} = sub { return if $IGNORE_IMPORT; goto &$action };
    }

    if (my @bad = sort keys %params) {
        carp("Invalid options to '$class': " . join(', ' => @bad));
    }

    $action->() unless $IGNORE_IMPORT;
}

1;
