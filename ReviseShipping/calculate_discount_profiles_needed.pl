#!/usr/bin/perl -w 

################################################################################
# CHANGE lOG
################################################################################
#
# Date        Description
# 1/20/2019   Initial Create


################################################################################
# DESCRIPTION:
################################################################################
#
#   Compares shipping data from both Ebay and the BTData.Inventory table.
#
#   Usage Examples:
#       analyze_shipping_cost3.pl -a -P      # get list of changes required for all listings
#       analyze_shipping_cost3.pl -i 12345   # get list of changes required for specific listing
#       analyze_shipping_cost3.pl -a -r      # NOTE: Revise all lists???
#       analyze_shipping_cost3.pl -a -m 5    # get list of changes required for first 5 listings
#
#   Inputs
#     BTData.Inventory table              # Inventory meta-data  (cost, storage location, SKU, etc.)
#     Ebay
#
#   Outputs (defaults):
#     shipping_cost_fix.csv               # ??? 
#     shipping_cost_fix.noweights.csv     # No Weight. You cannto have calculated shipping with out setting weight on Ebay
#     shipping_cost_fix.errors.csv        # EbayItemID or Title not in Database, unknown shipping service, etc
#
#   TODO:
#   change -P to be the default?
#   Does it update Ebay?
#   Does it update Inventory?
#   What are the inputs and outputs?


################################################################################
# NOTES:
################################################################################
#
#   Add to shipping program - 
#     If multiple items are purchased, calculate if it's cheaper to ship two 
#     items seperately 1st class, rather than 1 box priority
#     * Probably not... *

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
use Switch;

use lib '../cfg';
use EbayConfig;

$|=1;

################################################################################
# Process Command Line Options
################################################################################
my %opts;
getopts('ai:rDm:w:d',\%opts);

# Primary Options:
# -a    => All items processing
# -i    => Item id (ebayItemId) of single item to process
# -r    => Revise item(s) on ebay
                                          #       want to test updating the database.

# Misc Options:
# -o    => Output file - items that need shipping cost fixed  (Default: shipping_cost_fix.csv) 
# -e    => Error file  - items without weights                (Default: shipping_cost_fix.noweights.csv)
# -w    => Weight of single item ( only used with -i )
# -m    => Max number of items to process (debugging. use with -a)
# -D    => Debug mode
# -d    => Dev database connection

my $single_item_id;
my $process_all_items = 1;

my $max_items           = defined $opts{m} ? $opts{m} : 0;
my $REVISE_ITEM         = defined $opts{r} ? 1 : 0;                 # TODO: add this functionality below
my $DEBUG               = defined $opts{D} ? 1 : 0;

my $connect_string = $opts{d} ? 'DBI:ODBC:BTData_DEV_SQLEXPRESS' : 'DBI:ODBC:BTData_PROD_SQLEXPRESS';  # PROD connection is default
print "\n*\n* Connection string: $connect_string\n*\n\n";

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

# GetShippingDiscountProfiles 
my $request_GetShippingDiscountProfiles = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetShippingDiscountProfilesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<OutputSelector>FlatShippingDiscount</OutputSelector>
<WarningLevel>High</WarningLevel>
</GetShippingDiscountProfilesRequest>
END_XML


################################################################################
# SQL
################################################################################

# Get weight
# NOTE: 
#       1. Database SHOULD have all active Ebay listings (US site only).
#       2. On the database we can store a seperate weight for each variation, 
#          but on ebay there is only one weight per listing.
#          So, for determining the shipping cost, we'll use the ebay weight OR
#          the MAX weight found on the database for listing (Title).
#
# TODO: are we sure we want to trim the title?
#       remove max(cost) from title query, since its at the title/variation level?
#
my $sql_get_weight = <<END_SQL;
	select ROW_NUMBER() over(order by a.eBayItemID) as id, a.*
	  from ( select eBayItemID, ltrim(rtrim(Title)) as title, 
	                MAX(weight) as weight,
                  MAX(packaged_weight) as packaged_weight,
                  MAX(cost) as cost                  
             from Inventory 
            where active = 1
            group by eBayItemID, ltrim(rtrim(Title)) ) a
END_SQL

