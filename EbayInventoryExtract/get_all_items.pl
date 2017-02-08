use strict;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request;
use HTTP::Headers;
use HTML::Restrict;
use HTML::Entities 'decode_entities';
use DBI;
use XML::Simple qw(XMLin XMLout);
# use XML::Tidy;
use Date::Calc 'Today';
use Data::Dumper 'Dumper';			$Data::Dumper::Sortkeys = 1;
use File::Copy qw(copy move);
use POSIX;
use Getopt::Std;
use Storable 'dclone';

use lib '../cfg';
use EbayConfig;

my %opts;
getopts('i:aDI:O:p',\%opts);
# -i <ebay item ID>		- perform operations on this single item
# -a                  - perform operations on all items
# -D                  - Debug/verbose mode. 
# -I <filename>       - Input filename. csv format (same as output. PUT NEW VALUE IN THE "TOTAL SHIPPING COST" column)
# -O <filename>       - output filename base. default is 'product_import'
my @item_list;
my $process_all_items = 0;

if ( defined $opts{i} ) {
  die "must supply an item id to -i" if ( $opts{i} !~ /^[\d,]+$/ );
	@item_list = split(',',$opts{i});
}
elsif ( defined $opts{a} ) {
  $process_all_items = 1;
}
else {
	die "must supply either option '-i <item id>' or '-a' option";
}

my $PRODUCTION  = defined $opts{p} ? 1 : 0;
my $DEBUG       = defined $opts{D} ? 1 : 0;
my $infile      = defined $opts{I} ? $opts{I} : '';
my $outfile     = defined $opts{O} ? $opts{O} : 'lw_import';

print "\n\nDEV Mode. Use -p option for Production!\n\n" if ( ! $PRODUCTION );

my $of_ERR = $outfile . '.error_log.csv';
my $of_AI  = $outfile . '.AI_basic_product_import.csv';    # AI - AgileIron - Basic Item
my $of_AIM = $outfile . '.AI_matrix_product_import.csv';   # AI - AgileIron - Item with Variations
my $of_AIIS= $outfile . '.AI_item_specifics_import.csv';    # AI - AgileIron - Item Specifics (all items)
my $of_BPI = $outfile . '.basic_product.csv';
my $of_SLI = $outfile . '.stock_level.csv';
my $of_ATT = $outfile . '.product_ext_propeties.csv';
my $of_SUP = $outfile . '.product_supplier_info.csv';
my $of_IMG = $outfile . '.images.csv';
my $of_DES = $outfile . '.channel_desc_attr.csv';
my $of_VG  = $outfile . '.variation_group.csv';
my $of_SIV = $outfile . '.stock_item_variation.csv';

my $html_filter = HTML::Restrict->new(
        rules => {
            p  => [],
            ul => [],
            li => [],
            div => [],  # TODO: list valid attributes
        }
    );



###################################################
# EBAY API INFO                                   #
###################################################

# Ebay API Request Headers
my $header = $EbayConfig::ES_http_header;

# Ebay Authentication Token
my $eBayAuthToken = $EbayConfig::ES_eBayAuthToken;

my $request_getStore_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetStoreRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<CategoryStructureOnly>TRUE</CategoryStructureOnly>
</GetStoreRequest>
END_XML

my $request_getitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<DetailLevel>ReturnAll</DetailLevel>
<ItemID>__ItemID__</ItemID>
<IncludeItemSpecifics>TRUE</IncludeItemSpecifics>
</GetItemRequest>
END_XML

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

my $request_GetShippingDiscountProfiles = <<END_XML;
<?xml version="1.0" encoding="utf-8"?>
<GetShippingDiscountProfilesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
</GetShippingDiscountProfilesRequest>
END_XML


########################################
# SQL
########################################
my $sqlGetProductInfoBySKU = 'select * from Inventory where SKU=?';


###########################################################
# END EBAY API INFO                                       #
###########################################################

# Open output files
open my $ofh_ERR, '>', $of_ERR or die "can't open file $of_ERR";
open my $ofh_AI , '>', $of_AI  or die "can't open file $of_AI ";
open my $ofh_AIIS,'>', $of_AIIS or die "can't open file $of_AIIS";
open my $ofh_AIM, '>', $of_AIM or die "can't open file $of_AIM";
open my $ofh_BPI, '>', $of_BPI or die "can't open file $of_BPI";
open my $ofh_SLI, '>', $of_SLI or die "can't open file $of_SLI";
open my $ofh_ATT, '>', $of_ATT or die "can't open file $of_ATT";
open my $ofh_SUP, '>', $of_SUP or die "can't open file $of_SUP";
open my $ofh_IMG, '>', $of_IMG or die "can't open file $of_IMG";
open my $ofh_DES, '>', $of_DES or die "can't open file $of_DES";
open my $ofh_VG , '>', $of_VG  or die "can't open file $of_VG ";
open my $ofh_SIV, '>', $of_SIV or die "can't open file $of_SIV";

my $connectionString = $PRODUCTION ? "DBI:ODBC:BTData_PROD_SQLEXPRESS" : "DBI:ODBC:BTData_DEV_SQLEXPRESS";

# Connect to Database
my $dbh;
eval {
	# Open database connection
	$dbh =
	DBI->connect( $connectionString,
							  'shipit',
							  'shipit',
							  { 
									RaiseError       => 0, 
									AutoCommit       => 1, 
									FetchHashKeyName => 'NAME_lc',
									LongReadLen      => 32768,
							  } 
						)
	|| die "\n\nDatabase connection not made: $DBI::errstr\n\n";
};
die "$@"
  if ($@);

$dbh->{LongReadLen} = 50000;

# prepare sql - Get product info by SKU
my $sth_productInfo = $dbh->prepare( $sqlGetProductInfoBySKU ) or die "can't prepare stmt";

my $request;
my $response_hash;
my $allEbayCategories = {};
my $allItemSpecifics = {};
my $allItemsItemSpecifics = {};

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
      #print Dumper( $i->{ItemID} ); exit;
    }
    if ($pagenumber==1) {
      $maxpages = $response_hash->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
    }
    $pagenumber++;
  }
}

my $all_items_count = scalar @all_items;
#print $ofh_ERR "Total Items: ",scalar @all_items,"\n";

