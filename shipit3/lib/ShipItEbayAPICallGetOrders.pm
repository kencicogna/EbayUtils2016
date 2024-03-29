package ShipItEbayAPICallGetOrders;

use utf8;
use strict;
use Moose;
use ShipItEbayAPICallGetMyEbaySelling;

use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;

use Carp;
use Cwd;
use DBI;
use XML::Simple qw(XMLin XMLout);
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;


#-------------------------------------------------------------------------------
# Attributes
#-------------------------------------------------------------------------------

# Config info
has environment         => ( is => 'rw', isa => 'Str', default=>'', trigger => \&_setHeaderValues );  # e.g. 'production' or not.
has apiURL              => ( is => 'rw', isa => 'Str', default=>'' );  # Gets set when environment is set

# API Call info
has callName            => ( is => 'rw', isa => 'Str', default=>'GetOrders' ); # sets request xml 
has devName             => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'd57759d2-efb7-481d-9e76-c6fa263405ea'
has appName             => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'KenCicog-a670-43d6-ae0e-508a227f6008'
has certName            => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. '8fa915b9-d806-45ef-ad4b-0fe22166b61e'
has siteID              => ( is => 'rw', isa => 'Num', default=>0  );  # e.g. 0 (0 = USA)
has compatibilityLevel  => ( is => 'rw', isa => 'Int', default=>1235); # as of 2022/01/18
has contentType         => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'text/xml'
has eBayAuthToken       => ( is => 'rw', isa => 'Str', default=>'' );  # Very long string of characters
has HTTPHeaders         => ( is => 'rw', isa => 'Object'           );
has requestXML          => ( is => 'rw', isa => 'Str', default=>'' );  # XML 

# Input
has orderIDs            => ( is => 'rw', isa => 'ArrayRef'          );  # Order ID array reference (get from ShipItEbayAPICallGetMyEbaySelling)

# Result
has orders              => ( is => 'rw', isa => 'ArrayRef'          );  # Order details array reference
has image_lookup        => ( is => 'rw', isa => 'HashRef'           );  # 


#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------

sub _setCallNameSpecificInfo {
  my $self              = shift;
  my $api_call_name     = $self->callName;
  my $api_call_name_tag = $api_call_name . 'Request';
  my $eBayAuthToken     = $self->eBayAuthToken;

  # define the HTTP header
  my $objHeader = HTTP::Headers->new;
  $objHeader->push_header('X-EBAY-API-COMPATIBILITY-LEVEL' => $self->compatibilityLevel);
  $objHeader->push_header('X-EBAY-API-DEV-NAME'            => $self->devName );
  $objHeader->push_header('X-EBAY-API-APP-NAME'            => $self->appName );
  $objHeader->push_header('X-EBAY-API-CERT-NAME'           => $self->certName);
  $objHeader->push_header('X-EBAY-API-CALL-NAME'           => $api_call_name );
  $objHeader->push_header('X-EBAY-API-SITEID'              => $self->siteID  );
  $objHeader->push_header('X-EBAY-API-DETAIL-LEVEL'        => 0 );
  $objHeader->push_header('Content-Type'                   => $self->contentType);

  $self->HTTPHeaders( $objHeader );

  my $requestXML = <<END_REQUEST_XML;
      <?xml version="1.0" encoding="utf-8"?>
      <$api_call_name_tag xmlns="urn:ebay:apis:eBLBaseComponents">
      <RequesterCredentials>
        <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
      </RequesterCredentials>
      <WarningLevel>High</WarningLevel>
      <OrderIDArray>
      __ORDER_ID_ARRAY__
      </OrderIDArray>
      </$api_call_name_tag>
END_REQUEST_XML

  $self->requestXML( $requestXML );
}


