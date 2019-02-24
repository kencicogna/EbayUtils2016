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
my $process_all_items = 0;

if ( defined $opts{i} ) {
	$single_item_id = $opts{i};
}
elsif ( defined $opts{a} ) {
  $process_all_items = 1;
}
else {
	die "must supply either option '-i <item id>' or '-a' option";
}

my $max_items           = defined $opts{m} ? $opts{m} : 0;
my $REVISE_ITEM         = defined $opts{r} ? 1 : 0;                 # TODO: add this functionality below
my $DEBUG               = defined $opts{D} ? 1 : 0;

my $connect_string = $opts{d} ? 'DBI:ODBC:BTData_DEV_SQLEXPRESS' : 'DBI:ODBC:BTData_PROD_SQLEXPRESS';  # PROD connection is default
print "\n*\n* Connection string: $connect_string\n*\n\n";

my $outfile      = 'shipping_analysis.csv';                 # shipping changes proposed
my $profitfile   = 'profit_analysis.csv';                   # profit, loss, recommended list price analysis
my $noweightfile = 'shipping_cost_fix.noweights.csv';       # errors - no weight on ebay
my $errfile      = 'shipping_cost_fix.errors.csv';          # errors - database record missing or incomplete, or ebay update failed.

my $shipToLocations = getShipToLocations();

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
<OutputSelector>TotalNumberOfPages</OutputSelector>
<OutputSelector>ItemID</OutputSelector>
<OutputSelector>Title</OutputSelector>
<OutputSelector>SKU</OutputSelector>
<OutputSelector>VariationTitle</OutputSelector>
<OutputSelector>SellingStatus</OutputSelector>
</GetMyeBaySellingRequest>
END_XML

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

# Revise Item call
my $request_reviseitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<ReviseFixedPriceItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<Item>
<ItemID>__ItemID__</ItemID>
__SHIPPING_DETAILS__
__SHIPPING_PACKAGE_DETAILS__
</Item>
</ReviseFixedPriceItemRequest>
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
# Output Files
################################################################################
# Open file handles
open my $outfh, '>', $outfile or die "can't open file";
open my $profh, '>', $profitfile or die "can't open file";
open my $noweight_fh, '>', $noweightfile or die "can't open file";
open my $err_fh, '>', $errfile or die "can't open file";

# Write header rows
print $outfh qq/,,,,,,Domestic First Class (current),,,,,International ePacket (current),,,,,International ePacket (new),,,/;
print $outfh qq/\neBayItemID,Title,Variation,Ebay Weight,DB PWeight,,FC amt,FC addl,DP amt,DP name,,EP amt,EP addl,DP amt,DP name,,EP amt,EP addl,DP amt,DP name/;
print $profh qq/eBayItemID,Title,Variation,Wholesale Cost,Listing Price,Profit \$,Profit \%,Break Even,10%,20%,30%,40%,50%,60%,70%,80%,90%,100%/;
print $noweight_fh qq/"eBayItemID","Title"/;
print $err_fh qq/"eBayItemID","Title","Error Message"\n/;


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
# Get all Ebay flat rate shipping discount profiles  (for international)
################################################################################
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

    # TODO: ignore discount profiles from eBay that match patterns below
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


################################################################################
# GET LIST OF ACTIVE ITEM_ID's *** FROM EBAY ***
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetMyeBaySelling');

my @all_items;
my $pagenumber=1;
my $maxpages=1000000;

if ( $process_all_items ) {
	while ( $pagenumber <= $maxpages ) {
		$request = $request_getmyebayselling;
		$request =~ s/__PAGE_NUMBER__/$pagenumber/;
		$response_hash = submit_request( $request, $header );

    # Handle paging
		if ($pagenumber==1) {
			$maxpages = $response_hash->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
		}
    print "\npage $pagenumber of $maxpages";
		$pagenumber++;

    # Active Items
		for my $i ( @{$response_hash->{ActiveList}->{ItemArray}->{Item}} ) {

      # NOTE: Exclude foreign listings by currency (not perfect, some other countries could use USD)
      #       But, by doing a check here, we avoid a lot of extra API calls later 
      next if ($i->{SellingStatus}->{CurrentPrice}->{currencyID} ne 'USD');

			push(@all_items, $i->{ItemID});
		}
	}
}
else {
	@all_items = split(',',$single_item_id);
}

