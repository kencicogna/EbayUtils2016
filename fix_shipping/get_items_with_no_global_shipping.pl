#!/usr/bin/perl -w 

use strict;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request;
use HTTP::Headers;
use HTML::Restrict;
use DBI;
use XML::Simple qw(XMLin XMLout);
use Date::Calc 'Today';
use Data::Dumper 'Dumper';			$Data::Dumper::Sortkeys = 1;
use File::Copy qw(copy move);
use POSIX;
use Getopt::Std;
use Storable 'dclone';

my %opts;
getopts('i:raDI:O:A',\%opts);
# -i <ebay item ID>		- perform operations on this single item
# -a                  - perform operations on all items
# -r 									- revise item(s)
# -D                  - Debug/verbose mode. 
# -I <filename>       - Input filename. csv format (same as output. PUT NEW VALUE IN THE "TOTAL SHIPPING COST" column)
# -O <filename>       - output filename base. default is 'product_import'
my @item_list;
my $process_all_items = 0;

if ( defined $opts{i} ) {
	@item_list = split(',',$opts{i});
}
elsif ( defined $opts{a} ) {
  $process_all_items = 1;
}
else {
	die "must supply either option '-i <item id>' or '-a' option";
}

my $REVISE_ITEM = defined $opts{r} ? 1 : 0;
my $DEBUG       = defined $opts{D} ? 1 : 0;
my $infile      = defined $opts{I} ? $opts{I} : '';
my $outfile     = defined $opts{O} ? $opts{O} : 'dump';
my $ReturnAll   = defined $opts{A} ? 1 : 0;
my $maxpage     = defined $opts{m} ? $opts{m} : 0;


###################################################
# EBAY API INFO                                   #
###################################################

my $header = HTTP::Headers->new;
$header->push_header('X-EBAY-API-COMPATIBILITY-LEVEL' => '929');
$header->push_header('X-EBAY-API-DEV-NAME'  => 'd57759d2-efb7-481d-9e76-c6fa263405ea');
$header->push_header('X-EBAY-API-APP-NAME'  => 'KenCicog-a670-43d6-ae0e-508a227f6008');
$header->push_header('X-EBAY-API-CERT-NAME' => '8fa915b9-d806-45ef-ad4b-0fe22166b61e');
$header->push_header('X-EBAY-API-CALL-NAME' => '');                                       # Supply call name to submit_request() 
$header->push_header('X-EBAY-API-SITEID'    => '0');                                      # 0 => usa
$header->push_header('Content-Type'         => 'text/xml');

# eBayAuthToken
my $eBayAuthToken = 'AgAAAA**AQAAAA**aAAAAA**CQTJVA**nY+sHZ2PrBmdj6wVnY+sEZ2PrA2dj6wHlIKoCZCBogmdj6x9nY+seQ**4EwAAA**AAMAAA**IjIgU4Mg/eixJ7OQDRd60pU4NWyjtHgmki3+78wP5Vdt8qXeUz9lAbiDgkWaTbHHxBS2J+GvPSZZ9c+24CHqWIxORvV0OK1M176YGUAUPY7YXq8Z2XSTUp+pmq7In/SjzNc17Aqg+CUZsYDn1mnyoRGyW3rT5uk6TtCStBcckV1q55Jg0JomVxUtC68NPC+4JDCqOEqHVOok7pTR8dNa7wTZiSZCoKodX7c8wnBStPkGHhw3G3ogeU0FmKudl1IMsV1zUlJ0E5dCq9GF/2wxgQQAdH29RXcVUHKDE5zAXSmUIvrmIRKG2xDOnxUSjsRMQJZ8dN/wEKXtjQK4NYCBqwmqo+7uMsUwbqjF6X320t/eksCLbG8tL+QtLN9PwrpbAUnnMHnn/LI+sEb1BaFHBI0O9eqYKJII/bVaYwFNilqq4qe1wR+qF2Ge9Fa6jYvdKMwhVvYZmily6mIDhJEX4VUQ3B9wx6tx6Bnm49/2LNblVY+toRI+rqdMnjVAQTXPeWzxmUqSK4Ql0Jn7pm0ul7v9Zt9/LYNRpjId7NoEC//q/5rvBxGIBSLe3KzrSR2r/Xuu9IMfrJbq3bvoMBpgr5Iy7+K2vXPmfXkQ3VuXocoAJIvuZTrSLIY6DSqfdc5oxk0RObGcShP+grojI1FpWGULDDYM5Uxlbj3FNSGc7X/U2MslXt0dZ5Ao0dtf4oz63oEHQV1sfEToouUEhML7Sz9exfEfZy35LqR6RuTOXDyTG1gFweFCkK6F54eZgdLZ';

