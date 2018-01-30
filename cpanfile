requires "Importer" => "0.024";
requires "JSON::MaybeXS" => "0";
requires "Test2" => "1.302120";
requires "Test2::API" => "1.302120";
requires "Test2::Harness" => "0.001049";
requires "Test2::V0" => "0.000097";
requires "perl" => "5.008009";
suggests "Cpanel::JSON::XS" => "0";

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "0";
  requires "File::ShareDir::Install" => "0.06";
};

on 'develop' => sub {
  requires "Test::Pod" => "1.41";
};
