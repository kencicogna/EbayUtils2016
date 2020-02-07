
use strict;
use SOAP::Lite;
use Data::Dumper 'Dumper';

use lib 'lib';
use EndiciaAPICall;




my $environmnet = 'development';
my $pkg = getPackage();
my $postal_cfg = '';

my $objEndiciaCall = EndiciaAPICall->new( environment=>$environment );

print "\n\nBEFORE:\n\n", Dumper($objEndiciaCall);

eval {
  print "\ncalling api...\n";
  #$objEndiciaCall->PrintLabel( $self->{pkg}, $self->{postal_cfg} );
};

if($@) {
  die "\n\nERROR printing label:  $@\n\n";
}


print "\n\nAFTER:\n\n", Dumper($objEndiciaCall);


if ( ! $objEndiciaCall->TrackingNumber or ! $objEndiciaCall->ActualPostageCost ) {
  print "\n\nERROR: API call did not return tracking number and shipping cost.\n\n"; # Input to postage software
}





sub getPackage {
  my $p = {
    mailclass         => 'CommercialePacket',
    mailpiece         => '',
    total_weight__oz  => 1,
    date_advance      => 0,
    firstname         => 'ken',
    lastname          => 'cicogna',
    company           => '',
    addressline1      => '7 park road ct.',
    city              => 'lombard',
    state             => 'IL',
    zip               => '60148',
    countryname       => 'United States',
    country           => 'US',
    phonenumber       => '',
    emailaddress      => '',

    total_price       => 5.55,
    dom_intl_flag     => 'D',
  };

  return $p;
}