# Write output header row to output file
#	Product Name
#	ItemID	
#	Custom Label	
#	RelationshipDetails	
#	Product Code	
#	Bar Code	
#	Matrix Item	
#	Color	Style	
#	Pacifier Style	
#	Stickers	
#	Scent	Model	
#	Animal	
#	Dinosaur	
#	Theme	
#	Air Freshener Type	
#	Pacifier Animal	
#	Type	
#	Matrix SKU Code	
#	Product Category	
#	Manufacturer	
#	Manufacturer Part No	
#	Website	
#	Product Images	
#	Description	
#	Unit Cost	
#	Stock Location	
#	Qty in Stock	
#	Bin Location	
#	Reorder Level	- 1
#	Product Stock Manager	- admin
#	Send Stock Notifications - yes
#	Auto Create PO at Reorder Level	-no
#	eBay PriceBook	
#	Preferred Vendor	
#	Preferred Vendor Part Number	
#	Preferred Vendor Price	
#	Preferred Vendor Order Qty	
#	SEO Title	
#	SEO Description	
#	SEO Keywords	
#	Income Account	
#	COGS Account	
#	Asset Account	
#	QuickBooks Item	
#	Tax Category	
#	Length (in)	
#	Width (in)	
#	Height (in)	
#	Weight-Major (lbs)	
#	Weight-Minor (oz)	
#	eBay Item ID	
#	eBay Variation 
#	SKU	
#	ASIN	
#	FNSKU	
#	Discontinued	
#	UPC Code	
#	ISBN	
#	EAN	
#	Brand	
#	EPID


# Print Headers records to output files
my $AI_headers = qq/"Product Name","ItemID","Custom Label","RelationshipDetails","Product Code","Bar Code","Matrix Item","Variation Type","Matrix SKU Code","Product Category","Manufacturer","Manufacturer Part No","Website","Product Images","Description","Unit Cost","Stock Location","Qty in Stock","Bin Location","Reorder Level","Product Stock Manager","Send Stock Notifications","Auto Create PO at Reorder Level","eBay PriceBook","Preferred Vendor","Preferred Vendor Part Number","Preferred Vendor Price","Preferred Vendor Order Qty","SEO Title","SEO Description","SEO Keywords","Income Account","COGS Account","Asset Account","QuickBooks Item","Tax Category","Length (in)","Width (in)","Height (in)","Weight-Major (lbs)","Weight-Minor (oz)","eBay Item ID","eBay Variation","SKU","ASIN","FNSKU","Discontinued","UPC Code","ISBN","EAN","Brand","EPID","EbayCategoryID","EbayCategoryName"\n/;
print $ofh_AI  $AI_headers;
print $ofh_AIM $AI_headers;
print $ofh_BPI qq/SKU,Title,PurchasePrice,RetailPrice,Weight,BarcodeNumber,Category,ShortDescription,DimHeight,DimWidth,DimDepth\n/;
print $ofh_SLI qq/SKU,StockLevel,MinimumLevel,UnitCost,StockValue,Location,BinRack\n/;
print $ofh_ATT qq/SKU,PropertyType,PropertyName,PropertyValue\n/;
print $ofh_SUP qq/SKU,SupplierName,PurchasePrice\n/;  # TODO: does supplier code get assigned automatically?
print $ofh_IMG qq/SKU,isPrimary,FilePath\n/;          
print $ofh_DES qq/SKU,Title,Price,Description\n/;  
print $ofh_VG  qq/VariationSKU,VariationGroupName\n/;  # Linnwork - VariationSKU = ParentSKU
print $ofh_SIV qq/SKU,VariationSKU\n/;  # Linnwork - SKU=variation SKU,    VariationSKU=ParentSKU  


################################################################################
# Loop over each item (active on eBay)
################################################################################
my $rec_count = 0;
my $item_count=0;
my $SKU_counter = 0;
my $categoryIDHash = {};
my $categoryNameHash = {};


# Get store category names (build hash table lookup by category ID => $categoryIDHash)
$request = $request_getStore_default;
my $ebayStore = submit_request( 'GetStore', $request, $header );
my $esCategories = $ebayStore->{Store}->{CustomCategories}->{CustomCategory};
for my $hr_cat ( @$esCategories ) {
  LoadCategory( $hr_cat, $hr_cat->{Name} );
}

# Get Shipping Discount Profiles ID's (build lookup table:  profile name => profile ID)
my $shipProfLookup = {};
$request = $request_GetShippingDiscountProfiles;
my $ebayShipProf = submit_request( 'GetShippingDiscountProfiles', $request, $header );
my $flatShipDiscProfiles = $ebayShipProf->{FlatShippingDiscount}->{DiscountProfile};
for my $dp ( @$flatShipDiscProfiles ) {
  $shipProfLookup->{ $dp->{DiscountProfileName} } = $dp->{DiscountProfileID};
}