# Get cost
# NOTE:
#       1. cost is stored at the variation level
#
my $sql_get_cost = <<END_SQL;
select ROW_NUMBER() over(order by a.eBayItemID) as id, a.*
  from ( select eBayItemID, ltrim(rtrim(Title)) as title, variation, cost 
           from Inventory 
          where active = 1
     ) a
END_SQL


################################################################################
# Initialize variables
################################################################################
my $dbh;
my ($sth,$sthtv);
my $items   = {}; # items keys by row number
my $itemsid = {}; # items keys by EbayItemID
my $itemst  = {}; # items keys by title (for weight)
my $itemstv = {}; # items keys by title / variation (for cost)


########################################################################################
# Get Item info from Database (Cost/Weights) - build lookup hashes
########################################################################################
# Open database connection
$dbh = DBI->connect( $connect_string, 'shipit', 'shipit',
              { 
                RaiseError       => 0, 
                AutoCommit       => 1, 
                FetchHashKeyName => 'NAME_lc',
                LongReadLen      => 32768,
              } 
            )
    || die "\n\nDatabase connection not made: $DBI::errstr\n\n";

# Get WEIGHTS from the Inventory table by TITLE
$sth = $dbh->prepare( $sql_get_weight ) or die "can't prepare stmt";
$sth->execute() or die "can't execute stmt";
$items = $sth->fetchall_hashref('id') or die "can't fetch results";						

# Create title lookups, and ebayitemid lookup
for my $id ( keys %$items ) {
  $itemsid->{ $items->{$id}->{ebayitemid} } = $items->{$id};
  $itemst->{ $items->{$id}->{title} } = $items->{$id};
}

# Get COSTS from the Inventory table by TITLE+VARIATION
$sthtv = $dbh->prepare( $sql_get_cost ) or die "can't prepare stmt";
$sthtv->execute() or die "can't execute stmt";
$items = $sthtv->fetchall_hashref('id') or die "can't fetch results";						

# Create title / variation lookup, and ebayitemid lookup
for my $id ( keys %$items ) {
  $itemstv->{ $items->{$id}->{title} }->{ $items->{$id}->{variation} } = $items->{$id};
}

# NOTE: Lookup tables are:
#
#         Listing (title) level:
#            $itemsid->{ ebayItemID }
#            $itemst->{ ebayTitle }
#
#         Variation level:
#            $itemstv->{ ebayTitle }->{ ebayVariation }

my $response_hash;
my $request;
my %all_shipping_profiles;
my %new_shipping_profiles;


################################################################################
# Get all Ebay flat rate shipping discount profiles
################################################################################
# NOTE: We still need this for International shipping
#
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetShippingDiscountProfiles');
$request = $request_GetShippingDiscountProfiles;
$response_hash = submit_request( $request, $header );

my $FlatShippingDiscount = $response_hash->{FlatShippingDiscount}->{DiscountProfile};

if ( ! $FlatShippingDiscount ) {
  die "\n\nWARNING: Could not get shipping discount profiles!!!";
}
else {
  for my $sp ( sort @{$FlatShippingDiscount} ) {
    my $key =  sprintf( "%0.2f", $sp->{EachAdditionalAmount} ); 

    $all_shipping_profiles{ $sp->{DiscountProfileID} } = $sp;

    # TODO: delete discount profiles from eBay that match patterns below
    next if $sp->{DiscountProfileName} !~ /addl/;
    next if $sp->{DiscountProfileName} =~ /cents/;
    next if $sp->{DiscountProfileName} =~ /\s+/g;
    next if $sp->{DiscountProfileName} =~ /add_\.95_addl/;

    if ( exists $new_shipping_profiles{ "$key" } ) {
      warn "\n$key - discount profile already exists";
      print "\n1st: ",Dumper($new_shipping_profiles{$key});
      print "\n2st: ",Dumper($sp);
    }

    $new_shipping_profiles{ "$key" } = $sp;
  }
}
# print Dumper(\%all_shipping_profiles);
# print Dumper(\%new_shipping_profiles); exit;


################################################################################
#                                                                              #
#                                                                              #
#                   Process each item_id from Ebay                             #
#                                                                              #
#                                                                              #
################################################################################

print "\n\nMissing discount profiles (if any):\n";