sub sendRequest {
  my $self = shift;

  # strip out order ID's and build image lookup
  my $all_order_ids = [];
  my $image_lookup  = {};
  for my $i ( @{ $self->orderIDs } ) {
     push( @$all_order_ids, $i->{OrderLineItemID} );
     $image_lookup->{ $i->{OrderLineItemID} } = $i->{GalleryURL};
  }
#  print Dumper($image_lookup); exit;

  $self->_setCallNameSpecificInfo;  # sets request xml

  my ($cnt,$icnt);
  my $pages = POSIX::floor(@$all_order_ids / 100);
  my $total_pages = $pages + 1;

  print "\n\nGetting Orders ( $total_pages pages )";

  my $all_orders = [];
  for my $page ( 0..$pages ) {
    my @all_orderIDs;

    my $start = $page * 100;
    my $end   = $start + 100;
    $end = @$all_order_ids-1 if ( $end > @$all_order_ids-1 );  # dont go past the end of the array (-1 because it's zero indexed)

    for my $n ( $start..$end ) {
      push( @all_orderIDs, "<OrderID>$all_order_ids->[$n]<\/OrderID>" );
    }
    my $all_orderIDs = join( "\n", @all_orderIDs );

    print "\nall_order_ids",Dumper($all_order_ids);
    print "\nall_orderIDs",Dumper(\@all_orderIDs);

    # Get detailed info from ebay on this itemID
    my $request = $self->requestXML;
    $request =~ s/__ORDER_ID_ARRAY__/$all_orderIDs/;

    #print "\n\nREQUEST:\n\n",Dumper($request);
    #my $response_hash = $self->submit_request( $request );
    my $api_call_name = 'GetOrders';
    my $response_hash = $self->submit_request( $api_call_name, $request );    # Get list of order ID's
    #print "\n\nRESPONSE:\n\n",Dumper($response_hash);

    if ( ! defined $response_hash->{OrderArray}->{Order} ) {
      print Dumper($response_hash);
      die "ERROR: No Order tag returned";
    }

    # Loop over order line items 
    for my $order ( @{$response_hash->{OrderArray}->{Order}} ) { 
      push ( @$all_orders, $order );

      # clean up strange data at order level
      $order->{ShippingAddress}->{Street2} = '' if ( ref($order->{ShippingAddress}->{Street2}) );
      $order->{ShippingAddress}->{Street3} = '' if ( ref($order->{ShippingAddress}->{Street3}) );
      $order->{ShippingAddress}->{StateOrProvince}   = '' if ( ref($order->{ShippingAddress}->{StateOrProvince}) );
      $order->{ShippingAddress}->{Phone} = '' if ( ref($order->{ShippingAddress}->{Phone}) );

      for my $t ( @{ $order->{TransactionArray}->{Transaction} } ) {
        my $var;
        if ( $t->{Variation} ) {
          $var = $t->{Variation}->[0]->{VariationSpecifics}->{NameValueList}->[0]->{Value};
        }
        #$t->{GalleryURL} = $image_lookup->{ $t->{OrderLineItemID} };
        if ( ! defined $t->{Item}->{PictureDetails}->{GalleryURL} or 
             $t->{Item}->{PictureDetails}->{GalleryURL} =~ m#^http://thumbs# or
             $var) {
          print "\nGetting image for: $t->{Item}->{Title}";
          $t->{GalleryURL} = $self->getImage( $t->{Item}->{ItemID}, $var );
        }
      }
    }

  }

  $self->orders( $all_orders );

} # end sendRequest


