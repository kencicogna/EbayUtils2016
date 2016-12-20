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


my %opts;
getopts('i:raDo:m:w:e:P',\%opts);

# -a    => All items processing
# -i    => Item id of single itme to processing
# -r    => Revise item(s) on ebay
# -o    => Output file - items that need shipping cost fixed
# -e    => Error file - items without weights
# -w    => Weight of single item ( only used with -i )
# -m    => Max number of items to process (debugging. use with -a)
# -D    => Debug mode
# -P    => Production DB connection

my $single_item_id;
my $process_all_items = 0;
my $weight_in;

if ( defined $opts{i} ) {
	$single_item_id = $opts{i};
	$weight_in = $opts{w} ? $opts{w} : 0;
}
elsif ( defined $opts{a} ) {
  $process_all_items = 1;
}
else {
	die "must supply either option '-i <item id>' or '-a' option";
}

my $max_items           = defined $opts{m} ? $opts{m} : 0;
my $REVISE_ITEM         = defined $opts{R} ? 1 : 0;
my $DEBUG               = defined $opts{D} ? 1 : 0;
my $outfile             = defined $opts{o} ? $opts{o} : 'shipping_cost_fix.csv';
$outfile .= '.csv' if ( $outfile !~ /.*\.csv$/i );
my $noweightfile        = defined $opts{e} ? $opts{e} : 'shipping_cost_fix.noweights.csv';
$noweightfile .= '.csv' if ( $noweightfile !~ /.*\.csv$/i );

my $errfile = 'shipping_cost_fix.errors.csv';
my $connect_string = $opts{P} ? 'DBI:ODBC:BTData_PROD_SQLEXPRESS' : 'DBI:ODBC:BTData_DEV_SQLEXPRESS';
print STDERR "\n*\n* Connection string: $connect_string\n*\n\n";

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
</Item>
</ReviseFixedPriceItemRequest>
END_XML


########################################
# SQL
########################################

# Get weight from database 
# NOTE: 1. Database SHOULD have all active Ebay listings.
#       2. On the database we can store a seperate weight for each variation, 
#          but on ebay there is only one weight per listing.
#          So, for determining the shipping cost, we'll use the ebay weight OR
#          the MAX weight found on the database for listing (Title).
my $sql_get_weight = <<END_SQL;
	select ROW_NUMBER() over(order by a.eBayItemID) as id, a.*
	  from ( select eBayItemID, ltrim(rtrim(Title)) as title, MAX(weight) as weight,
                  MAX(cost) as cost -- this only applies to non-variations
             from tty_StorageLocation 
            where active = 1
            group by eBayItemID, Title ) a
END_SQL

# Get cost from database 
# NOTE: cost is stored at the variation level
my $sql_get_cost = <<END_SQL;
	select ROW_NUMBER() over(order by a.eBayItemID) as id, a.*
	  from ( select eBayItemID, ltrim(rtrim(Title)) as title, variation, cost 
             from tty_StorageLocation 
            where active = 1
         ) a
END_SQL


########################################
# Open Output Files
########################################
open my $outfh, '>', $outfile or die "can't open file";
open my $noweight_fh, '>', $noweightfile or die "can't open file";
open my $err_fh, '>', $errfile or die "can't open file";

my $dbh;
my ($sth,$sthtv);
my $items = {};   # all items by row number
my $itemsid = {}; # all items by EbayItemID
my $itemst  = {}; # items by title
my $itemstv = {}; # items by title / variation