print "Total Items: ",scalar @all_items,"\n";


################################################################################
#                                                                              #
#                                                                              #
#                   Process each item_id from Ebay                             #
#                                                                              #
#                                                                              #
################################################################################
my $item_count=0;
for my $item_id ( @all_items ) {

	$item_count++;
	$request = $request_getitem_default;
	$request =~ s/__ItemID__/$item_id/;
	$header->remove_header('X-EBAY-API-CALL-NAME');
	$header->push_header  ('X-EBAY-API-CALL-NAME' => 'GetItem');
	$response_hash = submit_request( $request, $header );

	my $r = $response_hash->{Item};
	my $title  = $r->{Title};           # NOTE: We are trimming title in the database too (do we need to do this? maybe just put out warning?)
  $title =~ s/^\s+//g;
  $title =~ s/\s+$//g;

  print "\n($item_count) $title";

  # Warn if title not in database
	if ( ! defined $itemst->{$title} ) {
    print $err_fh qq($item_id,$title,"WARNING [2]: TITLE not in database"\n);
  }

  my $db_total_item_ozs = 0;
  my $db_total_packaged_ozs = 0;

  # Warn if itemID not in database (fyi- cost is at the variation level)
	if ( ! defined $itemsid->{$item_id} ) {
    print $err_fh qq($item_id,$title,"WARNING [1]: ITEM ID not in database"\n);
  }
  else {
    # Get weight from database
    $db_total_item_ozs = $itemsid->{$item_id}->{weight};
    $db_total_packaged_ozs = $itemsid->{$item_id}->{packaged_weight} || $db_total_item_ozs;   # use weight if packaged weight is not defined
  }

  # Get weight from Ebay
	my $spd = $r->{ShippingPackageDetails};
  my $ebay_lbs = defined $r->{ShippingPackageDetails}->{WeightMajor}->{content} ? int($r->{ShippingPackageDetails}->{WeightMajor}->{content}) : 0;
  my $ebay_oz = defined $r->{ShippingPackageDetails}->{WeightMinor}->{content} ? int($r->{ShippingPackageDetails}->{WeightMinor}->{content}) : 0;
  my $ebay_total_ozs = ( $ebay_lbs * 16 ) + $ebay_oz;

	# NOTE: We don't want to continue if there's no weight, 
  #       because Calculated Shipping can't be set with out weight
	if ( ! $ebay_total_ozs ) {
		print "\nITEM ID: '$item_id' - TITLE: '$title' -- no weight";
		print $noweight_fh "\n$item_id,$title";
		next;
	}

  # Use best weight  (DB Packaged, DB weight, Ebay weight)
  $db_total_packaged_ozs = $db_total_packaged_ozs || $ebay_total_ozs;
  my $lbs = floor($db_total_packaged_ozs / 16);
  my $oz = $db_total_packaged_ozs % 16;

  
  ################################################################################ 
	# Get Ebay Shipping details - mailclass/price/etc.
  ################################################################################ 
	my $sd  = $r->{ShippingDetails};
	my $shipping_details = dclone($sd);    # Copy of original shipping details (TODO: don't need this if I'm not going to alter $sd)


  #################################################################################
  # DOMESTIC SHIPPING
  #################################################################################
  my $curr_dom_first_cost    = 'n/a';
  my $curr_dom_first_addl    = 'n/a';
  my $curr_dom_priority_cost = 'n/a';
  my $curr_dom_priority_addl = 'n/a';

  # Current Discount Profile
  my ($curr_dom_dp_id, $curr_dom_dp_name, $curr_dom_dp_addl_cost) = ('','','');
  if ( defined $sd->{FlatShippingDiscount}->{DiscountProfile} ) {
    $curr_dom_dp_id = $sd->{FlatShippingDiscount}->{DiscountProfile}->{DiscountProfileID};
    $curr_dom_dp_name = $all_shipping_profiles{ $curr_dom_dp_id }->{DiscountProfileName};
    $curr_dom_dp_addl_cost = $sd->{FlatShippingDiscount}->{DiscountProfile}->{EachAdditionalAmount}->{content} || '0';
  }

  # Current Package Dimensions (default 4x6x4)
  my $packageDepth  = defined $r->{ShippingPackageDetails}->{PackageDepth}->{content} ? $r->{ShippingPackageDetails}->{PackageDepth}->{content} : '4' ;
  my $packageLength = defined $r->{ShippingPackageDetails}->{PackageLength}->{content} ? $r->{ShippingPackageDetails}->{PackageLength}->{content} : '6' ;
  my $packageWidth  = defined $r->{ShippingPackageDetails}->{PackageWidth}->{content} ? $r->{ShippingPackageDetails}->{PackageWidth}->{content} : '4' ;
  
  # Delete Flat Rate Shipping Discount 
  delete $sd->{FlatShippingDiscount};

  # Current shipping services costs
  my $elems = @{$sd->{ShippingServiceOptions}};
  for ( my $idx=0 ; $idx < $elems; $idx++ ) {
    my $sso = $sd->{ShippingServiceOptions}->[$idx];
		my $sso_ss_cost = $sso->{ShippingServiceCost}->{content} || '0';
		$sso->{ShippingServiceCost} = $sso_ss_cost;

		my $sso_ss_addl_cost = $sso->{ShippingServiceAdditionalCost}->{content} || '0';
		$sso->{ShippingServiceAdditionalCost} = $sso_ss_addl_cost;

    # First class
    if ( $sso->{ShippingService} eq 'USPSFirstClass' ) {
      $curr_dom_first_cost = $sso_ss_cost;
      $curr_dom_first_addl = $sso_ss_addl_cost;
    }

    # Priority
    if ( $sso->{ShippingService} eq 'USPSPriority' ) {
      $curr_dom_priority_cost = $sso_ss_cost;
      $curr_dom_priority_addl = $sso_ss_addl_cost;
    }

	}

  # Set domestic shipping service options (sso) to first class or priority based on weight
  $sd->{ShippingServiceOptions} = [];
  if ( $db_total_packaged_ozs < 16 ) {
    # First Class
    my $first_class = {
        'ExpeditedService' => 'false',
        'ShippingService' => 'USPSFirstClass',
        'ShippingServicePriority' => '1',
        'ShippingTimeMax' => '3',
        'ShippingTimeMin' => '2'
    };
    push( @{$sd->{ShippingServiceOptions}}, $first_class);
  }
  else {
    # Priority
    my $priority = {
      'ExpeditedService' => 'false',
      'ShippingService' => 'USPSPriority',
      'ShippingServicePriority' => '1',
      'ShippingTimeMax' => '3',
      'ShippingTimeMin' => '1'
    };
    push( @{$sd->{ShippingServiceOptions}}, $priority);
  }

  # Estimate Calculated Shipping (needed to estimate profit/loss due to final values fee being charged on shipping)
  my $new_dom_calc_shipping_cost = get_dom_calc_shipping_cost( $db_total_packaged_ozs );

  # current shipping type
  if ($sd->{ShippingType} =~ /CalculatedDomestic.*/) {
    $curr_dom_dp_name      = '(calc)';
    $curr_dom_dp_addl_cost = '(calc)';
    $curr_dom_first_cost   = '(calc)';
    $curr_dom_first_addl   = '(calc)';
  }

  #################################################################################
	# INTERNATIONAL SHIPPING SERVICES
  #################################################################################
  my $curr_intl_row_cost     = 'n/a';
  my $curr_intl_row_addl     = 'n/a';
  my $curr_intl_dp_addl_cost = 'n/a';
  my $curr_intl_dp_name      = 'n/a';

  my $new_intl_epacket_row_cost = 'n/a';
  my $new_intl_epacket_row_addl = 'n/a';

  my $idp;  # New International Discount Profile

  # Current International shipping info (Optional)
	if ( defined $sd->{InternationalShippingServiceOption} ) { # this is optional

    # Current International shipping costs (OtherInternational / WorldWide (i.e. "Economy", e.g. IPA/E-Packet) )
    for my $sso ( @{$sd->{InternationalShippingServiceOption}}  ) {
      if ( $sso->{ShippingService} eq 'OtherInternational' ) {
        $curr_intl_row_cost = $sso->{ShippingServiceCost}->{content};
        $curr_intl_row_addl = sprintf("%0.2f",$sso->{ShippingServiceAdditionalCost}->{content});
      }
    }

    # Get Current International Discount Profile
    if ( defined $sd->{InternationalFlatShippingDiscount} ) {
      $curr_intl_dp_addl_cost = sprintf("%0.2f",$sd->{InternationalFlatShippingDiscount}->{DiscountProfile}->{EachAdditionalAmount}->{content});
      $curr_intl_dp_name = $sd->{InternationalFlatShippingDiscount}->{DiscountProfile}->{DiscountProfileName};
    }
	}

  # NEW International shipping values ( If package <= 4 lbs (64 ozs) )
  if ( $db_total_packaged_ozs <= 64 ) {
    $new_intl_epacket_row_cost = get_intl_epacket_row_cost( $db_total_packaged_ozs );
    $new_intl_epacket_row_addl = get_intl_epacket_row_addl( $db_total_packaged_ozs );

    # NEW International Discount Profile
    if ( defined $new_shipping_profiles{ $new_intl_epacket_row_addl } ) {
      $idp = $new_shipping_profiles{ $new_intl_epacket_row_addl };
    }
    else {
      die "\n\nError: Missing Discount Profile for amount: $new_intl_epacket_row_addl";
    }

    # Set New values
    $sd->{InternationalFlatShippingDiscount} = 
    {
      'DiscountName'    => 'EachAdditionalAmount',
      'DiscountProfile' => {
        'DiscountProfileID'   => $idp->{DiscountProfileID},
        'DiscountProfileName' => $idp->{DiscountProfileName},
        #'EachAdditionalAmount' => [ "$addl_item_cost" ]    # TODO: why is this an array????
        'EachAdditionalAmount' => {
          'content' => $idp->{EachAdditionalAmount},
          'currencyID' => 'USD'
        }
      }
    };

    $sd->{InternationalShippingDiscountProfileID} = $idp->{DiscountProfileID};

    # Remove current exclude shipTo list, replace with specific list of countries to ship to (see InternationalShippingServiceOption->shipToLocation)
    delete $sd->{ExcludeShipToLocation};

    $sd->{InternationalShippingServiceOption} = [
                                        {
                                          'ShipToLocation' => $shipToLocations,   # ePacket only
                                          'ShippingService' => 'OtherInternational',
                                          'ShippingServiceAdditionalCost' => [ "$new_intl_epacket_row_addl" ],
                                          'ShippingServiceCost' => [ "$new_intl_epacket_row_cost" ],
                                          'ShippingServicePriority' => '1'
                                        },
                                      ];

  }
  else {
    delete $sd->{InternationalFlatShippingDiscount};
    delete $sd->{InternationalShippingDiscountProfileID};
    delete $sd->{InternationalShippingServiceOption};
  }

  $sd->{PaymentInstructions} = 'Thanks for shopping at The Teaching Toy Box!';
  $sd->{ShippingType} = 'CalculatedDomesticFlatInternational';
  $sd->{ShippingDiscountProfileID} = '0';

  ################################################################################ 
  # Create NEW shipping details hash
  ################################################################################ 
  my $new_ShippingPackageDetails = {
      MeasurementUnit   => 'English',
      PackageDepth      => $packageDepth,
      PackageLength     => $packageLength,
      PackageWidth      => $packageWidth,
      ShippingIrregular => 'false',
      ShippingPackage   => 'PackageThickEnvelope',
      WeightMajor       => $lbs,
      WeightMinor       => $oz
  };

  my $new_ShippingDetails = {
      # Calculated Shipping 
      CalculatedShippingRate => {
        OriginatingPostalCode => '60506',
         MeasurementUnit      => 'English',
         PackagingHandlingCosts => 0.0,
         ShippingIrregular => 'false',

        'PackageDepth' => {
          'content' => $packageDepth,
          'measurementSystem' => 'English',
          'unit' => 'inches'
        },
        'PackageLength' => {
          'content' => $packageLength,
          'measurementSystem' => 'English',
          'unit' => 'inches'
        },
        'PackageWidth' => {
          'content' => $packageWidth,
          'measurementSystem' => 'English',
          'unit' => 'inches'
        },
          'content' => '0.0',
          'currencyID' => 'USD'
        },
        'ShippingIrregular' => 'false',
        'ShippingPackage' => 'PackageThickEnvelope',
        'WeightMajor' => {
          'content' => $lbs,
          'measurementSystem' => 'English',
          'unit' => 'lbs'
        },
        'WeightMinor' => {
          'content' => $oz,
          'measurementSystem' => 'English',
          'unit' => 'oz'
        }
  };

      CalculatedShippingRate> CalculatedShippingRateType
        <MeasurementUnit> MeasurementSystemCodeType </MeasurementUnit>
        <OriginatingPostalCode> string </OriginatingPostalCode>
        <PackagingHandlingCosts> AmountType (double) </PackagingHandlingCosts>
        <ShippingIrregular> boolean </ShippingIrregular>
      </CalculatedShippingRate>
  };


      <CODCost> AmountType (double) </CODCost>
      <ExcludeShipToLocation> string </ExcludeShipToLocation>
      <!-- ... more ExcludeShipToLocation values allowed here ... -->
      <GlobalShipping> boolean </GlobalShipping>
      <InternationalPromotionalShippingDiscount> boolean </InternationalPromotionalShippingDiscount>
      <InternationalShippingDiscountProfileID> string </InternationalShippingDiscountProfileID>
      <InternationalShippingServiceOption> InternationalShippingServiceOptionsType
        <ShippingService> token </ShippingService>
        <ShippingServiceAdditionalCost> AmountType (double) </ShippingServiceAdditionalCost>
        <ShippingServiceCost> AmountType (double) </ShippingServiceCost>
        <ShippingServicePriority> int </ShippingServicePriority>
        <ShipToLocation> string </ShipToLocation>
        <!-- ... more ShipToLocation values allowed here ... -->
      </InternationalShippingServiceOption>
      <!-- ... more InternationalShippingServiceOption nodes allowed here ... -->
      <PaymentInstructions> string </PaymentInstructions>
      <PromotionalShippingDiscount> boolean </PromotionalShippingDiscount>
      <RateTableDetails> RateTableDetailsType
        <DomesticRateTable> string </DomesticRateTable>
        <DomesticRateTableId> string </DomesticRateTableId>
        <InternationalRateTable> string </InternationalRateTable>
        <InternationalRateTableId> string </InternationalRateTableId>
      </RateTableDetails>
      <SalesTax> SalesTaxType
        <SalesTaxPercent> float </SalesTaxPercent>
        <SalesTaxState> string </SalesTaxState>
        <ShippingIncludedInTax> boolean </ShippingIncludedInTax>
      </SalesTax>
      <ShippingDiscountProfileID> string </ShippingDiscountProfileID>
      <ShippingServiceOptions> ShippingServiceOptionsType
        <FreeShipping> boolean </FreeShipping>
        <ShippingService> token </ShippingService>
        <ShippingServiceAdditionalCost> AmountType (double) </ShippingServiceAdditionalCost>
        <ShippingServiceCost> AmountType (double) </ShippingServiceCost>
        <ShippingServicePriority> int </ShippingServicePriority>
        <ShippingSurcharge> AmountType (double) </ShippingSurcharge>
      </ShippingServiceOptions>
      <!-- ... more ShippingServiceOptions nodes allowed here ... -->
      <ShippingType> ShippingTypeCodeType </ShippingType>

	# Convert the hash into XML
  my $shipping_details_xml = XMLout($sd, NoAttr=>1, RootName=>'ShippingDetails', KeyAttr=>{});

  # Debug the XML before revising item
	#print "\n\nShippingDetails:\n",Dumper($sd);
	#print "\n\nShipping Details XML:\n",Dumper($shipping_details_xml);
  

  ################################################################################ 
  # Get Cost / Purchase Price / Calculate Profit or Loss
  ################################################################################ 
  my $cost = 0;
  my $list = 0;
  my $recommended_list = [];
  my $profit_amt = 0;
  my $var_cost = {};

  if ( defined $r->{Variations} ) {
    # Variations
    for my $v ( @{$r->{Variations}->{Variation}} ) {

      my $var = $v->{VariationSpecifics}->{NameValueList}->{Value};

      if ( ! defined $itemstv->{$title}->{$var} ) {
        print $err_fh qq($item_id,"$title - $var","WARNING: variation not in database"\n);
        next;
      }

      $list = $v->{StartPrice}->{content};
      $cost = $itemstv->{$title}->{$var}->{cost};

      if ( ! $cost ) {
        print $err_fh qq($item_id,"$title - $var","WARNING: variation has no cost in database"\n);
        next;
      }

      $var_cost->{$var}->{list} = $list;
      $var_cost->{$var}->{cost} = $cost;

      for (my $perc=0; $perc<=100; $perc+=10 ) {
        $var_cost->{$var}->{recommended_list}->[$perc] = getListPrice($perc,$cost);
      }

      #$var_cost->{$var}->{profit_amt} = sprintf( "%.2f", ($var_cost->{$var}->{list} * .901) - $cost - .55) ;
      $var_cost->{$var}->{profit_amt} = getProfitAmount($list,$cost);
    }
  }
  else {
    # Non-Variation
    $cost = $itemstv->{$title}->{''}->{cost};     # wholesale cost (purchase price)
    $list = $r->{StartPrice}->{content};          # listed price on ebay (selling it for this price)

    if ( ! $cost ) {
      no warnings;
      print $err_fh qq($item_id,"$title","WARNING: non-variation has no cost in database"\n);
      use warnings;
      next;
    }

    for (my $perc=0; $perc<=100; $perc+=10 ) {
      $recommended_list->[$perc] = getListPrice($perc,$cost);
    }

    # Calculate profit/loss
    $profit_amt = getProfitAmount($list,$cost);  # Pass current list price and wholesale cost. 
  }

  ################################################################################ 
  # Display Shipping Stats
  ################################################################################ 
  $curr_dom_first_cost = 'n/a' unless defined $curr_dom_first_cost;
  $curr_dom_first_addl = 'n/a' unless defined $curr_dom_first_addl;

  if ( $DEBUG ) {
    print <<END;



------------------------------------------------
-                                              -
-  Item: $item_id                          -
-                                              -
------------------------------------------------
  Title          : $title
  Ebay Item ID   : $item_id
  Weight (oz)    : $db_total_packaged_ozs
END

    if ( ! defined $r->{Variations} ) {
      # Non-Variation
      print <<END;
  Cost             : $cost
  Current List     : $list
  Recommended List : $recommended_list->[80]
END
    }
    else {
      # Variations
      print <<END;

                    Variations
    ------------------------------------------------
                   Listing Price
               ----------------------
    Cost       Current    Recommended  Description
    ------------------------------------------------
END

      for my $v ( sort keys %$var_cost ) {
        print sprintf("  %-10.2f %-10.2f %-10.2f  %s\n", $var_cost->{$v}->{cost}, $var_cost->{$v}->{list}, $var_cost->{$v}->{recommended_list}->[80], $v);
      }
    }

  }

  if ( $DEBUG ) {
    print <<END;

               Shipping Info                   
------------------------------------------------

Domestic - CURRENT
------------------------------------------------
  1st class cost : $curr_dom_first_cost
  1st class addl : $curr_dom_first_addl
  Priority cost  : $curr_dom_priority_cost
  Priority addl  : $curr_dom_priority_addl
  Discount Profile Amount : $curr_dom_dp_addl_cost
  Discount Profile Name   : $curr_dom_dp_name

Domestic - NEW
------------------------------------------------
  Calculated 

International - CURRENT
------------------------------------------------
  Economy ROW cost : $curr_intl_row_cost
  Economy ROW addl : $curr_intl_row_addl
  Discount Profile Amount : $curr_intl_dp_addl_cost
  Discount Profile Name   : $curr_intl_dp_name

International - NEW
------------------------------------------------
  E-Packet ROW cost : $new_intl_epacket_row_cost
  E-Packet ROW addl : $new_intl_epacket_row_addl
  Discount Profile Amount : $idp->{EachAdditionalAmount}
  Discount Profile Name   : $idp->{DiscountProfileName}    

END

    # TODO: Debugging only
		my $request = $request_reviseitem_default;
		$request =~ s/__ItemID__/$item_id/;
		$request =~ s/__SHIPPING_DETAILS__/$shipping_details_xml/;
#    print "$request \n\n";
#    exit;

  }


	################################################################################
	# TODO: REVISE ITEM ON EBAY
	################################################################################
	if ( $REVISE_ITEM ) {
    $header->remove_header('X-EBAY-API-CALL-NAME');
    $header->push_header('X-EBAY-API-CALL-NAME' => 'ReviseFixedPriceItem');

		my $request = $request_reviseitem_default;
		$request =~ s/__ItemID__/$item_id/;
		$request =~ s/__SHIPPING_DETAILS__/$shipping_details_xml/;

    # TODO: UPDATE Ebay with PACKAGED_WEIGHT from database ($db_total_packaged_ozs)
    #        done in ShippingPackageDetails and CalculatedShipping tags. I think that's it.

		eval {
			my $r = submit_request( $request, $header, 1 ); # return error object if the request fails
			if ( $r->{LongMessage} ) {
				my $error = $r->{LongMessage};
				print $err_fh qq/\n$item_id,"$title","$error"\n/;
				next;
			}
		};
		if ( $@ ) {
        no warnings;
				print $err_fh qq/$item_id,"$title","ERROR: Submit ReviseFixedPriceItem failed. $@"\n/;
        use warnings;
				next;
		}

    # TODO: update database with weight (if found on ebay but not database)
  
	}

  ################################################################################
  # Write Output files
  ################################################################################
  my $new_intl_dp_amt  = defined $idp->{EachAdditionalAmount} ? $idp->{EachAdditionalAmount} : 'n/a';
  my $new_intl_dp_name = defined $idp->{DiscountProfileName} ? $idp->{DiscountProfileName} : 'n/a';

  if ( ! defined $r->{Variations} ) {
    # Non-Variation
    my $v = ''; 
    my $r = $recommended_list;
    my $break_even = $r->[0];
    my $profit_perc;

    if ( $cost ) {    # some new items may not have cost entered in database
      eval {
        $profit_perc = ($profit_amt / $cost) * 100;  # NOTE: 
        $profit_perc = sprintf("%0.2f",$profit_perc);

        # Profit File
        print $profh qq/\n"$item_id","$title","$v","$cost","$list","$profit_amt","$profit_perc","$break_even","$r->[10]","$r->[20]","$r->[30]","$r->[40]","$r->[50]","$r->[60]","$r->[70]","$r->[80]","$r->[90]","$r->[100]"/;
      };
      if ($@) {
        print Dumper($shipping_details);
        print "\n\nITEM ID: $item_id";
        print   "\nTITLE  : $title";
        print   "\nVAR    : $v";
        die     "\nERROR   : $@";
      }
    }

    # Shipping File
    print $outfh qq/\n"$item_id","$title","$v",$ebay_total_ozs,$db_total_packaged_ozs,,$curr_dom_first_cost,$curr_dom_first_addl,$curr_dom_dp_addl_cost,$curr_dom_dp_name,,$curr_intl_row_cost,$curr_intl_row_addl,$curr_intl_dp_addl_cost,$curr_intl_dp_name,,$new_intl_epacket_row_cost,$new_intl_epacket_row_addl,$new_intl_dp_amt,$new_intl_dp_name/;

  }
  else {
    # Variations
    for my $v ( sort keys %$var_cost ) {
      my $cost = sprintf("%0.2f",$var_cost->{$v}->{cost});
      my $list = sprintf("%0.2f",$var_cost->{$v}->{list});
      my $r = $var_cost->{$v}->{recommended_list};
      my $break_even = $r->[0];
      my $profit_perc;

      if ( $cost ) {    # some new items may not have cost entered in database
        eval {
          $profit_amt = $var_cost->{$v}->{profit_amt};
          $profit_perc = ($profit_amt / $cost) * 100;
          $profit_perc = sprintf("%0.2f",$profit_perc);

          # Profit File
          print $profh qq/\n"$item_id","$title","$v","$cost","$list","$profit_amt","$profit_perc","$break_even","$r->[10]","$r->[20]","$r->[30]","$r->[40]","$r->[50]","$r->[60]","$r->[70]","$r->[80]","$r->[90]","$r->[100]"/;
        };
        if ($@) {
          print Dumper($shipping_details);
          print "\n\nITEM ID : $item_id";
          print   "\nTITLE   : $title";
          print   "\nVAR     : $v";
          die     "\nERROR   : $@";
        }
      }

      # Shipping File
      print $outfh qq/\n"$item_id","$title","$v",$ebay_total_ozs,$db_total_packaged_ozs,,$curr_dom_first_cost,$curr_dom_first_addl,$curr_dom_dp_addl_cost,$curr_dom_dp_name,,$curr_intl_row_cost,$curr_intl_row_addl,$curr_intl_dp_addl_cost,$curr_intl_dp_name,,$new_intl_epacket_row_cost,$new_intl_epacket_row_addl,$new_intl_dp_amt,$new_intl_dp_name/;

    }
  }


  # Debugging
	if ( $max_items and $item_count >= $max_items ) {
		print "\nMax Items  : $max_items";
		print "\nItem Count : $max_items";
		last;
	}
}