sub submit_request {
	my ($self, $api_call_name, $request_xml) = @_;
  my $objHeader = $self->HTTPHeaders;
  my ($objRequest, $objUserAgent, $objResponse);
  my $request_sent_attempts = 0;
  my $response_hash = {};

	$objHeader->remove_header('X-EBAY-API-CALL-NAME');
	#$objHeader->push_header  ('X-EBAY-API-CALL-NAME' => $self->callName);
	$objHeader->push_header  ('X-EBAY-API-CALL-NAME' => $api_call_name);

  RESEND_REQUEST:
  $request_sent_attempts++;

  # Create UserAgent and Request objects
  $objUserAgent = LWP::UserAgent->new;
  $objUserAgent->timeout(300);
  $objRequest   = HTTP::Request->new(
    "POST",
    $self->apiURL,
    $objHeader,
    $request_xml
  );

  # Submit Request
  $objResponse = $objUserAgent->request($objRequest);		# SEND REQUEST

  # Try again if it failed
  if ( $objResponse->is_error ) {
		print "\n\n";
    print  "Response msg.   : ", Dumper( $response_hash->{Errors} );
    print  "Status          : FAILED";
    print  $objResponse->error_as_HTML;

    # Resend update request
    if ( $request_sent_attempts <= 3 ) {
      print  "Attempting to resend update request.\n";
      goto RESEND_REQUEST;
    }

    die "\n request   : ",Dumper($request_xml);
  }

  # Parse Response object to get Acknowledgement 
	my $content =  $objResponse->content;
  eval {
	   $response_hash = XMLin( "$content",  
      ForceArray=>['InternationalShippingServiceOption','ShippingServiceOptions','ShipToLocation','Variation',
                   'NameValueList','Order','Transaction','VariationSpecificPictureSet','PictureURL' ] );
	    #my $response_hash = XMLin( $content );
  };
  if ($@) {
    print "\n\nERROR in submit_request():  XMLin could not parse \$content";
    print "\n\n  \$content = '$content'";
    print "\n\n  objRequest = ",Dumper($objRequest);
    die;
  }

  my $ack = $response_hash->{Ack} || ' ';

  if ($ack =~ /success/i ) {
    return $response_hash;
  }
  else {
    print "\n\nREQUEST:\n",Dumper( $objRequest );
    print "\n\nRESPONSE:\n",Dumper( $objResponse );
    print "\n\nXML RETURNED FROM EBAY:\n",Dumper( $response_hash );
    print "\n\nREQUEST XML   : ",Dumper($request_xml);

    confess "ERROR: request was unsuccessful";
  }

} # end submit_request()


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
    $self->apiURL            ( 'https://api.ebay.com/ws/api.dll'      );
    $self->devName           ( 'd57759d2-efb7-481d-9e76-c6fa263405ea' );
    $self->appName           ( 'KenCicog-a670-43d6-ae0e-508a227f6008' );
    $self->certName          ( '8fa915b9-d806-45ef-ad4b-0fe22166b61e' );
    $self->siteID            ( 0          );
    $self->compatibilityLevel( '967'      );
    $self->contentType       ( 'text/xml' );

    $self->_setTokenFromFile ( 'cfg/ebay_api_production_token.txt' );
    
    # Get list of order ID's
    my $objOrderIDList = ShipItEbayAPICallGetMyEbaySelling->new( environment=>'production' );
    $objOrderIDList->sendRequest(); # TODO: maybe this should be called automatically when the object is created?
                                    #       also, maybe should be renamed? loadOrderIDs()?
    $self->orderIDs( $objOrderIDList->orderIDs );
  }
  else {
    # DEVELOPMENT
    $self->apiURL            ( 'https://api.sandbox.ebay.com/ws/api.dll' );
    $self->devName           ( 'd57759d2-efb7-481d-9e76-c6fa263405ea'    );
    $self->appName           ( 'KenCicog-8d14-43e3-871a-5ff9825f4ca1'    );
    $self->certName          ( '288c8c46-75a9-46bb-a08e-80ca5305efd1'    );
    $self->siteID            ( 0          );
    $self->compatibilityLevel( '967'      );
    $self->contentType       ( 'text/xml' );

    $self->_setTokenFromFile ( 'cfg/ebay_api_development_token.txt' );
  }

}

sub getImage {

  # TODO: This only gets the gallery image, it should also get the variation image

  my $self = shift;
  my $itemid = shift;
  my $variation_name = @_ ? shift : '';

  my $api_call_name     = 'GetItem';
  my $api_call_name_tag = 'GetItemRequest';
  my $eBayAuthToken     = $self->eBayAuthToken;

  my $request = <<END_REQUEST_XML;
      <?xml version="1.0" encoding="utf-8"?>
      <$api_call_name_tag xmlns="urn:ebay:apis:eBLBaseComponents">
      <RequesterCredentials>
        <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
      </RequesterCredentials>
      <WarningLevel>High</WarningLevel>
      <ItemID>__ItemID__</ItemID>
      <OutputSelector>Item.PictureDetails</OutputSelector>
      <OutputSelector>Item.Variations.Pictures</OutputSelector>
      </$api_call_name_tag>
END_REQUEST_XML

  $request =~ s/__ItemID__/$itemid/;

#   print "\n\n\nGET IMAGE - VAR NAME:  $variation_name";
#   print "\n\n\nGET IMAGE - ITEM ID:  $itemid";
#   print "\n\n\nGET IMAGE - XML: $request";
#   die;

  my $r = $self->submit_request( $api_call_name, $request );    # Get list of order ID's
# my $r={};

  my $variation_pic_url;
  if ( defined $r->{Item}->{Variations}->{Pictures}->{VariationSpecificPictureSet} ) {
    for my $vps ( @{$r->{Item}->{Variations}->{Pictures}->{VariationSpecificPictureSet}} ) {
      if ( $vps->{VariationSpecificValue} eq $variation_name ) {
        $variation_pic_url = $vps->{PictureURL}->[0]; # 0 is the main variation pic (there can be more than one image)
      }
    }
  }

  return $variation_pic_url ? $variation_pic_url : $r->{Item}->{PictureDetails}->{GalleryURL};
}


1;
