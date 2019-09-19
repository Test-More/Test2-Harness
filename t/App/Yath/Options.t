use Test2::V0 -target => 'App::Yath::Options';
# HARNESS-NO-FORK

BEGIN { $CLASS->import() }

imported_ok qw/options option include_options/;

isa_ok(options(), ['App::Yath::Options::Instance'], "Got an options instance");
is(options(),              exact_ref(options()), "Always get the same instance");
is(__PACKAGE__->options(), exact_ref(options()), "options() can be called on package as method");

my $opt = option foo => (type => 's', prefix => 'xxx');

is(
    $opt,
    {
        prefix => 'xxx',
        field  => 'foo',
        name   => 'xxx-foo',
        type   => 's',

        trace => [__PACKAGE__, __FILE__, T()],

        category    => 'NO CATEGORY - FIX ME',
        description => 'NO DESCRIPTION - FIX ME',
    },
    "Created expected option"
);

is(
    options(),
    {
        all      => [exact_ref($opt)],
        lookup   => {xxx => {foo => exact_ref($opt)}},
        cmd_list => [exact_ref($opt)],
        pre_list => [],
        settings => {},
    },
    "Added option as expected"
);

package My::Child;
use Test2::V0 -target => 'App::Yath::Options';

$CLASS->import();

ref_is_not(options(), main->options(), "Child class gets a new instance");

is(options()->all, [], "No options to start with");

include_options('main');

is(
    options()->all(),
    [$opt],
    "included options from 'main'"
);

my $opt2 = option(bar => (type => 's', prefix => 'xxx'));
my $opt3 = option(baz => (type => 's', prefix => 'xxx'));

is(options()->all, [$opt, $opt2, $opt3], "Child has parent options and its own");
is(main->options()->all, [$opt], "Parent does not get childs options");

package My::Other::Child;
use Test2::V0 -target => 'App::Yath::Options';
$CLASS->import();

include_options('My::Child', sub {
    my ($opt) = @_;

    return 0 if $opt->name =~ m/bar/;
    return 1;
});

is(options()->all(), [$opt, $opt3], "Filtered an option out during include");

done_testing;
