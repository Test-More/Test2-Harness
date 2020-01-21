use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

my %WriteMakefileArgs = (
    NAME             => 'Test2::Harness::Renderer::JUnit',
    AUTHOR           => q{Todd E. Rinaldo <toddr@cpanel.net>},
    VERSION_FROM     => 'lib/Test2/Harness/Renderer/JUnit.pm',
    ABSTRACT_FROM    => 'lib/Test2/Harness/Renderer/JUnit.pm',
    LICENSE          => 'artistic_2',
    MIN_PERL_VERSION => '5.010001',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    TEST_REQUIRES => {
        'Test::More' => '0',
    },
    PREREQ_PM => {
        'Test2::Harness::Renderer' => '1.000000',
        'Test2::Harness::Util::HashBase' => '1.000000',
        'File::Spec' => 0,
        'Storable' => 0,
        'XML::Generator' => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Test2-Harness-Renderer-JUnit-*' },
    META_MERGE => {
        resources => {
            license    => 'http://dev.perl.org/licenses/',
            bugtracker => 'https://github.com/cpanelinc/Test2-Harness-Renderer-JUnit/issues',
            repository => 'https://github.com/cpanelinc/Test2-Harness-Renderer-JUnit',
        }
    },
);

WriteMakefile(%WriteMakefileArgs);