for my $item_id ( keys $itemsid ) {

  # Get weight from database
  my $db_total_item_ozs = $itemsid->{$item_id}->{weight};
  my $db_total_packaged_ozs = $itemsid->{$item_id}->{packaged_weight} || $db_total_item_ozs;   # use weight if packaged weight is not defined

  next unless $db_total_packaged_ozs;

  my $idp;

  # NEW International shipping values ( If package <= 4 lbs (64 ozs) )
  if ( $db_total_packaged_ozs <= 64 ) {
    my $new_intl_epacket_row_cost = get_intl_epacket_row_cost( $db_total_packaged_ozs );
    my $new_intl_epacket_row_addl = get_intl_epacket_row_addl( $db_total_packaged_ozs );

    # NEW International Discount Profile
    if ( defined $new_shipping_profiles{ $new_intl_epacket_row_addl } ) {
      $idp = $new_shipping_profiles{ $new_intl_epacket_row_addl };
    }
    else {
      print "\n\tError: Missing Discount Profile for amount: $new_intl_epacket_row_addl";
    }

    my $new_intl_dp_amt  = defined $idp->{EachAdditionalAmount} ? $idp->{EachAdditionalAmount} : 'n/a';
    my $new_intl_dp_name = defined $idp->{DiscountProfileName} ? $idp->{DiscountProfileName} : 'n/a';
  }
}

print "\n\n";

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
  #print "\n\n",'*'x80;
	#print "\nREQUEST: \n\n",$objRequest->as_string();
  #print "\n",'*'x80,"\n\n";

  # Submit Request
  $objResponse = $objUserAgent->request($objRequest);		# SEND REQUEST

  #print "\n\n",'*'x80;
	#print "\nRESPONSE: \n\n",$objResponse->as_string();
  #print "\n",'*'x80,"\n\n";

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



################################################################################
# E-Packet shipping cost
################################################################################

sub get_dom_calc_shipping_cost {
  my $oz = shift;

  # NOTE:  Can't round up, some items are 15.9oz so that they stay under 16oz Priority mail limit
  # $oz = ceil($oz); # round up
  
  my $cost;

  # NOTE:  Using 7 zones as a baseline for estimates. 
  #        Using Commercial Base Plus pricing
  #        Prices based on 2/3/2019.

  if ( $oz < 16 ) {
    #
    # First Class
    #
    switch ($oz) {
      case [1..4]   { $cost = '2.96' }
      case [5..8]   { $cost = '3.49' }
      case [9..12]  { $cost = '4.19' }
      case [13..16] { $cost = '5.38' }
      else          { die "ERROR calculating shipping cost" }
    }
  }
  else
  {
    # 
    # Priority
    #
    switch ($oz) {
      case [9..16]      { $cost = '7.99'  }
      case [17..32]     { $cost = '10.23' }
      case [33..48]     { $cost = '13.10' }
      case [49..64]     { $cost = '15.59' }
      case [65..80]     { $cost = '17.92' }
      case [81..96]     { $cost = '20.83' }
      case [97..112]    { $cost = '23.48' }
      case [113..128]   { $cost = '25.85' }
      case [129..144]   { $cost = '28.00' }
      case [145..160]   { $cost = '30.79' }
      case [161..176]   { $cost = '33.51' }
      case [177..192]   { $cost = '36.23' }
      case [193..208]   { $cost = '37.69' }
      case [209..224]   { $cost = '39.79' }
      case [225..240]   { $cost = '40.56' }
      case [241..256]   { $cost = '42.84' }
      case [257..272]   { $cost = '45.07' }
      case [273..288]   { $cost = '47.29' }
      case [289..304]   { $cost = '49.49' }
      case [305..320]   { $cost = '51.34' }
      else              { die "ERROR calculating shipping cost" }
    }
  }
}


################################################################################
# International E-Packet Rest-Of-World (row) shipping cost
################################################################################
sub get_intl_epacket_row_cost {
  my $oz = shift;
  $oz = ceil($oz); # round up

  # price as of 1/30/2019
  # $3.30 per piece + $11.22 per pound (~ .70/oz)
  my $cost = 3.30 + ($oz * .70);
  $cost = sprintf("%0.2f",$cost);

  # Business rule: round up to eitehr .59 or .99
  my ($dollars,$cents) = ($cost =~ /^(\d+)\.(\d\d)$/);
  $cents = $cents <= 59 ? '59' : '99';
  $cost = "$dollars.$cents";

  return $cost;
}

