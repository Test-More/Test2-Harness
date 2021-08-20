package Test2::Harness::UI::Schema::Result::Coverage;
our $VERSION = '0.000077';
@Test2::Harness::UI::Schema::Result::Coverage::ISA = ('DBIx::Class::Core');
__PACKAGE__->table("coverage");

__END__

This package was added to replace the mostly-empty old version. Having the old
one in place caused the app to fail to start. This table is gone, but this
class is necessary.