################################################
# Get Item info from Database (Cost/Weights)
################################################
if ( $single_item_id && $weight_in ) {
	# short cut, if the user is only processing one item and has provide the weight
	#            also a way around not having access to the database when testing
  for my $i ( split(',',$single_item_id) ) {
	  $items->{$i}->{weight} = $weight_in;
  }
}
else {
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

	# Get all item weights from tty_storageLocation by TITLE
	$sth = $dbh->prepare( $sql_get_weight ) or die "can't prepare stmt";
	$sth->execute() or die "can't execute stmt";
	$items = $sth->fetchall_hashref('id') or die "can't fetch results";						

  # Create title lookup, and ebayitemid lookup
  for my $id ( keys %$items ) {
    $itemsid->{ $items->{$id}->{ebayitemid} } = $items->{$id};
    $itemst->{ $items->{$id}->{title} } = $items->{$id};
  }

	# Get all item costs from tty_storageLocation by TITLE/VARIATION
	$sthtv = $dbh->prepare( $sql_get_cost ) or die "can't prepare stmt";
	$sthtv->execute() or die "can't execute stmt";
	$items = $sthtv->fetchall_hashref('id') or die "can't fetch results";						

  # Create title / variation lookup, and ebayitemid lookup
  for my $id ( keys %$items ) {
    $itemstv->{ $items->{$id}->{title} }->{ $items->{$id}->{variation} } = $items->{$id};
  }
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

################################################################################
# Get all Ebay flat rate shipping discount profiles
################################################################################
$header->remove_header('X-EBAY-API-CALL-NAME');
$header->push_header('X-EBAY-API-CALL-NAME' => 'GetShippingDiscountProfiles');
$request = $request_GetShippingDiscountProfiles;
$response_hash = submit_request( $request, $header );

# print "\n\nREQUEST:\n\n",Dumper($request);
# print "\n\nRESPONSE:\n\n",Dumper($response_hash);

my $FlatShippingDiscount = $response_hash->{FlatShippingDiscount}->{DiscountProfile};

if ( ! $FlatShippingDiscount ) {
  #print "\n\nHTTP HEADERS: ",Dumper($header);
  #print "\n\nREQUEST:\n\n",Dumper($request);
  #print "\n\nRESPONSE:\n\n",Dumper($response_hash);
  print "\n\nWARNING: Could not get shipping discount profiles!!!\n";
  exit;
}
else {
  for my $sp ( sort @{$FlatShippingDiscount} ) {
    my $key =  sprintf( "%0.2f", $sp->{EachAdditionalAmount} ); 

    # get rid of duplicate dicount profiles, only keep the ones that are in the right format 
    if ( $sp->{DiscountProfileName} =~ / /  or $sp->{DiscountProfileName} =~ /cent/ or $sp->{DiscountProfileName} =~ /add_\.95_addl/) {
      #print "\nSkipping $sp->{DiscountProfileName}";
      next;
    };

    if ( exists $all_shipping_profiles{ "$key" } ) {
      print "\n",Dumper($sp);
      print Dumper($all_shipping_profiles{ "$key" });
      die "$key - discount profile already exists";
    }

    $all_shipping_profiles{ "$key" }->{EachAdditionalAmount} = $sp->{EachAdditionalAmount};
    $all_shipping_profiles{ "$key" }->{DiscountProfileName} = $sp->{DiscountProfileName};
    $all_shipping_profiles{ "$key" }->{DiscountProfileID} = $sp->{DiscountProfileID};
  }
}

# for my $k ( sort keys %all_shipping_profiles ) {
#   print "\n$all_shipping_profiles{$k}->{DiscountProfileName}";
# }

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
		for my $i ( @{$response_hash->{ActiveList}->{ItemArray}->{Item}} ) {
			push(@all_items, $i->{ItemID});
		}
		if ($pagenumber==1) {
			$maxpages = $response_hash->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
		}
		$pagenumber++;
	}
}
else {
	@all_items = split(',',$single_item_id);
}
print STDERR "Total Items: ",scalar @all_items,"\n";

# Write output header row to output file
print $outfh qq/eBayItemID,Title,Variation,Weight,Wholesale Cost,Shipping Cost,Listing Price,Profit-Loss,Break Even,10%,20%,30%,40%,50%,60%,70%,80%,90%,100%/;
print $noweight_fh qq/"eBayItemID","Title"/;
print $err_fh qq/"eBayItemID","Title","Error Message"\n/;