################################################################################
#
# Process each active Listing (itemID) on eBay
#
################################################################################
for my $item_id ( reverse @all_items ) {

  # Get detailed info from ebay on this itemID
  $request = $request_getitem_default;
  $request =~ s/__ItemID__/$item_id/;
  my $ebayResponse = submit_request( 'GetItem', $request, $header );
  my $ebayListing = $ebayResponse->{Item};
  my $title       =  $ebayListing->{Title};

  if ( $DEBUG ) { print Dumper($ebayListing); exit; }

  if ( ! defined( $ebayListing->{SKU} ) ) { print $ofh_ERR "\nItemID=$item_id - No SKU on Ebay. Skipping Item."; next;}

  parse_description_html($ebayListing);

  # Get Item Specifics list ( this will be the same for each variation )  
  my $itemSpecificsHash = {};
  if ( defined $ebayListing->{ItemSpecifics} ) {
    for my $a ( @{$ebayListing->{ItemSpecifics}->{NameValueList}} ) {
      $itemSpecificsHash->{ $a->{Name} } = $a->{Value};
    }
  }

  # Get Shipping details from EBAY
  my $S  = $ebayListing->{ShippingDetails};             # Shipping
  my $SD = $S->{ShippingServiceOptions};                # Shipping Domestic
  my $SI = $S->{InternationalShippingServiceOption};    # Shipping International

  # Get weight from EBAY
  my $majorweight = POSIX::floor($ebayListing->{weight} / 16);
  my $minorweight = $ebayListing->{weight} % 16;
  my $totalweight = $ebayListing->{weight};
  my $ebaymajorweight = defined $S->{ShippingPackageDetails}->{WeightMajor} ? $S->{ShippingPackageDetails}->{WeightMajor}->{content} : 0;
  my $ebayminorweight = defined $S->{ShippingPackageDetails}->{WeightMinor} ? $S->{ShippingPackageDetails}->{WeightMinor}->{content} : 0;
  my $ebayWeight = ($ebaymajorweight * 16) + $ebayminorweight;

  # Weight
  if ( ($ebayListing->{weight} != $ebayWeight) ) { # in total ouches
    print $ofh_ERR "WARNING: itemid=$item_id - weight differs from ebay and Inventory tables";
  }

  # Use weight in Inventory table first, then Ebay ( TODO: might want to change this )
  $majorweight = $majorweight ? $majorweight : $ebaymajorweight;
  $minorweight = $minorweight ? $minorweight : $ebayminorweight;
  $totalweight = $totalweight ? $totalweight : $ebayWeight;

  # Get Domestic shipping rates
  my ($StdShipping, $StdShipAddl, $PriShipping, $PriShipAddl, $DomShipProfID );
  for my $SS ( @$SD ) {
    if ( $SS->{ShippingService} eq 'USPSFirstClass' ) {                    # First Class
      $StdShipping = $SS->{ShippingServiceCost}->{content};
      $StdShipAddl = $SS->{ShippingServiceAdditionalCost}->{content};
    }
    elsif ( $SS->{ShippingService} eq 'USPSPriority' ) {                   # Priority
      $PriShipping = $SS->{ShippingServiceCost}->{content};
      $PriShipAddl = $SS->{ShippingServiceAdditionalCost}->{content};
    }
    elsif ( $SS->{ShippingService} eq 'Other' or 
            $SS->{ShippingService} eq 'USPSParcel' or 
            $SS->{ShippingService} eq 'USPSStandardPost' ) {   

      if ( $totalweight > 15.9 ) {
        $PriShipping = $SS->{ShippingServiceCost}->{content};
        $PriShipAddl = $SS->{ShippingServiceAdditionalCost}->{content};
      }
      elsif ( $totalweight >0 and $totalweight <= 15.9 )  {
        $StdShipping = $SS->{ShippingServiceCost}->{content};
        $StdShipAddl = $SS->{ShippingServiceAdditionalCost}->{content};
      }
      else {
        print $ofh_ERR "\nOdd SS + Unknown Weight: SS='$SS->{ShippingService}' ID: '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
      }

    }
    else {
      print $ofh_ERR "\nUnknown DOM SS: $SS->{ShippingService} - ID: '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
      next;
    }
  }

  # Flat rate, Domestic discount shipping profile name
  if ( defined $S->{FlatShippingDiscount}->{DiscountProfile}->{DiscountProfileName} ) {
      $DomShipProfID = $S->{FlatShippingDiscount}->{DiscountProfile}->{DiscountProfileName}; 
  }
  elsif( defined($S->{ShippingServiceOptions}->[0]->{ShippingServiceAdditionalCost}->{content}) && $S->{ShippingServiceOptions}->[0]->{ShippingServiceAdditionalCost}->{content} != 0 ) {
      # determine what the profile name should be, based on the additional amount charged
      my $extra_amt = $S->{ShippingServiceOptions}->[0]->{ShippingServiceAdditionalCost}->{content};
      $DomShipProfID = sprintf("add_%1.2f_addl", $extra_amt);
      print $ofh_ERR "\nNote: created Domestic Discount Shipping Profile '$DomShipProfID' : '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
  }
  else {
    # only warn if no profile AND it's not free shipping
    print $ofh_ERR "\nWARNING: no Domestic Discount Shipping Profile and not free shipping : '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
  }

  # Get Intl shipping rates
  my ($IntlStdShipping, $IntlStdShipAddl, $IntlPriShipping, $IntlPriShipAddl, $IntlShipProfID);
  for my $SS ( @$SI ) {

    # exclude special shipping prices to CA,MX,etc...
    next if ( $SS->{ShippingService} eq 'OtherInternational' && $SS->{ShipToLocation}->[0] ne 'Worldwide' ); 
    next if ( $SS->{ShippingService} eq 'USPSPriorityMailInternational' && $SS->{ShipToLocation}->[0] ne 'Worldwide' ); 

    if ( $SS->{ShippingService} eq 'OtherInternational' ) {
      $IntlStdShipping = $SS->{ShippingServiceCost}->{content};
      $IntlStdShipAddl = $SS->{ShippingServiceAdditionalCost}->{content};
    }
    elsif ( $SS->{ShippingService} eq 'USPSPriorityMailInternational' ) {
      $IntlPriShipping = $SS->{ShippingServiceCost}->{content};
      $IntlPriShipAddl = $SS->{ShippingServiceAdditionalCost}->{content};
      print $ofh_ERR "\nPriority INTL SS: $SS->{ShippingService} - ID: '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
    }
    else {
      print $ofh_ERR "\nUnknown INTL SS: '$SS->{ShippingService}' ID: '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
    }
  }

  # Flat rate, International discount shipping profile name
  if ( defined $S->{InternationalFlatShippingDiscount}->{DiscountProfile}->{DiscountProfileName} ) {
      $IntlShipProfID = $S->{InternationalFlatShippingDiscount}->{DiscountProfile}->{DiscountProfileName}; 
  }
  elsif( defined($S->{InternationalShippingServiceOptions}->[0]->{ShippingServiceAdditionalCost}->{content}) && 
         $S->{InternationalShippingServiceOptions}->[0]->{ShippingServiceAdditionalCost}->{content} != 0 ) {
      # determine what the profile name should be, based on the additional amount charged
      my $extra_amt = $S->{InternationalShippingServiceOptions}->[0]->{ShippingServiceAdditionalCost}->{content};
      $IntlShipProfID = sprintf("add_%1.2f_addl", $extra_amt);
      print $ofh_ERR "\nNote: created International Discount Shipping Profile '$IntlShipProfID' : '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
  }
  else {
    # only warn if no profile AND it's not free shipping
    print $ofh_ERR "\nWARNING: no International Discount Shipping Profile and not free shipping : '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
  }

  if( defined $shipProfLookup->{$DomShipProfID} ) {
    $DomShipProfID = $shipProfLookup->{$DomShipProfID};
  }
  else {
    print $ofh_ERR "\nWARNING: Domestic Discount Shipping Profile ($DomShipProfID) NOT DEFINED: '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
  }

  if( defined $shipProfLookup->{$IntlShipProfID} ) {
    $IntlShipProfID = $shipProfLookup->{$IntlShipProfID};
  }
  else {
    print $ofh_ERR "\nWARNING: Intl Discount Shipping Profile ($IntlShipProfID) NOT DEFINED: '$item_id' SKU: '$ebayListing->{SKU}' TITLE: '$ebayListing->{Title}'";
  }

  $item_count++;

  # Get Category info
  my $ebayCategoryID = $ebayListing->{PrimaryCategory}->{CategoryID};                              # Ebay category ID (primary)
  my $ebayCategoryName = $ebayListing->{PrimaryCategory}->{CategoryName};                              # Ebay category ID (primary)
  my ($primaryStoreCategoryID,$secondaryStoreCategoryID)  = GetCategoryID($ebayListing);         # Get store category ID's
  my $primaryStoreCategoryName = $categoryIDHash->{$primaryStoreCategoryID};                     # Store category (primary)
  my $secondaryStoreCategoryName = $categoryIDHash->{$secondaryStoreCategoryID};                 # Store category (secondary)
  my $storeCategoryName = $secondaryStoreCategoryName ? "${primaryStoreCategoryName}::${secondaryStoreCategoryName}" : $primaryStoreCategoryName;

  my $brand = $itemSpecificsHash->{Brand} ? $itemSpecificsHash->{Brand} : "";
  my $mpn   = $itemSpecificsHash->{MPN} ? $itemSpecificsHash->{MPN} : "";
  my $fullDescription  = $ebayListing->{DESCRIPTION};
  $fullDescription =~ s/"/""/g;

  ###########################################################################################################################
  #
  #    VARIATION LISTING
  #
  ###########################################################################################################################
  my $variation = '';
  if ( defined $ebayListing->{Variations} ) { 

    # Build list of variations from EBAY
    my $ebayVariations = {};
    my $ebayVariationType;
    for my $v ( @{ $ebayListing->{Variations}->{Variation} } ) {
      my $key = $v->{VariationSpecifics}->{NameValueList}->[0]->{Value}; # technically a list, but there should only be one level
      my $type = $v->{VariationSpecifics}->{NameValueList}->[0]->{Name}; # technically a list, but there should only be one level
      $ebayVariations->{$key} = $v;
      $ebayVariationType = $type;
    }

    # Build a hash of Variation Images from EBAY      # NOTE: Only good if pictures are self-hosted! Otherwise eBay (EPS) returns the 400x400 pic
    my $variationImages = {};
    my $variationImageLookup = {};
    for my $v ( @{$ebayListing->{Variations}->{Pictures}->{VariationSpecificPictureSet}} ) {
      if ( defined $v->{ExternalPictureURL} ) {
        $variationImages->{ $v->{VariationSpecificValue} } = $v->{ExternalPictureURL};
      }
      elsif ( defined $v->{PictureURL} ) {
        $variationImages->{ $v->{VariationSpecificValue} } = $v->{PictureURL};
        print $ofh_ERR "\nWARNING : Using EBAY HOSTED VARIATION Image!!!  TITLE: '$ebayListing->{Title}' VAR: '$v->{VariationSpecificValue}'";
      }
      else {
        # no variation image
        next;
      }

      if ( ref($variationImages->{$v->{VariationSpecificValue}}) =~ /ARRAY/i ) {
        for my $p ( @{ $variationImages->{$v->{VariationSpecificValue}} } ) {
          $variationImageLookup->{ $p } = 1;
        }
      } else {
        $variationImageLookup->{ $variationImages->{$v->{VariationSpecificValue}} } = 1;
      }

    }

    my $writeParentSKU = 1;    # Write the Variation Parent in addition to the first variation, the first time through the loop

    ################################################################################
    # LOOP over each variation in this listing
    ################################################################################
    for my $variation ( sort keys %$ebayVariations ) {

      # Get EBAY Variation specific hash
      my $ebayVar        = $ebayVariations->{$variation};
      my $variationSKU   = $ebayVar->{SKU};

      # Get data from INVENTORY table
      my $var = {};
      eval {
        $sth_productInfo->execute($variationSKU) or die "can't execute stmt";
        $var = $sth_productInfo->fetchrow_hashref;
      };
      if ( $@ ) { print $ofh_ERR "\n\nERROR: $@ \n"; print "\nTitle: $title"; die; }

      my $cost = $var->{cost} || '0';

      # Weight
      my $majorweight = POSIX::floor($var->{weight} / 16);
      my $minorweight = $var->{weight} % 16;
      my $totalweight = $var->{weight};
      
      if ( ($var->{weight} != $ebayWeight) ) { # in total ouches
        print $ofh_ERR "WARNING: itemid=$item_id - weight differs from ebay and Inventory tables";
      }

      # Use weight in Inventory table first, then Ebay ( TODO: might want to change this )
      $majorweight = $majorweight ? $majorweight : $ebaymajorweight;
      $minorweight = $minorweight ? $minorweight : $ebayminorweight;
      $totalweight = $totalweight ? $totalweight : $ebayWeight;

      # Variation Image
      my ($imageurl, $vpic2, $vpic3);
      if ( ref($variationImages->{$variation}) =~ /ARRAY/i ) {
          $imageurl = $variationImages->{$variation}->[0];
          $vpic2    = $variationImages->{$variation}->[1] if ( defined $variationImages->{$variation}->[1] );
          $vpic3    = $variationImages->{$variation}->[2] if ( defined $variationImages->{$variation}->[2] );
        }
      else {
          $imageurl     = $variationImages->{$variation};              
      }

      # UPC Validation
      if ( ($ebayVar->{VariationProductListingDetails}->{UPC} && $var->{upc}) && ($ebayVar->{VariationProductListingDetails}->{UPC} ne $var->{upc}) ) {
        print $ofh_ERR "\nWARNING: itemID=$item_id  ebay UPC does not match INVENTORY table UPC";
      }

      # Basic Product Import 
      my $varTitle         = $title . ' - ' . $variation;
      my $supplier         = $var->{supplier};
      my $purchasePrice    = $cost;
      my $retailPrice      = $ebayVar->{StartPrice}->{content};
      my $weight           = $var->{weight} || $ebayWeight || '0';
      my $barcode          = $ebayVar->{VariationProductListingDetails}->{UPC} ? $ebayVar->{VariationProductListingDetails}->{UPC} : $var->{upc};
      my $dimDepth         = '6';
      my $dimHeight        = '4';
      my $dimWidtht        = '4';
      my $shortDescription = $varTitle;                                # NOTE: nothing maps to this, this will have to be updated manually

      # Stock Level Import
      my $eQuantitySold    = defined $ebayVar->{SellingStatus}->{QuantitySold} ? $ebayVar->{SellingStatus}->{QuantitySold} : 0;
      my $eQuantity        = defined $ebayVar->{Quantity} ? $ebayVar->{Quantity} : 0;
      my $stockLevel       = $eQuantity - $eQuantitySold; # from eBay not eBT !
      my $minimumLevel     = 1;
      my $unitCost         = $cost;
      my $stockValue       = $stockLevel * $unitCost;
      my $location         = 'ADDI';
      my $binRack          = $var->{location} || '0-0-0';

      # Parent SKU related values
      my $mainimageurl   = $ebayListing->{PictureDetails}->{ExternalPictureURL} || $ebayListing->{IMAGE1};
      my $pic2           = $ebayListing->{IMAGE2};
      my $pic3           = $ebayListing->{IMAGE3};
      my $parentSKU      = $ebayListing->{SKU};
      my $variationGroup = $title;                # NOTE: for variations, title is 'variation group' (NOTE: deprecated)

      # Clean up fields 
      no warnings;
#       $varTitle         =~ s/"/''/g;    # TODO: maybe repace " with 'inches' or 'in.' instead?
#       $shortDescription =~ s/"/''/g;    #       although it's possible " doesn't represent inches, maybe it's a quoted word, e.g. "word"
#       $fullDescription  =~ s/"/''/g; 
#       $variationGroup   =~ s/"/''/g;
      $purchasePrice    = sprintf("%0.2f",$purchasePrice);
      $retailPrice      = sprintf("%0.2f",$retailPrice);
      $unitCost         = sprintf("%0.2f",$unitCost);

      # Validation
      if ( ! $variation )  { print $ofh_ERR "\nERROR: Cannot determine variation style!!!    TITLE: '$title' VAR: '$variation'"; }
      if ( ! $fullDescription ) { print $ofh_ERR "\nERROR: Cannot determine fullDescription!!!    TITLE: '$title' VAR: '$variation'"; }
      if ( ! $mainimageurl )    { print $ofh_ERR "\nERROR: Cannot determine PRIMARY Image!!!      TITLE: '$title' VAR: '$variation'"; }
      if ( ! $imageurl        ) { print $ofh_ERR "\nWARNING: Cannot determine VARIATION Image!!!    TITLE: '$title' VAR: '$variation'"; }

      #
      # Variation Parent
      #
      if ( $writeParentSKU ) {
        # Parent SKU record ( replaces "variationGroup" column in "Basic Product Import" )
        print $ofh_VG qq/$parentSKU,$variationGroup\n/; # parentSKU = parentSKU

        # Images
        print $ofh_IMG qq/$parentSKU,1,"$mainimageurl"\n/;   # 1 - isPrimary
        print $ofh_IMG qq/$parentSKU,0,"$pic2"\n/ if ($pic2 && ! defined $variationImageLookup->{$pic2} ); # exclude duplicate images
        print $ofh_IMG qq/$parentSKU,0,"$pic3"\n/ if ($pic3 && ! defined $variationImageLookup->{$pic3} ); # exclude duplicate images

        # Full HTML Description
        print $ofh_DES qq/$parentSKU,"$variationGroup",$retailPrice,"$fullDescription"\n/;  # TODO: what should retailPrice be if they're different prices?
                                                                                               #       might have to calc min/max, then move this print, after loop
        # Product Attributes - Variation Parent
        # Shipping
        print $ofh_ATT qq/$parentSKU,Attribute,StdShipping,"$StdShipping"\n/ if (defined $StdShipping);   
        print $ofh_ATT qq/$parentSKU,Attribute,StdShipAddl,"$StdShipAddl"\n/ if (defined $StdShipAddl);   
        print $ofh_ATT qq/$parentSKU,Attribute,PriShipping,"$PriShipping"\n/ if (defined $PriShipping);   
        print $ofh_ATT qq/$parentSKU,Attribute,PriShipAddl,"$PriShipAddl"\n/ if (defined $PriShipAddl);   
        print $ofh_ATT qq/$parentSKU,Attribute,DomShipProfID,"$DomShipProfID"\n/     if (defined $DomShipProfID);   
        print $ofh_ATT qq/$parentSKU,Attribute,IntlStdShipping,"$IntlStdShipping"\n/ if (defined $IntlStdShipping);   
        print $ofh_ATT qq/$parentSKU,Attribute,IntlStdShipAddl,"$IntlStdShipAddl"\n/ if (defined $IntlStdShipAddl);   
        print $ofh_ATT qq/$parentSKU,Attribute,IntlPriShipping,"$IntlPriShipping"\n/ if (defined $IntlPriShipping);   
        print $ofh_ATT qq/$parentSKU,Attribute,IntlPriShipAddl,"$IntlPriShipAddl"\n/ if (defined $IntlPriShipAddl);   
        print $ofh_ATT qq/$parentSKU,Attribute,IntlShipProfID,"$IntlShipProfID"\n/   if (defined $IntlShipProfID);   

        # Categories
        print $ofh_ATT qq/$parentSKU,Attribute,PrimaryEbayCategory,"$ebayCategoryID"\n/;

        # Item Specifics
        for my $attrName ( sort keys %$itemSpecificsHash ) {
          my $attrValue = $itemSpecificsHash->{$attrName};
          $attrValue =~ s/"/""/g; # fix excel/csv printing issue
          #$attrValue =~ s/&/and/g;
          $allItemSpecifics->{$attrName} = 1; 
          $allItemsItemSpecifics->{$parentSKU}->{$attrName} = $attrValue;
          print $ofh_ATT qq/$parentSKU,Specification,$attrName,"$attrValue"\n/;
        }

        # Store Categories
        print $ofh_ATT qq/$parentSKU,Attribute,PrimaryStoreCategory,"$primaryStoreCategoryID"\n/;
        print $ofh_ATT qq/$parentSKU,Attribute,SecondaryStoreCategory,"$secondaryStoreCategoryID"\n/ if ($secondaryStoreCategoryID);   

        $writeParentSKU = 0;
      }

      #
      # Individual variation item (non-parent):
      #

      # NOTE: Escaping embedded double quotes in title, variation, and description, so they can viewed correctly in Excel
      $title =~ s/"/""/g;
      $variation =~ s/"/""/g;

#       "Product Name","ItemID","Custom Label","RelationshipDetails","Product Code","Bar Code","Matrix Item"
#       "Variation Type","Matrix SKU Code","Product Category","Manufacturer","Manufacturer Part No","Website"
#       "Product Images","Description","Unit Cost","Stock Location","Qty in Stock","Bin Location","Reorder Level"
#       "Product Stock Manager","Send Stock Notifications","Auto Create PO at Reorder Level","eBay PriceBook","Preferred Vendor"
#
#       "Preferred Vendor Part Number","Preferred Vendor Price","Preferred Vendor Order Qty","SEO Title","SEO Description"
#       "SEO Keywords","Income Account","COGS Account","Asset Account","QuickBooks Item","Tax Category"
#       "Length (in)","Width (in)","Height (in)","Weight-Major (lbs)","Weight-Minor (oz)","eBay Item ID","eBay Variation","SKU"
#       "ASIN","FNSKU","Discontinued","UPC Code","ISBN","EAN","Brand","EPID"
#       "EbayCategoryID","EbayCategoryName"

      # AgileIron Product Import
      print $ofh_AIM qq/"$title",$item_id,$variationSKU,,$parentSKU,$barcode,"yes",/; # Matrix Item = Variation (i.e. "yes")
      print $ofh_AIM qq/$ebayVariationType,$variationSKU,"$storeCategoryName","$brand","$mpn",,/;
      print $ofh_AIM qq/,"$fullDescription",$unitCost,$location,$stockLevel,$binRack,1,/;
      print $ofh_AIM qq/admin,yes,no,$retailPrice,"$supplier",/; # TODO: Supplier can differ from manufacturer (brand) 
      print $ofh_AIM qq/,,,,,/; 
      print $ofh_AIM qq/,,,,,taxable,/;
      print $ofh_AIM qq/6,4,4,$majorweight,$minorweight,$item_id,"$variation",$variationSKU,/;
      print $ofh_AIM qq/,,,$barcode,,,"$brand",/;
      print $ofh_AIM qq/,$ebayCategoryID,"$ebayCategoryName"/;
      print $ofh_AIM "\n";

      # Basic Product Import
      print $ofh_BPI qq/$variationSKU,"$varTitle",$purchasePrice,$retailPrice,$weight,$barcode,$primaryStoreCategoryName,"$shortDescription",$dimHeight,$dimDepth,$dimDepth\n/;

      # Stock Level Import
      print $ofh_SLI qq/$variationSKU,$stockLevel,$minimumLevel,$unitCost,$stockValue,$location,$binRack\n/;

      # Product Attributes

      # Shipping
      print $ofh_ATT qq/$variationSKU,Attribute,StdShipping,"$StdShipping"\n/ if (defined $StdShipping);   
      print $ofh_ATT qq/$variationSKU,Attribute,StdShipAddl,"$StdShipAddl"\n/ if (defined $StdShipAddl);   
      print $ofh_ATT qq/$variationSKU,Attribute,PriShipping,"$PriShipping"\n/ if (defined $PriShipping);   
      print $ofh_ATT qq/$variationSKU,Attribute,PriShipAddl,"$PriShipAddl"\n/ if (defined $PriShipAddl);   
      print $ofh_ATT qq/$variationSKU,Attribute,DomShipProfID,"$DomShipProfID"\n/     if (defined $DomShipProfID);   
      print $ofh_ATT qq/$variationSKU,Attribute,IntlStdShipping,"$IntlStdShipping"\n/ if (defined $IntlStdShipping);   
      print $ofh_ATT qq/$variationSKU,Attribute,IntlStdShipAddl,"$IntlStdShipAddl"\n/ if (defined $IntlStdShipAddl);   
      print $ofh_ATT qq/$variationSKU,Attribute,IntlPriShipping,"$IntlPriShipping"\n/ if (defined $IntlPriShipping);   
      print $ofh_ATT qq/$variationSKU,Attribute,IntlPriShipAddl,"$IntlPriShipAddl"\n/ if (defined $IntlPriShipAddl);   
      print $ofh_ATT qq/$variationSKU,Attribute,IntlShipProfID,"$IntlShipProfID"\n/   if (defined $IntlShipProfID);   

      # Categories
      print $ofh_ATT qq/$variationSKU,Attribute,PrimaryEbayCategory,"$ebayCategoryID"\n/;
      $allEbayCategories->{$ebayCategoryID} = $ebayCategoryName;

      # Item Specifics
      for my $attrName ( sort keys %$itemSpecificsHash ) {
        my $attrValue = $itemSpecificsHash->{$attrName};
        $attrValue =~ s/"/''/g;
        $attrValue =~ s/&/and/g;
        print $ofh_ATT qq/$variationSKU,Specification,$attrName,"$attrValue"\n/;

      }

      # Variations
      print $ofh_ATT qq/$variationSKU,Attribute,VariationStyle,"$variation"\n/;      # variation only, not a parent attribute

      # Store Categories
      print $ofh_ATT qq/$variationSKU,Attribute,PrimaryStoreCategory,"$primaryStoreCategoryID"\n/;
      print $ofh_ATT qq/$variationSKU,Attribute,SecondaryStoreCategory,"$secondaryStoreCategoryID"\n/  if ($secondaryStoreCategoryID);   

      # Supplier
      print $ofh_SUP qq/$variationSKU,$supplier,$purchasePrice\n/ if ($supplier);

      # Images  
      print $ofh_IMG qq/$variationSKU,1,"$imageurl"\n/ if ($imageurl);   # 1 - isPrimary
      print $ofh_IMG qq/$variationSKU,0,"$vpic2"\n/ if ($vpic2);  
      print $ofh_IMG qq/$variationSKU,0,"$vpic3"\n/ if ($vpic3); 

      # Full HTML Description
      print $ofh_DES qq/$variationSKU,"$varTitle",$retailPrice,"$fullDescription"\n/;

      # Stock Item Variation
      print $ofh_SIV qq/$variationSKU,$parentSKU\n/;  # parentSKU = parent SKU

      use warnings;
    }
  }
  else {
    ################################################################################
    # NON-VARIATION LISTING
    ################################################################################
    my $SKU      = $ebayListing->{SKU};

    # get data from storage location table
    my $slt = {};
    eval {
      $sth_productInfo->execute($SKU) or die "can't execute stmt";
      $slt = $sth_productInfo->fetchrow_hashref;
    };
    if ( $@ ) {
      print $ofh_ERR "\n\nERROR: $@ \n";
      print $ofh_ERR "\ntitle: '$title' \n";
      die;
    }

    # Weight
    my $majorweight = POSIX::floor($slt->{weight} / 16);
    my $minorweight = $slt->{weight} % 16;
    my $totalweight = $slt->{weight};
    
    if ( ($slt->{weight} != $ebayWeight) ) { # in total ouches
      print $ofh_ERR "WARNING: itemid=$item_id - weight differs from ebay and Inventory tables";
    }

    # Use weight in Inventory table first, then Ebay ( TODO: might want to change this )
    $majorweight = $majorweight ? $majorweight : $ebaymajorweight;
    $minorweight = $minorweight ? $minorweight : $ebayminorweight;
    $totalweight = $totalweight ? $totalweight : $ebayWeight;

    my $cost = $slt->{cost} || '0';

    # Images
    my $imageurl = $ebayListing->{PictureDetails}->{ExternalPictureURL} || $ebayListing->{IMAGE1};
    my $pic2     = $ebayListing->{IMAGE2};
    my $pic3     = $ebayListing->{IMAGE3};

    # UPC Validation
    if ( ($itemSpecificsHash->{UPC} && $slt->{upc}) && 
         ($itemSpecificsHash->{UPC} ne $slt->{upc}) ) {
        print $ofh_ERR "\nWARNING: itemID=$item_id  ebay UPC does not match INVENTORY table UPC";
    }

    # Basic Product Import 
    my $supplier         = $slt->{supplier};
    my $purchasePrice    = $cost;
    my $retailPrice      = $ebayListing->{StartPrice}->{content};
    my $weight           = $slt->{weight} || '0';
    my $barcode          = $itemSpecificsHash->{UPC} ? $itemSpecificsHash->{UPC} : $slt->{upc};
    my $shortDescription = $title;                                   # NOTE: nothing maps to this field, update manually if needed
    my $dimHeight        = '10';
    my $dimWidtht        = '8';
    my $dimDepth         = '10';

    # Stock Level Import
    my $eQuantitySold    = defined $ebayListing->{SellingStatus}->{QuantitySold} ? $ebayListing->{SellingStatus}->{QuantitySold} : 0;
    my $stockLevel       = $ebayListing->{Quantity} - $eQuantitySold; # from eBay not eBT !
    my $minimumLevel     = 1;
    my $unitCost         = $cost;
    my $stockValue       = $stockLevel * $unitCost;
    my $location         = 'ADDI';
    my $binRack          = $slt->{location} || '0-0-0';

    no warnings;
#     $title            =~ s/"/''/g;
#     $shortDescription =~ s/"/''/gt
#     $fullDescription  =~ s/"/''/g; 
    $purchasePrice    = sprintf("%0.2f",$purchasePrice);
    $retailPrice      = sprintf("%0.2f",$retailPrice  );
    $unitCost         = sprintf("%0.2f",$unitCost     );

    # Validations
    if ( ! $fullDescription ) { print $ofh_ERR "\nERROR: Cannot determine fullDescription!!!    TITLE: '$title' VAR: '$variation'\n"; }
    if ( ! $imageurl )        { print $ofh_ERR "\nERROR: Cannot determine PRIMARY Image!!!      TITLE: '$title' VAR: '$variation'\n"; }

    # AgileIron Product Import
    print $ofh_AI qq/"$title",$item_id,$SKU,,$SKU,$barcode,no,/; # MatrixItem="no"
    print $ofh_AI qq/,,"$storeCategoryName","$brand","$mpn",,/;
    print $ofh_AI qq/,"$fullDescription",$unitCost,$location,$stockLevel,$binRack,1,/;
    print $ofh_AI qq/admin,yes,no,$retailPrice,"$supplier",/; # TODO: Supplier can differ from manufacturer (brand) 
    print $ofh_AI qq/,,,,,/;
    print $ofh_AI qq/,,,,,taxable,/;
    print $ofh_AI qq/6,4,4,$majorweight,$minorweight,$item_id,,$SKU,/;
    print $ofh_AI qq/,,,$barcode,,,"$brand",/;
    print $ofh_AI qq/,$ebayCategoryID,"$ebayCategoryName"/;
    print $ofh_AI "\n";

    # Basic Product Import 
    print $ofh_BPI qq/$SKU,"$title",$purchasePrice,$retailPrice,$weight,$barcode,$primaryStoreCategoryName,"$shortDescription",$dimHeight,$dimDepth,$dimDepth\n/;

    # Stock Level Import
    print $ofh_SLI qq/$SKU,$stockLevel,$minimumLevel,$unitCost,$stockValue,$location,$binRack\n/;

    # Product Attributes
    # Shipping
    print $ofh_ATT qq/$SKU,Attribute,StdShipping,"$StdShipping"\n/ if (defined $StdShipping);   
    print $ofh_ATT qq/$SKU,Attribute,StdShipAddl,"$StdShipAddl"\n/ if (defined $StdShipAddl);   
    print $ofh_ATT qq/$SKU,Attribute,PriShipping,"$PriShipping"\n/ if (defined $PriShipping);   
    print $ofh_ATT qq/$SKU,Attribute,PriShipAddl,"$PriShipAddl"\n/ if (defined $PriShipAddl);   
    print $ofh_ATT qq/$SKU,Attribute,DomShipProfID,"$DomShipProfID"\n/     if (defined $DomShipProfID);   
    print $ofh_ATT qq/$SKU,Attribute,IntlStdShipping,"$IntlStdShipping"\n/ if (defined $IntlStdShipping);   
    print $ofh_ATT qq/$SKU,Attribute,IntlStdShipAddl,"$IntlStdShipAddl"\n/ if (defined $IntlStdShipAddl);   
    print $ofh_ATT qq/$SKU,Attribute,IntlPriShipping,"$IntlPriShipping"\n/ if (defined $IntlPriShipping);   
    print $ofh_ATT qq/$SKU,Attribute,IntlPriShipAddl,"$IntlPriShipAddl"\n/ if (defined $IntlPriShipAddl);   
    print $ofh_ATT qq/$SKU,Attribute,IntlShipProfID,"$IntlShipProfID"\n/   if (defined $IntlShipProfID);   

    # eBay categories
    print $ofh_ATT qq/$SKU,Attribute,PrimaryEbayCategory,"$ebayCategoryID"\n/;
    $allEbayCategories->{$ebayCategoryID} = $ebayCategoryName;

    # Item Specifics
    for my $attrName ( sort keys %$itemSpecificsHash ) {
      my $attrValue = $itemSpecificsHash->{$attrName};
      $attrValue =~ s/"/''/g;
      #$attrValue =~ s/&/and/g;
      $allItemSpecifics->{$attrName} = 1; 
      $allItemsItemSpecifics->{$SKU}->{$attrName} = $attrValue;
      print $ofh_ATT qq/$SKU,Specification,$attrName,"$attrValue"\n/;
    }

    # Store Categories
    print $ofh_ATT qq/$SKU,Attribute,PrimaryStoreCategory,"$primaryStoreCategoryID"\n/;
    print $ofh_ATT qq/$SKU,Attribute,SecondaryStoreCategory,"$secondaryStoreCategoryID"\n/  if ($secondaryStoreCategoryID);   

    # Supplier
    print $ofh_SUP qq/$SKU,$supplier,$purchasePrice\n/ if ($supplier);

    # Images  
    print $ofh_IMG qq/$SKU,1,"$imageurl"\n/;    # 1 - isPrimary
    print $ofh_IMG qq/$SKU,0,"$pic2"\n/  if ($pic2);   
    print $ofh_IMG qq/$SKU,0,"$pic3"\n/  if ($pic3);  

    # Full HTML Description
    print $ofh_DES qq/$SKU,"$title",$retailPrice,"$fullDescription"\n/;

    use warnings;
    #print "\n",$rec_count++;
  }
  #exit if ( $rec_count > 20 );
}