close $outfh;
close $profh;
close $noweight_fh;
close $err_fh;



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


# OLD EXCLUDE Locations:
#   Previously we were including entire countries/regions, then excluding specific countries/states
#
#     push( @{$sd->{ExcludeShipToLocation}}, (
#       'Africa',
#       'South America',
#       'BN',
#       'KH',
#       'ID',
#       'LA',
#       'MO',
#       'PH',
#       'TW',
#       'TH',
#       'VN',
#       'BM',
#       'GL',
#       'MX',
#       'PM',
#       'BH',
#       'IQ',
#       'JO',
#       'KW',
#       'LB',
#       'OM',
#       'QA',
#       'SA',
#       'TR',
#       'AE',
#       'YE',
#       'AF',
#       'AM',
#       'AZ',
#       'BD',
#       'BT',
#       'CN',
#       'GE',
#       'IN',
#       'KZ',
#       'KR',
#       'KG',
#       'MV',
#       'MN',
#       'NP',
#       'PK',
#       'RU',
#       'LK',
#       'TJ',
#       'TM',
#       'UZ',
#       'AS',
#       'CK',
#       'FJ',
#       'PF',
#       'GU',
#       'KI',
#       'MH',
#       'FM',
#       'NR',
#       'NC',
#       'NU',
#       'PW',
#       'PG',
#       'SB',
#       'TO',
#       'TV',
#       'VU',
#       'WF',
#       'WS',
#       'AL',
#       'AD',
#       'AT',
#       'BE',
#       'BA',
#       'BG',
#       'CY',
#       'CZ',
#       'GR',
#       'GG',
#       'IS',
#       'JE',
#       'LI',
#       'MK',
#       'MD',
#       'MC',
#       'ME',
#       'PL',
#       'RO',
#       'SM',
#       'RS',
#       'SK',
#       'SI',
#       'SJ',
#       'UA',
#       'VA',
#       'AI',
#       'AG',
#       'AW',
#       'BS',
#       'BB',
#       'BZ',
#       'VG',
#       'KY',
#       'CR',
#       'DM',
#       'DO',
#       'SV',
#       'GD',
#       'GP',
#       'GT',
#       'HT',
#       'HN',
#       'JM',
#       'MQ',
#       'MS',
#       'AN',
#       'NI',
#       'PA',
#       'KN',
#       'LC',
#       'VC',
#       'TT',
#       'TC') 
#     );

