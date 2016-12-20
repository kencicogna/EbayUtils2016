package ShipItEbayAPICall;

use strict;
use Moose;

use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;

use Cwd;
use DBI;
use XML::Simple qw(XMLin XMLout);
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;


#-------------------------------------------------------------------------------
# Attributes
#-------------------------------------------------------------------------------

# Package Info
has packageID           => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. User assigned package ID (not the ID automatically created by Stamps.com)
has environment         => ( is => 'rw', isa => 'Str', default=>'', trigger => \&_setHeaderValues );  # e.g. 'production' or anything else. Used to determine which ebay API to use
has apiURL              => ( is => 'rw', isa => 'Str', default=>'' );  # Set when environment is set
has firstname           => ( is => 'rw', isa => 'Str', default=>' ' );  # i.e. Recipient's first name
has lastname            => ( is => 'rw', isa => 'Str', default=>' ' );  # i.e. Recipient's last name
has ebay_item_id        => ( is => 'rw', isa => 'Str', default=>'' );  # 
has ebay_transaction_id => ( is => 'rw', isa => 'Str', default=>'' );  # 

# Actuals, returned from Stamps.com
has trackingNumber      => ( is => 'rw', isa => 'Str', default=>'' );  # returned from stamps in xml file
has actualPostageCost   => ( is => 'rw', isa => 'Num', default=>0  );  
																													 # returned from stamps in xml file
                                                           # TODO: Need to add SDCCost field too, to get the final cost
                                                           #       *IF* any Stamp.com service are used (being charged).
                                                           #       Currently not being used.
# API Call info
has callName            => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'CompleteSale'
has devName             => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'd57759d2-efb7-481d-9e76-c6fa263405ea'
has appName             => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'KenCicog-a670-43d6-ae0e-508a227f6008'
has certName            => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. '8fa915b9-d806-45ef-ad4b-0fe22166b61e'
has siteID              => ( is => 'rw', isa => 'Num', default=>0  );  # e.g. 0 (0 = USA)
has compatibilityLevel  => ( is => 'rw', isa => 'Int', default=>0  );  # e.g. '899'
has contentType         => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'text/xml'
has eBayAuthToken       => ( is => 'rw', isa => 'Str', default=>'' );  # Very long string of characters
                                                           # reads token from file, if file name is passed


#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------