################################################################################
# International E-Packet Rest-Of-World (row) additional item shipping cost
################################################################################
sub get_intl_epacket_row_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  my $addl = $oz * .70;
  $addl = sprintf("%0.2f",$addl);

  # Business rule: round up to .50 or whole dollar
  my ($dollars,$cents) = ($addl =~ /^(\d+)\.(\d\d)$/);
  if ( $cents > 0 && $cents <= 50 ) {
    $cents = '50';
  }
  elsif ( $cents > 50 && $cents <= 99 ) {
    $cents = '00';
    $dollars += 1;
  }

  $addl = "$dollars.$cents";

  return $addl;
}


################################################################################
# International E-Packet countries
################################################################################
sub getShipToLocations
{
  # NOTE:
  #   Last Update     : 2/10/2019
  #   Total countries : 36 countries total
  #   Excluding       : None. At one point we were excluding Russia and Brazil due to high
  #                     number of shipping issues via IPA mail class.
  
  my $shipToLocations = {
		'AU' => 'Australia',
		'AT' => 'Austria',
		'BE' => 'Belgium',
    'BR' => 'Brazil',
		'CA' => 'Canada',
		'HR' => 'Croatia',
		'DK' => 'Denmark',
		'EE' => 'Estonia',
		'FI' => 'Finland',
		'FR' => 'France',
		'DE' => 'Germany',
		'GI' => 'Gibraltar',
		'GR' => 'Greece',
		'HK' => 'Hong Kong',
		'HU' => 'Hungary',
		'IE' => 'Ireland',
		'IL' => 'Israel',
		'IT' => 'Italy',
		'JP' => 'Japan',
		'LV' => 'Latvia',
		'LT' => 'Lithuania',
		'LU' => 'Luxembourg',
		'MY' => 'Malaysia',
		'MT' => 'Malta',
		'NL' => 'Netherlands',
		'NZ' => 'New Zealand',
		'NO' => 'Norway',
		'PL' => 'Poland',
		'PT' => 'Portugal',
    'RU' => 'Russia',
		'SG' => 'Singapore',
		'KR' => 'South Korea',
		'ES' => 'Spain',
		'SE' => 'Sweden',
		'CH' => 'Switzerland',
		'GB' => 'United Kingdom',    # a.k.a. Great Britain
  };

  my @shipToLocations = sort keys $shipToLocations;

  return \@shipToLocations;
}

sub getListPrice
{
  my ($profit_perc,$cost) = @_;

  # TODO: use globals for these fee values (same as getProfitAmount())
  
  # Fees
  my $final_value_fee = .09;
  my $top_rated_seller_discount = .8;   # Assuming seller always has this status. Seller only pays 80% of FVF.
  my $paypal_fee_perc = .027;           # PayPal fee = 2.7% + 30 cents
  my $paypal_fee_amt  = .30;
  my $shipping_materials = .25;         # guestimate per bubble mailer (probably on the high side)

  my $price_to_fees_ratio = 100 - (($final_value_fee * $top_rated_seller_discount) + $paypal_fee_perc); # .901

  my $desired_profit_amt = ($profit_perc/100)*$cost;

  # List Price Calculation
  my $list_price = ($cost + $desired_profit_amt + $shipping_materials + $paypal_fee_amt) / $price_to_fees_ratio;

  return sprintf("%.2f", $list_price);

}

sub getProfitAmount
{
  my ($list,$cost) = @_;

  # TODO: use globals for these fee values (same as getListPrice())
  
  # Fees
  my $final_value_fee = .09;
  my $top_rated_seller_discount = .8;   # Assuming seller always has this status. Seller only pays 80% of FVF.
  my $paypal_fee_perc = .027;           # PayPal fee = 2.7% + 30 cents
  my $paypal_fee_amt  = .30;
  my $shipping_materials = .25;         # guestimate per bubble mailer (probably on the high side)

  my $price_to_fees_ratio = 100 - (($final_value_fee * $top_rated_seller_discount) + $paypal_fee_perc); # .901

  # Profit Calculation
  my $profit_amt =  ($list * $price_to_fees_ratio) - $cost - $shipping_materials - $paypal_fee_amt;

  return sprintf("%.2f", $profit_amt );
}