close $ofh_AI;
close $ofh_AIM;
close $ofh_BPI;
close $ofh_SLI;
close $ofh_ATT;
close $ofh_SUP;
close $ofh_IMG;
close $ofh_DES;
close $ofh_ERR;

# TODO: Maybe we do this later...
# Get Ebay Category name and Item Specifics 
# for my $categoryID ( keys $allEbayCategories ) {
    # Make API call to get recommended item specifics
# }

#
# All Current Item specifics for each Item
#
my @ispecs = ('SKU', sort keys %$allItemSpecifics);
my $ispec_headers = join( ',', @ispecs );
print $ofh_AIIS "$ispec_headers\n";

my %iso;
my $ispos = 0;
for my $is ( @ispecs ) {
  $iso{$is} = $ispos++; 
}

for my $sku ( keys %$allItemsItemSpecifics ) {
  my @isvalues = ();
  $isvalues[0] = $sku;
  while( my ($isname,$isvalue) = each %{$allItemsItemSpecifics->{$sku}} ) {
    if ( ! defined( $iso{$isname} ) ) {
      print "ERROR: SKU=$sku  ISNAME=$isname\n";
      next;
    }
    my $pos = $iso{$isname}; 
    $isvalue =~ s/"/""/g;
    $isvalues[$pos] = qq/"$isvalue"/;
  }
  print $ofh_AIIS join(',',@isvalues),"\n"; 
}
close $ofh_AIIS;