sub sendRequest {
  my $self = shift;

  my $api_call_name = $self->callName;
  my $api_call_name_tag = $api_call_name . 'Request';

  # define the HTTP header
  my $objHeader = HTTP::Headers->new;
  $objHeader->push_header('X-EBAY-API-COMPATIBILITY-LEVEL' => $self->compatibilityLevel);
  $objHeader->push_header('X-EBAY-API-DEV-NAME'            => $self->devName );
  $objHeader->push_header('X-EBAY-API-APP-NAME'            => $self->appName );
  $objHeader->push_header('X-EBAY-API-CERT-NAME'           => $self->certName);
  $objHeader->push_header('X-EBAY-API-CALL-NAME'           => $self->callName);
  $objHeader->push_header('X-EBAY-API-SITEID'              => $self->siteID  );
  $objHeader->push_header('Content-Type'                   => $self->contentType);

  # Package info
  my $package_id     = $self->packageID;
  my $TrackingNumber = $self->trackingNumber;
  my $PostageCost    = $self->actualPostageCost;                       # Not being used....
  my $Name           = $self->firstname . ' ' . $self->lastname;       # Not being used....

  my $request_sent_attempts = 0;

  # Request hash
  my $r= {}; 
  $r->{WarningLevel}  = 'High';
  $r->{ItemID}        = $self->ebay_item_id;
  $r->{TransactionID} = $self->ebay_transaction_id;
  $r->{RequesterCredentials}->{eBayAuthToken} = $self->eBayAuthToken;
  $r->{Shipment}->{ShipmentTrackingDetails}->{ShipmentTrackingNumber} = $TrackingNumber;
  $r->{Shipment}->{ShipmentTrackingDetails}->{ShippingCarrierUsed}    = 'USPS';

  my $request_xml = XMLout( $r, NoAttr=>1, RootName=>undef, KeyAttr=>{} );
  $request_xml = <<END_REQUEST_XML;
<?xml version='1.0' encoding='utf-8'?>
<$api_call_name_tag xmlns="urn:ebay:apis:eBLBaseComponents">
$request_xml
</$api_call_name_tag>
END_REQUEST_XML


  RESEND_REQUEST:
  $request_sent_attempts++;

  # Make the call
  my $objRequest = HTTP::Request->new( 'POST', $self->apiURL, $objHeader, $request_xml);

  # Deal with the response
  my $objUserAgent = LWP::UserAgent->new;
  my $objResponse = $objUserAgent->request($objRequest);

  # Parse response object to get Acknowledgement 
  my $response_hash = XMLin( $objResponse->content );
  my $ack = $response_hash->{Ack};
  print "Response status : $ack\n";

  if (!$objResponse->is_error && $ack =~ /success/i ) {
    print "Status          : Successfully updated tracking number.\n";
    print "Object Content  :\n";
    print $objResponse->content;
  }
  else {
    print "Response msg.   : ", Dumper( $response_hash->{Errors} );
    print "Status          : ERROR updating tracking number... ";
    print $objResponse->error_as_HTML;

    # TODO
		#print $request_xml;

    # Resend update request
    if ( $request_sent_attempts < 3 ) {
      print "Attempting to resend update request.\n";
      # TODO: testing
      goto RESEND_REQUEST;
    }

    print "Status          : Failed. UPDATE TRACKING NUMBER MANUALLY!";
  }

} # end sendRequest()


sub _setTokenFromFile {
  # Set eBayAuthToken field based on file contents
  use File::Slurp;
  my ($self,$string) = @_;

  if ( -f $string ) {
    my $eBayAuthToken = read_file( $string ) or die "can't read token file: '$string'";
    $eBayAuthToken =~ s/^\s+//;
    $eBayAuthToken =~ s/\s+$//;
    $self->eBayAuthToken($eBayAuthToken);
  } 
  else {
    $self->eBayAuthToken($string);
  }
}


sub _setHeaderValues() {
  # Set all the header values based on the environment selected
  my ($self,$environment) = @_;

  if ( $environment =~ /production/i ) {
    # PRODUCTION
    $self->callName          ( 'CompleteSale' );
    $self->apiURL            ( 'https://api.ebay.com/ws/api.dll'      );
    $self->devName           ( 'd57759d2-efb7-481d-9e76-c6fa263405ea' );
    $self->appName           ( 'KenCicog-a670-43d6-ae0e-508a227f6008' );
    $self->certName          ( '8fa915b9-d806-45ef-ad4b-0fe22166b61e' );
    $self->siteID            ( 0          );
    $self->compatibilityLevel( '967'      );
    $self->contentType       ( 'text/xml' );

    $self->_setTokenFromFile ( 'cfg/ebay_api_production_token.txt' );
  }
  else {
    # DEVELOPMENT
    $self->callName          ( 'CompleteSale' );
    $self->apiURL            ( 'https://api.sandbox.ebay.com/ws/api.dll' );
    $self->devName           ( 'd57759d2-efb7-481d-9e76-c6fa263405ea'    );
    $self->appName           ( 'KenCicog-8d14-43e3-871a-5ff9825f4ca1'    );
    $self->certName          ( '288c8c46-75a9-46bb-a08e-80ca5305efd1'    );
    $self->siteID            ( 0          );
    $self->compatibilityLevel( '899'      );
    $self->contentType       ( 'text/xml' );

    $self->_setTokenFromFile ( 'cfg/ebay_api_development_token.txt' );
  }
}


1;