# Get all items
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
#<OutputSelector>ItemID PaginationResult</OutputSelector>

# Get all info about one item
my $request_getitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
  <RequesterCredentials>
    <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
  </RequesterCredentials>
  <WarningLevel>High</WarningLevel>
  __DETAIL_LEVEL__
  <ItemID>__ItemID__</ItemID>
  <IncludeItemSpecifics>TRUE</IncludeItemSpecifics>
</GetItemRequest>
END_XML


###########################################################
# END EBAY API INFO                                       #
###########################################################

my $request;
my $response_hash;

################################################################################
# Get list of all item id's
################################################################################
my @all_items;
my $pagenumber=1;
my $maxpages=1000000;

if ( ! $process_all_items ) {
	push(@all_items,@item_list);
}
else {
  while ( $pagenumber <= $maxpages ) {
    $request = $request_getmyebayselling;
    $request =~ s/__PAGE_NUMBER__/$pagenumber/;
    $response_hash = submit_request( 'GetMyeBaySelling', $request, $header );
    for my $i ( @{$response_hash->{ActiveList}->{ItemArray}->{Item}} ) {
      push(@all_items, $i->{ItemID});
    }
    if ($pagenumber==1) {
      $maxpages = $response_hash->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
    }

    last if ( $pagenumber == $maxpage );

    $pagenumber++;
  }
}

my $all_items_count = scalar @all_items;

my $all_cats = {};
my $all_listings = {};

################################################################################
# Loop over each item (active on eBay)
################################################################################
open my $ofh, '>', 'shipping_errors.txt';
for my $item_id ( reverse @all_items ) {
  # Get detailed info from ebay on this itemID
  $request = $request_getitem_default;
  if ( $ReturnAll ) {
    $request =~ s#__DETAIL_LEVEL__#<DetailLevel>ReturnAll</DetailLevel>#;
  } else {
    $request =~ s#__DETAIL_LEVEL__##;
  }
  $request =~ s/__ItemID__/$item_id/;
  my $ebayResponse = submit_request( 'GetItem', $request, $header );
  my $ebayListing = $ebayResponse->{Item};

  print Dumper($ebayListing) if $DEBUG;

  if ( $DEBUG ) {
    print Dumper( $ebayListing->{ShipToLocations} );
    print Dumper( $ebayListing->{ShippingDetails}->{ExcludeShipToLocation} );
  }

  my $excl = defined $ebayListing->{ShippingDetails}->{ExcludeShipToLocation}
                   ? join( ',', @{ $ebayListing->{ShippingDetails}->{ExcludeShipToLocation} } )
                   : '';

  if ( $ebayListing->{ShipToLocations} ne "Worldwide" or  ($excl ne "RU,BR" and $excl ne "BR,RU") ) {
    print $ofh "\n$ebayListing->{Title}";
  }

}

close $ofh;
print "\n\n";
exit;

####################################################################################################

sub submit_request {
	my ($call_name, $request, $objHeader) = @_;
  my ($objRequest, $objUserAgent, $objResponse);
  my $request_sent_attempts = 0;

	$header->remove_header('X-EBAY-API-CALL-NAME');
	$header->push_header  ('X-EBAY-API-CALL-NAME' => $call_name);

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
	my $response_hash = XMLin( "$content",  
      ForceArray=>['Variation','NameValueList','NameRecommendation','ValueRecommendation','ExcludeShipToLocation' ] );
	#my $response_hash = XMLin( $content );
  my $ack = $response_hash->{Ack};

  if (!$objResponse->is_error && $ack =~ /success/i ) {
		#print "\n\n";
		#print  "Status          : Success\n";
		#print  "Object Content  :\n";
		#print  $objResponse->content;
		#print Dumper( $response_hash );

    return $response_hash;
  }
  else {
		print "\n\n";
    print  "Response msg.   : ", Dumper( $response_hash->{Errors} );
    print  "Status          : FAILED";
    print  $objResponse->error_as_HTML;

    # Resend update request
    if ( $request_sent_attempts < 1 ) {
      print  "Attempting to resend update request.\n";
      goto RESEND_REQUEST;
    }

		die;
  }

} # end submit_request()

