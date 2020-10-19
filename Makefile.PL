use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

my %WriteMakefileArgs = (
    NAME               => 'Test2::Harness::Renderer::JUnit',
    AUTHOR             => q{Todd E. Rinaldo <toddr@cpanel.net>},
    VERSION_FROM       => 'lib/Test2/Harness/Renderer/JUnit.pm',
    ABSTRACT_FROM      => 'lib/Test2/Harness/Renderer/JUnit.pm',
    LICENSE            => 'artistic_2',
    MIN_PERL_VERSION   => '5.010001',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    TEST_REQUIRES => {
        'Test::More'                => '0',
        'App::Yath::Tester'         => 0,
        "Test2::API"                => "1.302170",
        "Test2::V0"                 => "0.000127",
        "File::Temp"                => "0",
        "Data::Dumper"              => "0",
        "XML::Simple"               => "0",
        "Test2::Tools::Explain"     => 0,
        "Test2::Plugin::NoWarnings" => 0,
    },
    PREREQ_PM => {
        'Test2::Harness::Renderer'       => '1.000000',
        'Test2::Harness::Util::HashBase' => '1.000000',
        'XML::Generator'                 => 0,
        'File::Spec'                     => 0,
        'Storable'                       => 0,
        'XML::Generator'                 => 0,
        "Carp"                           => "0",
        "Cwd"                            => "0",
        "Exporter"                       => "0",
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES    => 'Test2-Harness-Renderer-JUnit-*' },
    META_MERGE => {
        resources => {
            license    => 'http://dev.perl.org/licenses/',
            bugtracker => 'https://github.com/cpanelinc/Test2-Harness-Renderer-JUnit/issues',
            repository => 'https://github.com/cpanelinc/Test2-Harness-Renderer-JUnit',
        }
    },
);

WriteMakefile(%WriteMakefileArgs);
