package ShipItEbayAPICallGetMyEbaySelling;

use utf8;
use strict;
use Moose;

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
has callName            => ( is => 'rw', isa => 'Str', default=>'GetMyeBaySelling' ); # sets request xml 
has devName             => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'd57759d2-efb7-481d-9e76-c6fa263405ea'
has appName             => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'KenCicog-a670-43d6-ae0e-508a227f6008'
has certName            => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. '8fa915b9-d806-45ef-ad4b-0fe22166b61e'
has siteID              => ( is => 'rw', isa => 'Num', default=>0  );  # e.g. 0 (0 = USA)
has compatibilityLevel  => ( is => 'rw', isa => 'Int', default=>967);  # e.g. '705'
has contentType         => ( is => 'rw', isa => 'Str', default=>'' );  # e.g. 'text/xml'
has eBayAuthToken       => ( is => 'rw', isa => 'Str', default=>'' );  # Very long string of characters
has HTTPHeaders         => ( is => 'rw', isa => 'Object'           );
has requestXML          => ( is => 'rw', isa => 'Str', default=>'' );  # XML 

# Result
has orderIDs            => ( is => 'rw', isa => 'ArrayRef'          );  # Order ID array reference


#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------

sub _setCallNameSpecificInfo {
  my $self              = shift;
  my $api_call_name     = $self->callName;
  my $api_call_name_tag = $api_call_name . 'Request';
  my $eBayAuthToken     = $self->eBayAuthToken;
  my $version           = $self->compatibilityLevel;

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
<Version>$version</Version>
  <SoldList>
    <Include>true</Include>
    <DurationInDays>20</DurationInDays>
    <IncludeNotes>true</IncludeNotes>
    <OrderStatusFilter>AwaitingShipment</OrderStatusFilter>
    <Pagination>
      <EntriesPerPage>100</EntriesPerPage>
      <PageNumber>__PAGE_NUMBER__</PageNumber>
    </Pagination>
    <Sort>BuyerUserID</Sort>
  </SoldList>
</$api_call_name_tag>
END_REQUEST_XML

  $self->requestXML( $requestXML );
}


sub sendRequest {
  my $self = shift;

  $self->_setCallNameSpecificInfo;  # sets request xml

  ################################################################################
  # Get list of all item id's
  ################################################################################
  my $all_items = [];
  my $pagenumber=1;
  my $maxpages=$pagenumber;         #TODO: if i used a do/while loop I wouldn't have to do this

  while ( $pagenumber <= $maxpages ) {
    my $request = $self->requestXML;
    $request =~ s/__PAGE_NUMBER__/$pagenumber/g;
    my $response_hash = $self->submit_request( $self->callName, $request );    # Get list of order ID's

    for my $orderTxn  ( @{$response_hash->{SoldList}->{OrderTransactionArray}->{OrderTransaction}} ) {     # Get each item
      if ( ! defined $orderTxn->{Transaction} && ! defined $orderTxn->{Order} ) {
        print Dumper($orderTxn);
        die "\n\nERROR: Undefined Transaction and Order Tags. One must exist\n";
      }

      # Get Items from 'Transaction' tag if they did NOT use shoping cart (I Think)
      #
      for my $txn  ( @{$orderTxn->{Transaction}} ) {
        # get fullsized image URL if (1) there's no image, (2) only the thumbnail, or (3) is a variation
        # TODO: Another option is to get the image url from the TTY_STORAGE_LOCATION table
        next if ( defined $txn->{ShippedTime} );
        push( @$all_items, { OrderLineItemID=>$txn->{OrderLineItemID}, GalleryURL=>'' } );
      }

      # Get Items from 'Order' tag if they DID use shopping cart (I Think)
      #
      for my $order  ( @{$orderTxn->{Order}} ) {     
        for my $txn ( @{$order->{TransactionArray}->{Transaction}} ) {
          # get fullsized image URL if (1) there's no image, (2) only the thumbnail, or (3) is a variation
          # TODO: Another option is to get the image url from the TTY_STORAGE_LOCATION table
          next if ( defined $txn->{ShippedTime} );
          push( @$all_items, { OrderLineItemID=>$txn->{OrderLineItemID}, GalleryURL=>'' } );
        }
      }

    }

    if ( ! defined $response_hash->{SoldList}->{PaginationResult}->{TotalNumberOfPages} ) {
      print Dumper($request);
      print Dumper($response_hash);
      print Dumper($self);
      print "\n\nERROR: Maxpages can not be determined";
      exit;
    }

    if ( $pagenumber==1 ) {
      die if ( ! defined $response_hash->{SoldList}->{PaginationResult}->{TotalNumberOfPages} );
      $maxpages = $response_hash->{SoldList}->{PaginationResult}->{TotalNumberOfPages};
    }

    print STDERR "\nPage: $pagenumber / $maxpages";
    $pagenumber++;
  }

  $self->orderIDs( $all_items );

} # end sendRequest


sub submit_request {
	my ($self, $api_call_name, $request_xml) = @_;
  my $objHeader = $self->HTTPHeaders;
  my ($objRequest, $objUserAgent, $objResponse);
  my $request_sent_attempts = 0;
  my $response_hash = {};

	$objHeader->remove_header('X-EBAY-API-CALL-NAME');
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
     ForceArray=>['InternationalShippingServiceOption','ShippingServiceOptions','ShipToLocation','Variation','NameValueList','Order','Transaction','OrderTransaction','VariationSpecificPictureSet','PictureURL' ] );
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
    
    confess "ERROR: request was unsuccessful CONTENT=$content";
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
      </$api_call_name_tag>
END_REQUEST_XML

  $request =~ s/__ItemID__/$itemid/;

  my $r = $self->submit_request( $api_call_name, $request );    # Get list of order ID's

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
