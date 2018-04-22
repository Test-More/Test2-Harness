requires "Carp" => "0";
requires "Crypt::Eksblowfish::Bcrypt" => "0";
requires "DBI" => "0";
requires "DBIx::Class::InflateColumn::DateTime" => "0";
requires "DBIx::Class::InflateColumn::Serializer" => "0";
requires "DBIx::Class::InflateColumn::Serializer::JSON" => "0";
requires "DBIx::Class::Schema::Loader" => "0";
requires "DBIx::Class::Tree::AdjacencyList" => "0";
requires "DBIx::Class::UUIDColumns" => "0";
requires "DBIx::QuickDB" => "0";
requires "Data::GUID" => "0";
requires "DateTime" => "0";
requires "File::ShareDir" => "0";
requires "IO::Uncompress::Bunzip2" => "0";
requires "IO::Uncompress::Gunzip" => "0";
requires "Importer" => "0.024";
requires "JSON::MaybeXS" => "0";
requires "List::Util" => "0";
requires "Plack::App::Directory" => "0";
requires "Plack::Builder" => "0";
requires "Router::Simple" => "0";
requires "Scalar::Util" => "0";
requires "Test2" => "1.302120";
requires "Test2::API" => "1.302120";
requires "Test2::Formatter::Test2::Composer" => "0";
requires "Test2::Harness" => "0.001049";
requires "Test2::Harness::Util::JSON" => "0";
requires "Test2::Harness::Util::UUID" => "0";
requires "Test2::Util::Facets2Legacy" => "0";
requires "Test2::V0" => "0.000097";
requires "Text::Xslate" => "0";
requires "Time::HiRes" => "0";
requires "parent" => "0";
requires "perl" => "5.008009";
suggests "Cpanel::JSON::XS" => "0";

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "0";
  requires "File::ShareDir::Install" => "0.06";
};

on 'develop' => sub {
  requires "Test::Pod" => "1.41";
};
