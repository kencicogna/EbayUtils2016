#!/usr/bin/perl -w 

# NOTES:
#
#   Add to shipping program - 
#     If multiple items are purchased, calculate if it's cheaper to ship two 
#     items seperately 1st class, rather than 1 box priority

use strict;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request;
use HTTP::Headers;
use DBI;
use XML::Simple qw(XMLin XMLout);
use Date::Calc 'Today';
use Data::Dumper 'Dumper';			$Data::Dumper::Sortkeys = 1;
use File::Copy qw(copy move);
use POSIX;
use Getopt::Std;
use Storable 'dclone';

use lib '../cfg';
use EbayConfig;


###################################################
# EBAY API INFO                                   #
###################################################

# define the HTTP header
my $header = $EbayConfig::ES_http_header;

# eBayAuthToken
my $eBayAuthToken = $EbayConfig::ES_eBayAuthToken;

#
# XML Request templates
#

# GetItem call - get detail info about a specific listing
my $request_getitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<ItemID>__ItemID__</ItemID>
</GetItemRequest>
END_XML

# GetMyEbaySelling call - gets list of Active listing
my $request_getmyebayselling = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetMyeBaySellingRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<ActiveList>
	<Include>true</Include>
	<Pagination>
		<EntriesPerPage>200</EntriesPerPage>
		<PageNumber>__PAGE_NUMBER__</PageNumber>
	</Pagination>
</ActiveList>
</GetMyeBaySellingRequest>
END_XML


################################################################################
# Make API Calls
################################################################################
my $request;
my $response_hash;


################################################################################
# GetItem          PASSED
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetItem');

$request = $request_getitem_default;
$request =~ s/__ItemID__/371690543832/;  # Puffer Snake eBay Item ID

# $response_hash = submit_request( $request, $header );


################################################################################
# GetTokenStatus   PASSED
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetTokenStatus');

$request = <<END_XML;
<?xml version="1.0" encoding="utf-8"?>
<GetTokenStatusRequest xmlns="urn:ebay:apis:eBLBaseComponents">
  <RequesterCredentials>
    <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
  </RequesterCredentials>
  <WarningLevel>High</WarningLevel>
</GetTokenStatusRequest>
END_XML

# print "\n\nREQUEST:\n\n", Dumper($request);
# $response_hash = submit_request( $request, $header );
# print "\n\nRESPONSE:\n\n", Dumper($response_hash);


################################################################################
# GetTokenStatus    FAILED
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetAccount');

$request = <<END_XML;
<?xml version="1.0" encoding="utf-8"?>
<GetAccountRequest xmlns="urn:ebay:apis:eBLBaseComponents">
  <RequesterCredentials>
    <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
  </RequesterCredentials>
  <AccountEntrySortType>AccountEntryFeeTypeAscending</AccountEntrySortType>
  <AccountHistorySelection>LastInvoice</AccountHistorySelection>
</GetAccountRequest>
END_XML

# print "\n\nREQUEST:\n\n", Dumper($request);
# $response_hash = submit_request( $request, $header );
# print "\n\nRESPONSE:\n\n", Dumper($response_hash);


################################################################################
# Get all Ebay flat rate shipping discount profiles
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetShippingDiscountProfiles');
$request = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetShippingDiscountProfilesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
</GetShippingDiscountProfilesRequest>
END_XML

# $response_hash = submit_request( $request, $header );
# print "\n\nREQUEST:\n\n",Dumper($request);
# print "\n\nRESPONSE:\n\n",Dumper($response_hash);


################################################################################
# GetMyeBaySelling
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetMyeBaySelling');

my @all_items;
my $pagenumber=1;
my $maxpages=1000000;

while ( $pagenumber <= $maxpages ) {
  $request = $request_getmyebayselling;
  $request =~ s/__PAGE_NUMBER__/$pagenumber/;
  $response_hash = submit_request( $request, $header );

  print Dumper($response_hash); exit;

  for my $i ( @{$response_hash->{ActiveList}->{ItemArray}->{Item}} ) {
    push(@all_items, $i->{ItemID});
  }
  if ($pagenumber==1) {
    $maxpages = $response_hash->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
  }
  $pagenumber++;
}



exit;

####################################################################################################
sub submit_request {
	my ($request, $objHeader,$return_error) = @_;
  my ($objRequest, $objUserAgent, $objResponse);
  my $request_sent_attempts = 0;

  RESEND_REQUEST:
  $request_sent_attempts++;

  # Create UserAgent and Request objects
  $objUserAgent = LWP::UserAgent->new;
  $objRequest   = HTTP::Request->new(
    "POST",
    "https://api.ebay.com/ws/api.dll",
    $objHeader,
    $request
  );

	#print "\n objHeader : ",Dumper($objHeader);
	#print "\n request   : ",Dumper($request);
	#print "\n objRequest: ",Dumper($objRequest);

  # Submit Request
  $objResponse = $objUserAgent->request($objRequest);		# SEND REQUEST

  # Parse Response object to get Acknowledgement 
	my $content =  $objResponse->content;

	my $response_hash;
  if (!$objResponse->is_error ) {
	  $response_hash = XMLin( "$content",  ForceArray=>['InternationalShippingServiceOption','ShippingServiceOptions','ShipToLocation','Variation'] );
  }
  else {
    print Dumper($objResponse);
    die "\n\nERROR: API call failed";
  }

  my  $ack = $response_hash->{Ack} || 'No acknowledgement found';

  if ($ack =~ /success/i ) {
    return $response_hash;
  }
  else {
		print "\n\n";
    print "\nStatus          : FAILED";
	  print "\nRequest         : ", Dumper( $request );
    print "\nResponse msg.   : ", Dumper( $response_hash->{Errors} );
		#print $objResponse->error_as_HTML;

    # Resend update request
    if ( $request_sent_attempts < 1 ) {
      print  "Attempting to resend update request.\n";
      goto RESEND_REQUEST;
    }

		# Return error information if requested
		if ( $return_error ) { 
			return $response_hash->{Errors}; 
		} else { 
			die; 
		}

  }

} # end submit_request()