################################################################################
#                                                                              #
#                                                                              #
#                 Loop over each item_id from Ebay                             #
#                                                                              #
#                                                                              #
################################################################################
my $item_count=0;
for my $item_id ( @all_items ) {

	$item_count++;
	# GET SINGLE ITEM DETAILS - EBAY API 'GetItem' call
	$request = $request_getitem_default;
	$request =~ s/__ItemID__/$item_id/;
	$header->remove_header('X-EBAY-API-CALL-NAME');
	$header->push_header  ('X-EBAY-API-CALL-NAME' => 'GetItem');
	$response_hash = submit_request( $request, $header );

	my $r = $response_hash->{Item};
	my $title  = $r->{Title};
  $title =~ s/^\s+//g;
  $title =~ s/\s+$//g;

  # print Dumper($r); exit;

  ################################################################################ 
  # Must be in database to get COST  (fyi- cost is at the variation level)
	if ( ! defined $itemsid->{$item_id} ) {
    print $err_fh qq($item_id,$title,"WARNING [1]: ITEM ID not in database"\n);
    #next;
  }

	if ( ! defined $itemst->{$title} ) {
    print $err_fh qq($item_id,$title,"WARNING [2]: TITLE not in database"\n);
    #next;
  }

  ################################################################################ 
  # Get weight from Ebay first (if defined and weight is positive)
  my $lbs = defined $r->{ShippingPackageDetails}->{WeightMajor}->{content} ? int($r->{ShippingPackageDetails}->{WeightMajor}->{content}) : 0;
  my $ozs = defined $r->{ShippingPackageDetails}->{WeightMinor}->{content} ? int($r->{ShippingPackageDetails}->{WeightMinor}->{content}) : 0;
  $ozs = ( $lbs * 16 ) + $ozs;

  # Get weight from database
	if ( ! $ozs && defined $itemst->{$title} && $itemsid->{$item_id} ) {
	  $ozs = int($items->{$item_id}->{weight}||'0');
	}

	if ( ! $ozs ) {
		print STDERR "\nITEM ID: '$item_id' - TITLE: '$title' -- no weight";
		print $noweight_fh "\n$item_id,$title";
		#next; --> NOTE: moved this down by revise item, to give the item the opportunity to fall out also due to not having intl. shipping info
	}

  ################################################################################ 
	# Get Ebay Shipping info - mailclass/price
	my $spd = $r->{ShippingPackageDetails};
	my $sd  = $r->{ShippingDetails};
	my $shipping_details = dclone($sd);


  #################################################################################
	# INTERNATIONAL SHIPPING SERVICES
  #################################################################################
  my $curr_intl_ipa_row_cost=0;
  my $curr_intl_ipa_row_addl=0;
  my $curr_intl_ipa_ca_cost=0;
  my $curr_intl_ipa_ca_addl=0;
  my $curr_intl_dp_addl_cost=0;
  my $curr_intl_dp_name;

	my $addl_item_cost=0;
	my $addl_item_cost_profile;
	my $new_cost_row=0;
	my $new_cost_ca=0;

  my $new_intl_ipa_row_cost=0;
  my $new_intl_ipa_row_addl=0;
  my $new_intl_ipa_ca_cost=0;
  my $new_intl_ipa_ca_addl=0;
  my $new_intl_epacket_row_cost=0;
  my $new_intl_epacket_row_addl=0;
  my $new_intl_epacket_ca_cost=0;
  my $new_intl_epacket_ca_addl=0;
  my $new_intl_dp_addl_cost=0;
  my $new_intl_dp_name;

	if ( defined $sd->{InternationalShippingServiceOption} ) { # this is optional

    # Get Current shipping costs
    my $isso = $sd->{InternationalShippingServiceOption};

    for my $sso ( @$isso ) {

      #die "\nERROR: Unknown International shipping service: ",Dumper($isso) 
      if ( $sso->{ShippingService} ne 'OtherInternational' ) {
	      print $err_fh qq/$item_id,"$title","warning: unhandled INTL shipping service '/,$sso->{ShippingService},qq/'"/;
        next;
      }

      if ( $sso->{ShipToLocation}->[0] eq 'CA' ) {
		    $curr_intl_ipa_ca_cost = $sso->{ShippingServiceCost}->{content};
		    $curr_intl_ipa_ca_addl = sprintf("%0.2f",$sso->{ShippingServiceAdditionalCost}->{content});
        die unless $curr_intl_ipa_ca_cost;
      }
      elsif (  $sso->{ShipToLocation}->[0] eq 'Worldwide' ) {

		    $curr_intl_ipa_row_cost = $sso->{ShippingServiceCost}->{content};
		    $curr_intl_ipa_row_addl = sprintf("%0.2f",$sso->{ShippingServiceAdditionalCost}->{content});
      }
      else {
        die "\nERROR: Unknown International shipping location: ",Dumper($isso); 
      }

    }

    # Get Current discount profile info
    if ( defined $sd->{InternationalFlatShippingDiscount} ) {
      $curr_intl_dp_addl_cost = sprintf("%0.2f",$sd->{InternationalFlatShippingDiscount}->{DiscountProfile}->{EachAdditionalAmount}->{content});
      $curr_intl_dp_name = $sd->{InternationalFlatShippingDiscount}->{DiscountProfile}->{DiscountProfileName};
    }


#     # Get addl_item_cost_profile
# 		my $addl_item_cost_string = sprintf("%0.2f", $addl_item_cost );
#     $curr_intl_dp_addl_cost = $addl_item_cost_string;
#     if ( defined $all_shipping_profiles{ $addl_item_cost_string } ) { 
# 			$addl_item_cost_profile = $all_shipping_profiles{ $addl_item_cost_string };
#       $curr_intl_dp_name = $addl_item_cost_profile->{DiscountProfileName};
# 		} else {
# 			print STDERR "\nWARNING: NO SHIPPING PROFILE FOUND FOR COST '$addl_item_cost_string'";
# 			print STDERR "\n  ($item_id) $title\n";
# 			print $err_fh qq/$item_id,"$title","No shipping profile for cost '$addl_item_cost_string'"\n/;
# 			next;
# 		}

    # Get NEW International shipping values
    $new_intl_ipa_row_cost = get_intl_ipa_row_cost( $ozs );
    $new_intl_ipa_row_addl = get_intl_ipa_row_addl( $ozs );
    $new_intl_ipa_ca_cost = get_intl_ipa_ca_cost( $ozs );
    $new_intl_ipa_ca_addl = get_intl_ipa_ca_addl( $ozs );

    $new_intl_epacket_row_cost = get_intl_epacket_row_cost( $ozs );
    $new_intl_epacket_row_addl = get_intl_epacket_row_addl( $ozs );
    $new_intl_epacket_ca_cost = get_intl_epacket_ca_cost( $ozs );
    $new_intl_epacket_ca_addl = get_intl_epacket_ca_addl( $ozs );

    $new_intl_dp_addl_cost = 0;                 # free domestic shipping on all products
    $new_intl_dp_name      = 'add_0.00_addl';   # free domestic shipping on all products

    # Update Shipping Details hash
		$sd->{InternationalShippingDiscountProfileID} = $addl_item_cost_profile->{DiscountProfileID};
    $sd->{InternationalFlatShippingDiscount} = 
																			{
                                       'DiscountName'    => 'EachAdditionalAmount',
                                       'DiscountProfile' => {
                                                            'DiscountProfileID' => $addl_item_cost_profile->{DiscountProfileID},
                                                            'DiscountProfileName' => $addl_item_cost_profile->{DiscountProfileName},
                                                            'EachAdditionalAmount' => [ "$addl_item_cost" ]
                                                            }
                                     };
		

    $sd->{InternationalShippingServiceOption} = [
                                        {
                                          'ShipToLocation' => [ 'Worldwide' ],
                                          'ShippingService' => 'OtherInternational',
                                          'ShippingServiceAdditionalCost' => [ $addl_item_cost ],
                                          'ShippingServiceCost' => [ "$new_cost_row" ],
                                          'ShippingServicePriority' => '1'
                                        },
                                        {
                                          'ShipToLocation' => [ 'CA' ],
                                          'ShippingService' => 'OtherInternational',
                                          'ShippingServiceAdditionalCost' => [ $addl_item_cost ],
                                          'ShippingServiceCost' => [ "$new_cost_ca" ],
                                          'ShippingServicePriority' => '2'
                                        },
                                      ];

	}
	else {
		# No international shipping specified
		#print STDERR Dumper($r);
	  print STDERR "\nWARNING: NO INTL SHIPPING INFORMATION IN LISTING";
		print STDERR "\n  ($item_id) $title\n";

	  print $err_fh qq/$item_id,"$title","No International shipping info (calculated weight?)"\n/;
		next;
	}

  next if ( ! $ozs );  # skip this record if we couldn't find a weight (message already printed above)


  #################################################################################
  # DOMESTIC SHIPPING
  #################################################################################
  my $curr_dom_dp_addl_cost;
  my $curr_dom_dp_name;
  my $curr_dom_first_cost;
  my $curr_dom_first_addl;
  my $curr_dom_priority_cost;
  my $curr_dom_priority_addl;

  # Current Discount Profile Additional Cost
	$curr_dom_dp_addl_cost = $sd->{FlatShippingDiscount}->{DiscountProfile}->{EachAdditionalAmount}->{content} || '0';
	my $curr_dom_addl_item_cost_string = sprintf("%0.2f", $curr_dom_dp_addl_cost );

  # Current Discount Profile Name
	my $curr_dom_addl_item_cost_profile = $all_shipping_profiles{ $curr_dom_addl_item_cost_string };
  die "\nWARNING: No profile exists for '$curr_dom_addl_item_cost_string'"
    if ( ! defined $all_shipping_profiles{ $curr_dom_addl_item_cost_string } );
  $curr_dom_dp_name = $curr_dom_addl_item_cost_profile->{DiscountProfileName};

  # Get actual shiiping costs for domestic first class
  my $actual_dom_first_cost = get_dom_first_cost( $ozs );
  my $actual_dom_priority_cost = get_dom_priority_cost( $ozs );

  # Get NEW domestic shipping values  (free domestic 1st class shipping on all products)
  my $new_dom_first_cost = $ozs>16 ? undef : 0;                   
  my $new_dom_first_addl = $ozs>16 ? undef : 0;
  my $new_dom_priority_cost = get_dom_priority_cost( $ozs );
  my $new_dom_priority_addl = get_dom_priority_addl( $ozs );  # always 0
  my $new_dom_dp_addl_cost = 0;               
  my $new_dom_dp_name      = 'add_0.00_addl';

  # Back out shipping cost already built in to the price
  # If first class shipping is offered, then subtract the FC price, 
  # else if only priority is offered, then set priority to free (because it will be built into the price of the item)
  if ( defined $actual_dom_first_cost ) {
    # Domestic
    $new_dom_priority_cost -= $actual_dom_first_cost;
    # INTL
    $new_intl_ipa_row_cost -= $actual_dom_first_cost;
    $new_intl_epacket_row_cost -= $actual_dom_first_cost;
    $new_intl_ipa_ca_cost -= $actual_dom_first_cost;
    $new_intl_epacket_ca_cost -= $actual_dom_first_cost;
  }
  else {
    # Domestic (Priority ONLY)
    $new_dom_priority_cost = 0;
    $new_dom_priority_addl = 0;

    # INTL
    $new_intl_ipa_row_cost -= $actual_dom_priority_cost;
    $new_intl_epacket_row_cost -= $actual_dom_priority_cost;
    $new_intl_ipa_ca_cost -= $actual_dom_priority_cost;
    $new_intl_epacket_ca_cost -= $actual_dom_priority_cost;
  }

	# FIX CONTENT TAGS (before revising item -- probably wouldn't have to do this if we XMLin'd with different options)
	delete $sd->{CalculatedShippingRate};

  # Update xml with new domestic shipping service options (sso)
	for my $sso ( @{ $sd->{ShippingServiceOptions} } ) {
		my $sso_ss_cost = $sso->{ShippingServiceCost}->{content} || '0';
		$sso->{ShippingServiceCost} = $sso_ss_cost;

		my $sso_ss_addl_cost = $sso->{ShippingServiceAdditionalCost}->{content} || '0';
		$sso->{ShippingServiceAdditionalCost} = $sso_ss_addl_cost;

    if ( $sso->{ShippingService} eq 'USPSFirstClass' ) {
      $curr_dom_first_cost = $sso_ss_cost;
      $curr_dom_first_addl = $sso_ss_addl_cost;
    }

    if ( $sso->{ShippingService} eq 'USPSPriority' ) {
      $curr_dom_priority_cost = $sso_ss_cost;
      $curr_dom_priority_addl = $sso_ss_addl_cost;
    }
	}

	$sd->{FlatShippingDiscount}->{DiscountProfile}->{EachAdditionalAmount} = sprintf("%.2f",$new_dom_dp_addl_cost);

	# Convert the hash into XML
  my $shipping_details_xml = XMLout($sd, NoAttr=>1, RootName=>'ShippingDetails', KeyAttr=>{});
  use warnings;

  # Debug the XML before revising item
#	if ( $DEBUG ) { 
#		print "\n\nShippingDetails:\n",Dumper($sd);
#		print "\n\nShipping Details XML:\n",Dumper($shipping_details_xml);
#	}

  ################################################################################ 
  # Get Cost / Purchase Price
  ################################################################################ 
  my $cost = 0;
  my $list = 0;
  my $recommended_list = [];
  my $profit_loss = 0;
  my $var_cost = {};
  if ( defined $r->{Variations} ) {
    for my $v ( @{$r->{Variations}->{Variation}} ) {

      my $var = $v->{VariationSpecifics}->{NameValueList}->{Value};

      if ( ! defined $itemstv->{$title}->{$var} ) {
        print $err_fh qq($item_id,"$title - $var","WARNING: variation not in database"\n);
        next;
      }

      $var_cost->{$var}->{list} = $v->{StartPrice}->{content};

      # Does each variation have it's own cost?
      $cost = $itemstv->{$title}->{$var}->{cost};

      if ( ! $cost ) {
        print $err_fh qq($item_id,"$title - $var","WARNING: variation has no cost in database"\n);
        next;
      }

      $var_cost->{$var}->{cost} = $cost;

      for (my $perc=0; $perc<=100; $perc+=10 ) {
        $var_cost->{$var}->{recommended_list}->[$perc] = sprintf("%.2f", ( (($perc/100)*$cost) + $cost + $actual_dom_first_cost + .30 + .25) / .901 );
      }

      $var_cost->{$var}->{profit_loss} = sprintf( "%.2f", ($var_cost->{$var}->{list} * .901) - $cost - $actual_dom_first_cost - .55) ;
    }
  }
  else {
    # Non-Variation
    $cost = $itemstv->{$title}->{''}->{cost};
    $list = $r->{StartPrice}->{content};

    if ( ! $cost ) {
      no warnings;
      print $err_fh qq($item_id,"$title","WARNING: non-variation has no cost in database"\n);
      use warnings;
      next;
    }

    for (my $perc=0; $perc<=100; $perc+=10 ) {
      $recommended_list->[$perc] = sprintf("%.2f", ( (($perc/100)*$cost) + $cost + $actual_dom_first_cost + .30 + .25) / .901);
    }

    $profit_loss = sprintf("%.2f", (($list * .901) - $cost - $actual_dom_first_cost - .55)  );
  }

  ################################################################################ 
  # Display Shipping Stats
  ################################################################################ 
  $curr_dom_first_cost = 'n/a' unless defined $curr_dom_first_cost;
  $curr_dom_first_addl = 'n/a' unless defined $curr_dom_first_addl;
  $actual_dom_first_cost = 'n/a' unless defined $actual_dom_first_cost;
  $new_dom_first_addl = 'n/a' unless defined $new_dom_first_addl;

  if ( $DEBUG ) {
    print <<END;
Item
------------------------------------------------
  Title          : $title
  Ebay Item ID   : $item_id
  Weight (oz)    : $ozs
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

    #  print Dumper($var_cost); exit;
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

Domestic - ACTUAL
------------------------------------------------
  1st class cost : $actual_dom_first_cost
  1st class addl : $new_dom_first_addl
  Priority cost  : $actual_dom_priority_cost
  Priority addl  : $new_dom_priority_addl
  Discount Profile Amount : $new_dom_dp_addl_cost
  Discount Profile Name   : $new_dom_dp_name

Domestic - NEW
------------------------------------------------
  1st class cost : $new_dom_first_cost
  1st class addl : $new_dom_first_addl
  Priority cost  : $new_dom_priority_cost
  Priority addl  : $new_dom_priority_addl
  Discount Profile Amount : $new_dom_dp_addl_cost
  Discount Profile Name   : $new_dom_dp_name


International - CURRENT
------------------------------------------------
  Economy ROW cost : $curr_intl_ipa_row_cost
  Economy ROW addl : $curr_intl_ipa_row_addl
  Economy CA cost : $curr_intl_ipa_ca_cost
  Economy CA addl : $curr_intl_ipa_ca_addl
  Discount Profile Amount : $curr_intl_dp_addl_cost
  Discount Profile Name   : $curr_intl_dp_name

International - NEW
------------------------------------------------
  Economy/IPA ROW cost : $new_intl_ipa_row_cost
  Economy/IPA ROW addl : $new_intl_ipa_row_addl
  Economy/IPA CA cost : $new_intl_ipa_ca_cost
  Economy/IPA CA addl : $new_intl_ipa_ca_addl
  E-Packet    ROW cost : $new_intl_epacket_row_cost
  E-Packet    ROW addl : $new_intl_epacket_row_addl
  E-Packet    CA cost : $new_intl_epacket_ca_cost
  E-Packet    CA addl : $new_intl_epacket_ca_addl
  Discount Profile Amount : $new_intl_dp_addl_cost    ( shouldn't this be .55 * weight? )
  Discount Profile Name   : $new_intl_dp_name    

END

  }


	#
	# REVISE ITEM
	#
	if ( $REVISE_ITEM ) {
    $header->remove_header('X-EBAY-API-CALL-NAME');
    $header->push_header('X-EBAY-API-CALL-NAME' => 'ReviseFixedPriceItem');

		my $request = $request_reviseitem_default;
		$request =~ s/__ItemID__/$item_id/;
		$request =~ s/__SHIPPING_DETAILS__/$shipping_details_xml/;

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

  # Write Output file
  $actual_dom_first_cost = 'n/a' unless defined $actual_dom_first_cost;

  if ( ! defined $r->{Variations} ) {
    # Non-Variation
    my $r = $recommended_list;
    my $break_even = $r->[0];
    my $list_diff = $break_even ? sprintf( "%d", (($list-$break_even)/$break_even)*100) : 'n/a';
    $profit_loss = sprintf("%0.2f",$profit_loss);

    print $outfh qq/\n$item_id,"$title",,$ozs,$cost,$actual_dom_first_cost,$list,$profit_loss,$break_even,$r->[10],$r->[20],$r->[30],$r->[40],$r->[50],$r->[60],$r->[70],$r->[80],$r->[90],$r->[100]/;
  }
  else {
    # Variations
    for my $v ( sort keys %$var_cost ) {
      my $cost = sprintf("%0.2f",$var_cost->{$v}->{cost});
      my $list = sprintf("%0.2f",$var_cost->{$v}->{list});
      my $r = $var_cost->{$v}->{recommended_list};
      my $break_even = $r->[0];
      my $list_diff = $break_even ? sprintf( "%d", (($list-$break_even)/$break_even)*100) : 'n/a';
      my $profit_loss = sprintf("%0.2f",$var_cost->{$v}->{profit_loss});

      print $outfh qq/\n"$item_id","$title","$v","$ozs","$cost","$actual_dom_first_cost","$list","$profit_loss","$break_even","$r->[10]","$r->[20]","$r->[30]","$r->[40]","$r->[50]","$r->[60]","$r->[70]","$r->[80]","$r->[90]","$r->[100]"/;
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


####################################################################################################
sub get_dom_first_cost {
  my $oz = shift;
  my $coz = ceil($oz); # round up

  # as of 4/17/2016
  # http://pe.usps.com/text/dmm300/Notice123.htm
  my $shipping_rate_table_commercial_base = {
    1   => '2.60',
    2   => '2.60',
    3   => '2.60',
    4   => '2.60',
    5   => '2.60',
    6   => '2.60',
    7   => '2.60',
    8   => '2.60',
    9   => '3.30',
    10  => '3.35',
    11  => '3.40',
    12  => '3.45',
    13  => '3.50',
    14  => '3.55',
    15  => '3.60',
    16  => '3.65',
  };

  # Do not offer first class shipping if it weighs more than 16oz.
  return undef 
    if ( $oz > 16 );

  die "ERROR: Invalid weight of '$oz' passed into get_dom_first_cost()"
    if ( ! defined $shipping_rate_table_commercial_base->{ $coz } );

  return $shipping_rate_table_commercial_base->{ $coz };
}

sub get_dom_first_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  return get_dom_first_cost($oz);  # always zero because domestic is "free"
}

sub get_dom_priority_cost {
  my $oz = shift;
  my $coz = ceil($oz);     # round up
  my $lbs = ceil($oz/16);  # round up

  # as of 4/17/2016
  # http://pe.usps.com/text/dmm300/Notice123.htm
  my $shipping_rate_table_commercial_base = {
    1 => '6.20',   # <= 1 lbs
    2 => '8.15',   # <= 2 lbs
    3 => '9.75',   # <= 3 lbs
    4 => '10.66',  # <= 4 lbs
    5 => '11.26',  # <= 5 lbs
    6 => '12.11',  # <= 6 lbs
    7 => '12.99',  # <= 7 lbs
  };

  die "weight greater than 7 lbs, update hash table" if ($lbs>7);

  my $cost = $shipping_rate_table_commercial_base->{$lbs} ;

  return $cost;
}

sub get_dom_priority_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  my $cost = 0;

  return $cost;
}

#
#  IPA shipping costs
#
sub get_intl_ipa_row_cost {
  my $oz = shift;
  $oz = ceil($oz); # round up

  # price as of 3/22/2016
  my $cost = 2.61 + ($oz * .57);

  return $cost;
}

sub get_intl_ipa_row_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  my $cost = $oz * .57;

  return $cost;
}

sub get_intl_ipa_ca_cost {
  my $oz = shift;
  $oz = ceil($oz); # round up

  # price as of 3/22/2016
  my $cost = 2.59 + ($oz * .39);

  return $cost;
}

sub get_intl_ipa_ca_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  my $cost = $oz * .39;

  return $cost;
}

#
# E-Packet shipping cost
#

sub get_intl_epacket_row_cost {
  my $oz = shift;
  $oz = ceil($oz); # round up

  # price as of 3/22/2016
  my $cost = 3.50 + ($oz * .55);

  return $cost;
}

sub get_intl_epacket_row_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  my $cost = $oz * .55;

  return $cost;
}

sub get_intl_epacket_ca_cost {
  my $oz = shift;
  $oz = ceil($oz); # round up

  # price as of 3/22/2016
  my $cost = 3.50 + ($oz * .34);

  return $cost;
}

sub get_intl_epacket_ca_addl {
  my $oz = shift;
  $oz = ceil($oz); # round up

  my $cost = $oz * .34;

  return $cost;
}