print <<END;
  Ebay Listings: $all_items_count
  eBT Listings : $item_count
END


exit;

####################################################################################################

sub GetCategoryID {
  my $eL = shift;
  my $c1 = $eL->{Storefront}->{StoreCategoryID};
  my $c2 = $eL->{Storefront}->{StoreCategory2ID};

  if ( $c2 ) {
    if ( ($c1 == $categoryNameHash->{'Autism & Special Needs'} or $c1 == $categoryNameHash->{'CLEARANCE'})   and $c2 ) {
      return($c2,$c1);
    }
    else {
      return($c1,$c2);
    }
  }
  else {
    return ($c1,'');
  }
}

sub LoadCategory {
  my ($hr_cat, $fullname) = @_;
  my $currentID   = $hr_cat->{CategoryID};

  if ( defined $hr_cat->{ChildCategory} ) {
    # fix node if it's a hash instead of array reference
    if ( ref($hr_cat->{ChildCategory}) =~ /.*hash.*/i ) {
      my $tmp = $hr_cat->{ChildCategory};
      $hr_cat->{ChildCategory} = [];
      $hr_cat->{ChildCategory}->[0] = $tmp;
    }

    for my $hr_scat ( @{$hr_cat->{ChildCategory}} ) {
      my $childname  = "${fullname}::" . $hr_scat->{Name};
      LoadCategory( $hr_scat, $childname );
    }
  }
  else {
    $categoryIDHash->{$currentID} = $fullname;
    $categoryNameHash->{$fullname} = $currentID;
  }
}

sub parse_description_html {
  my $listing = shift;
  my $html    = $listing->{Description};

  die "\n\nERROR: NO 'Description' key in the ebayListing hash!"
    if ( ! $html );

  $html = $html_filter->process( $html );
  #$html = decode_entities($html);

  $listing->{DESCRIPTION} = $html;
}

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
      ForceArray=>['InternationalShippingServiceOption','ShippingServiceOptions','ShipToLocation','Variation','NameValueList','VariationSpecificPictureSet' ] );
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

