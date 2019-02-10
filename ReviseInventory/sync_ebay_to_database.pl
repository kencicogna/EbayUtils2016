#!/usr/bin/perl -w -- 


use strict;


use strict;
use lib '../cfg';

use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request;
use HTTP::Headers;

use DBI;
use XML::Simple qw(XMLin XMLout);
use Date::Calc 'Today';
use Data::Dumper 'Dumper';			$Data::Dumper::Sortkeys = 1;
use File::Copy qw(copy move);
use POSIX qw(strftime);
use Getopt::Std;
use List::MoreUtils qw/uniq/;
use Text::CSV_XS;

use EbayConfig;

####################################################################################################
# Command Line Options
####################################################################################################
my %opts;
getopts('ueDi:o:',\%opts);

my $UPDATE      = $opts{u} ? $opts{u} : 0;
my $UPDATE_EBAY = $opts{e} ? $opts{e} : 0;
my $DEBUG       = $opts{D} ? $opts{D} : 0;
my $itemId      = $opts{i} ? $opts{i} : 0;  # Only process one item (default is all items)
my $outfile     = $opts{o} ? $opts{o} : 0;

####################################################################################################
# Initialization
####################################################################################################
my $timestamp = strftime '%Y%m%d_%H%M%S', gmtime();
my $host = `hostname`; chomp($host);

# Set correct Path and ODBC connection based on which computer it's running on. This is not a good solution and may not be needed.
my $ODBC;
if ( $host eq "Ken-Laptop" ) {
  chdir('C:/Users/Ken/Documents/GitHub/EbayUtils2016/ReviseInventory');
  $ODBC = 'BTData_PROD_SQLEXPRESS';
}
else {
  chdir('C:/Users/Owner/Documents/GitHub/EbayUtils2016/ReviseInventory');
  $ODBC = 'BTData_PROD_SQLEXPRESS';
}

# Parse itemId(s) if provided
my @all_items;
if ( $itemId ) {
  my @item_list = split (',', $itemId);
	push(@all_items,@item_list);
}

# Output file and CSV Parser
my ($ofh, $csv);
if ( $outfile ) {
  $csv = Text::CSV_XS->new ({ binary => 1, auto_diag => 1, eol => $/ });
  open $ofh, ">:encoding(utf8)", $outfile or die "Can't open output file '$outfile': $!";
}

###################################################
# Ebay API Info                                   #
###################################################

# Ebay API Request Headers
my $header = $EbayConfig::ES_http_header;

# Ebay Authentication Token
my $eBayAuthToken = $EbayConfig::ES_eBayAuthToken;


# Supplier Name / Supplier ID (TODO: store on a DB table later.  Leaving in for now, maybe put a check in the the supliers are correct.)
my @all_suppliers = (
	 'Toysmith'
	,'Patch Products'
	,'Westminster'
	,'Learning Resources'
	,'Dwink'
	,'Warm Fuzzy Toys'
	,'FCTRY'
	,'Mary Meyer'
	,'Myself Belts'
	,'Melissa and Doug'
	,'Toyops'
	,'Potty Watch'
	,'Best of Toys'
	,'Hohner'
	,'The Pencil Grip'
	,'Educational Insights'
	,'Boston America'
	,'Tedco'
	,'Tangle'
	,'Play Visions'
	,'Peaceable Kingdom'
	,'Accoutrements'
	,'Allermates'
	,'Fred'
	,'Knot Genie'
	,'NPW'
	,'Fun Express'
	,'Billy Bob'
	,'PBNJ'
	,'Gamago'
	,'Eeboo'
	,'Eureka'
	,'Triops'
	,'International Playthings'
	,'International Arrivals'
	,'Aerobie'
	,'Mudpuppy'
	,'Toobaloo'
	,'Hickory'
	,'Kidrobot'	
	,'Price Productions'
	,'Funbites'
	,'Time Timer'
	,'Oriental Trading'
	,'Geddes'
	,'Trend'
	,'Original Toy Company'
	,'Chewy Tubes'
	,'ChewNoodle'
	,'Crazy Aarons Thinking Putty'
	,'US Toy'
	,'KIPP'
	,'Basic Fun'
	,'Hog Wild'
	,'Gymnic'
	,'Janod'
	,'HandiWriter'
	,'ALEX'
  ,'Ravensburger',
  ,'Garlic Press'
  ,'Paladone'
  ,'Rich Frog'
);


###################################################
# XML API Request Templates                       #
###################################################

# Gets all listings, 200 at a time 
my $request_getmyebayselling_default = <<END_XML;
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

# Get select item details
my $request_getitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<GetItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
	<RequesterCredentials>
		<eBayAuthToken>$eBayAuthToken</eBayAuthToken>
	</RequesterCredentials>
	<WarningLevel>High</WarningLevel>
	<ItemID>__ItemID__</ItemID>
	<IncludeItemSpecifics>TRUE</IncludeItemSpecifics>

	<OutputSelector>PictureDetails</OutputSelector>
	<OutputSelector>SKU</OutputSelector>
	<OutputSelector>Title</OutputSelector>
	<OutputSelector>VariationSpecificPictureSet</OutputSelector>
	<OutputSelector>VariationSpecifics</OutputSelector>
	<OutputSelector>UPC</OutputSelector>
	<OutputSelector>ItemSpecifics</OutputSelector>
  <OutputSelector>ShippingPackageDetails</OutputSelector>
  <OutputSelector>SellingStatus</OutputSelector>
  <OutputSelector>Quantity</OutputSelector>
  <OutputSelector>Site</OutputSelector>
</GetItemRequest>
END_XML

# TODO: Revise Ebay. Leaving in for now. Later we can add use this code to create a new SKU and update the listing's CustomLabel field
my $request_reviseitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<ReviseFixedPriceItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<Item>
<ItemID>__ItemID__</ItemID>
__SINGLE_SKU__
__VARIATION_SKU__
__quantityXML__
</Item>
</ReviseFixedPriceItemRequest>
END_XML


my $self = {};
$self->{objHeader} = $header;  # http header object

$self->{request_getmyebayselling_default} = $request_getmyebayselling_default;
$self->{request_getitem_default}          = $request_getitem_default;
$self->{request_reviseitem_default}       = $request_reviseitem_default;

$self->{backup_table} = 'Inventory_' . $timestamp;

###################################################
# SQL                                             #
###################################################

# SQL: Backup Inventory table
$self->{sql}->{backup_inventory_table} = "select * into $self->{backup_table} from Inventory";

# SQL: Clear the active flag before updating
$self->{sql}->{clear_active_flags} = 'update Inventory set active=0';
$self->{sql}->{clear_active_flag}  = 'update Inventory set active=0 where ebayItemId = ?';

# SQL: Insert/Update the Inventory table (when UPDATE (-u) switch is given)
# NOTE: Merge requires a semi-colon at the end (99% sure).
$self->{sql}->{merge_inventory} = <<END_SQL;
MERGE INTO Inventory t
USING (
  VALUES (?,?,?,?,?,?,?,?,?,?)
) AS s (ebayitemid, supplier, sku, title, variation, image_url, main_image_url, upc, weight, quantity)
ON 
  t.title                = s.title and
  isnull(t.variation,'') = isnull(s.variation,'')
WHEN MATCHED THEN
  UPDATE SET 
			 t.supplier         = isnull(t.supplier,s.supplier),
	     t.ebayitemid       = s.ebayitemid,
	     t.sku              = s.sku,
       t.last_modified    = getdate(),
       t.image_url        = s.image_url,
       t.main_image_url   = s.main_image_url,
			 t.upc              = isnull(t.upc,s.upc),
			 t.weight           = isnull(t.weight,s.weight),
			 t.quantity         = s.quantity,
       t.active           = 1
WHEN NOT MATCHED THEN
  INSERT (ebayitemid, supplier, sku, title, variation, last_modified, image_url, main_image_url, active, upc, weight, quantity)
  VALUES (s.ebayitemid, s.supplier, s.sku, s.title, s.variation, getdate(), s.image_url, s.main_image_url, 1, s.upc, s.weight, s.quantity)
;
END_SQL

# TODO: Add SQL check to make sure we only match one record before updating, this will catch a duplicate title/variation issue 
#       Or, turn off auto-commit and check that only 1 row was updated or rollback


####################################################################################################
# MAIN PROCESSING 
####################################################################################################

$self->{dbh} =
  DBI->connect( "DBI:ODBC:$ODBC",
                'shipit2',
                'shipit2',
                { 
                  RaiseError       => 0, 
                  AutoCommit       => 1, 
                  FetchHashKeyName => 'NAME_lc',
                  LongReadLen      => 100000,
                } 
              )
  || die "\n\nDatabase connection not made: $DBI::errstr\n\n";


###################################################
# Get active items from eBay                      #
###################################################
my $pagenumber=1;
my $maxpages=999;

if ( @all_items == 0 ) {
  while ( $pagenumber <= $maxpages ) {
    $self->{request} = $self->{request_getmyebayselling_default};
    $self->{request} =~ s/__PAGE_NUMBER__/$pagenumber/;

    $self->{objHeader}->remove_header('X-EBAY-API-CALL-NAME');
    $self->{objHeader}->push_header  ('X-EBAY-API-CALL-NAME'=>'GetMyeBaySelling' );

    my $response_hash = submit_request($self);

    if ($pagenumber==1) {
      $maxpages = $response_hash->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
    }

    print "\npage $pagenumber of $maxpages";
    $pagenumber++;

    for my $i ( @{$response_hash->{ActiveList}->{ItemArray}->{Item}} ) {
      # Exclude foreign listings by currency (not perfect, some other countries could use USD)
      # But, by doing a check here, we avoid a lot of extra API calls later 
      next if ($i->{SellingStatus}->{CurrentPrice}->{currencyID} ne 'USD');

      # Skip item, if a single item ID was given (-i)
      next if ($itemId && $i->{ItemID} != $itemId);

      push(@all_items, $i->{ItemID});
    }
  }
}

print "\n\nNumber of items found on Ebay: ", scalar(@all_items), "\n\n";

###################################################
# UPDATE Inventory TABLE                          #
###################################################

if ( $UPDATE ) {
  # Make auto backup of Inventory table
  $self->{dbh}->do( $self->{sql}->{backup_inventory_table} ) or die "can't execute stmt";

  if ( @all_items ) {
    # Clear actives flag(s) only for itemId(s) provided
    my $sth = $self->{dbh}->prepare( $self->{sql}->{clear_active_flag} ) or die "can't execute stmt";
    for my $id ( @all_items ) {
      $sth->execute( $id ) or die "can't execute stmt";
    }
  }
  else {
    # Clear ALL active flag on Inventory table
    $self->{dbh}->do( $self->{sql}->{clear_active_flags} ) or die "can't execute stmt";
  }
}

# Prepare merge inventory stmt
my $sql = $self->{sql}->{merge_inventory};
my $sth = $self->{dbh}->prepare( $sql ) or die "can't prepare stmt: $sql";


####################################################################################################
# Loop over all items on Ebay
####################################################################################################
my $itemcnt=0;

for my $item_id ( uniq sort @all_items ) {

  $itemcnt++;
  print "\nListing #$itemcnt ( $item_id )";

  # Get detailed info for this item
  $self->{request} = $self->{request_getitem_default};
  $self->{request} =~ s/__ItemID__/$item_id/;           
  $self->{objHeader}->remove_header('X-EBAY-API-CALL-NAME');
  $self->{objHeader}->push_header  ('X-EBAY-API-CALL-NAME'=>'GetItem' );

  my $r = submit_request($self);
  $r = $r->{Item};

  # NOTE: IMPORTANT! Only sync listing on US Site to the database. 
  #       Otherwise there will be duplicates by SKU (CustomLabel)
  if ( ! defined($r->{Site}) ) {
    die "\nERROR: Can't determine Site (US, UK, AU, etc...) on which item is listed!)";
  }
  next if ( $r->{Site} ne "US" );

  my $title = $r->{Title};

  # Warn about titles with leaving or trailing spaces
  if ( $title =~ /^\s+.+$/ ) {
    print "\nWARNING: Title has a leading space:  '$title'";
  } elsif ( $title =~ /^.+?\s+$/ ) {
    print "\nWARNING: Title has a trailing space:  '$title'";
  } 

  my $extimage = ref($r->{PictureDetails}->{ExternalPictureURL}) eq 'ARRAY'
                  ? $r->{PictureDetails}->{ExternalPictureURL}->[0]
                  : $r->{PictureDetails}->{ExternalPictureURL};
  my $intimage = ref($r->{PictureDetails}->{PictureURL}) eq 'ARRAY'
                  ? $r->{PictureDetails}->{PictureURL}->[0]
                  : $r->{PictureDetails}->{PictureURL};

  my $image_url_main;
  eval {
    $image_url_main = $extimage ? $extimage : $intimage ? $intimage : $r->{PictureDetails}->{GalleryURL};
  };
  if ($@) {
    print "\nERROR: item $item_id - Gallery pic: '$r->{PictureDetails}'";
    next;
  }

  my $lbs = $r->{ShippingPackageDetails}->{WeightMajor}->{content};
  my $ozs = $r->{ShippingPackageDetails}->{WeightMinor}->{content};
  my $weight_oz = ($lbs*16) + $ozs;

  my $brand = get_Brand($r->{ItemSpecifics}); # i.e. Supplier

  if ( defined $r->{Variations} ) {
    ################################################################################ 
    # VARIATIONS
    ################################################################################ 
    my $variations={};
    my $gross_qty;
    my $sold_qty;

    for my $v ( @{$r->{Variations}->{Variation}} ) {
      my $var;

      if ( ref($v->{VariationSpecifics}->{NameValueList} ) eq 'ARRAY' ) {
        $var = $v->{VariationSpecifics}->{NameValueList}->[0]->{Value};
      }
      else {
          $var = $v->{VariationSpecifics}->{NameValueList}->{Value};
      }

      $variations->{$var}->{SKU} = $v->{SKU};
      $variations->{$var}->{IMG} = $image_url_main;   # default image (may be replaced below)
      $variations->{$var}->{UPC} = defined $v->{VariationProductListingDetails}->{UPC}
                                   ?  $v->{VariationProductListingDetails}->{UPC}
                                   : '';

      # Calulate quantity available
      $gross_qty = $v->{Quantity} ? $v->{Quantity} : 0;
      $sold_qty  = $v->{SellingStatus}->{QuantitySold} ? $v->{SellingStatus}->{QuantitySold} : 0;
      $variations->{$var}->{QTY} = $gross_qty - $sold_qty;
    }         

    # Get variation specific images (if they exist, replaces default image)
    if ( defined $r->{Variations}->{Pictures}->{VariationSpecificPictureSet} ) {
      for my $v ( @{$r->{Variations}->{Pictures}->{VariationSpecificPictureSet}} ) {
        my $var       = $v->{VariationSpecificValue};
        my $extimage  = ref( $v->{ExternalPictureURL} ) eq 'ARRAY'  
                        ? $v->{ExternalPictureURL}->[0]
                        : $v->{ExternalPictureURL};
        my $intimage  = ref( $v->{PictureURL} ) eq 'ARRAY'
                        ? $v->{PictureURL}->[0]
                        : $v->{PictureURL};

        my $image_url = $extimage || $intimage || $image_url_main;
        
        $variations->{$var}->{IMG} = $image_url;
      }
    }

    # Update Inventory table
    for my $variation ( keys %$variations ) {
      my $sku       = $variations->{$variation}->{SKU};
      my $image_url = $variations->{$variation}->{IMG};
      my $upc       = $variations->{$variation}->{UPC};
      my $avail_qty = $variations->{$variation}->{QTY};

      if ( $UPDATE ) {
        $sth->execute($item_id, $brand, $sku, $title, $variation, $image_url, $image_url_main,$upc,$weight_oz,$avail_qty) or die "can't execute query: $sql";
      }

      if ( $outfile ) {
        $csv->print($ofh, [$item_id, $brand, $sku, $title, $variation, $image_url, $image_url_main,$upc,$weight_oz,$avail_qty]);
      }

    }
  }
  else {
    ################################################################################ 
    # NON-VARIATION LISTING
    ################################################################################ 
    my $variation = '';
    my $image_url = $image_url_main;
    my $sku       = $r->{SKU};
    my $upc       = get_UPC($r->{ItemSpecifics});

    # Get Quantity
    my $gross_qty = $r->{Quantity} ? $r->{Quantity} : 0;
    my $sold_qty  = $r->{SellingStatus}->{QuantitySold} ? $r->{SellingStatus}->{QuantitySold} : 0;
    my $avail_qty = $gross_qty - $sold_qty;

    if ( $UPDATE ) {
      $sth->execute($item_id, $brand, $sku, $title, $variation, $image_url, $image_url_main,$upc,$weight_oz,$avail_qty) or die "can't execute query: $sql";
    }

    if ( $outfile ) {
      $csv->print($ofh, [$item_id, $brand, $sku, $title, $variation, $image_url, $image_url_main,$upc,$weight_oz,$avail_qty]);
    }
  }

} # End for @all_items loop



####################################################################################################
# Update Ebay
####################################################################################################
# TODO: Leaving in for now, just in case we want to update ebay with SKU value
#       Obviously this will change drastically to only update SKU
if ( $UPDATE_EBAY ) {

  my $request  = $self->{request_reviseitem_default};
  my $ItemID   = $self->{tc_item_id}->GetValue();
  my $SKU      = $self->{tc_product_sku}->GetValue();			# UPC / manufacturer SKU
  my $TTB_SKU  = $self->{tc_ttb_sku}->GetValue();
  my $Location = $self->{tc_location}->GetValue();
	my $Weight   = $self->{tc_weight}->GetValue();
  my $Supplier = $self->{current_supplier} || ' ';
  my $addQty   = $self->{tc_quantity_add}->GetValue()    || int('0');     # can't add zero
  my $totalQty = $self->{tc_quantity_total}->GetValue()  ; #|| int('0');  # zero is valid, but may cause listing to close (warn user about this)
  my $availQty = $self->{lbl_quantity_available}->GetLabel() || int('0');
  my $Title    = $self->{current_title};
  my $Variation= $self->{current_variation};
  my $VarSpecs = {};
 
  # Validate values
  if ( ! $ItemID )                                  { $self->warning_dialog("ItemID not defined!");                  return 1; }
  if ( ! $SKU or $SKU =~ /.*scan.*sku.*/i )         { $self->warning_dialog("Product SKU not defined!");             return 1; }
  if ( $SKU =~ /^\d+$/ && $SKU !~ /^\d{12,14}$/ )   { $self->warning_dialog("Product SKU is not 12 to 14 digits!");  return 1; }
  if ( ! $Title )                                   { $self->warning_dialog("Title not defined!");                   return 1; }
  if ( $addQty !~ /^\d*$/ || $totalQty !~ /^\d*$/ ) { $self->warning_dialog("quantity fields must be numeric");      return 1; }
  if ( $addQty && $totalQty )                       { $self->warning_dialog("You can not set both quantity fields"); return 1; }

  if ( $Location =~ /^(\d)(\w)(\d)$/ ) {
		$Location = uc("$1-$2-$3");
	}

	# Subtitute current values in the request xml
  $request =~ s/__ItemID__/$ItemID/;

	if ( $addQty ) {	# assumes totalQty not set (validation above should prevent that)
		$totalQty = $availQty + $addQty;
  }

  if ( $Variation ) {
    my $spec = $self->{current_variation_specifics};
    delete $spec->{SKU};
    $VarSpecs->{Variations}->{Variation} = $spec;

    $VarSpecs->{Variations}->{Variation}->{Quantity} = $totalQty
      if ( $totalQty ne '');

    $VarSpecs->{Variations}->{Variation}->{VariationProductListingDetails}->{UPC} = $SKU;

		my $VarSpecsXML = XMLout($VarSpecs, NoAttr=>1, RootName=>undef, KeyAttr=>{});

#    NOTE: skipping SKU update on eBay, we want to be careful about this when we turn on LinnWorks inventory tracking!
    $request =~ s/__VARIATION_SKU__/$VarSpecsXML/;

    $request =~ s/__SINGLE_SKU__//;                   # remove single SKU place holder from XML    
    $request =~ s/__quantityXML__//;                  # remove quantity place holder from XML
  }
  else {
#    NOTE: skipping SKU update on eBay, we want to be careful about this when we turn on LinnWorks inventory tracking!

		# get Item Specifics XML
		my $is_xml='';
		if ( defined $self->{is_map}->{$ItemID} ) {
		  $is_xml = get_item_specifics_xml( $self->{is_map}->{$ItemID}, $SKU );
		}

    $request =~ s/__VARIATION_SKU__//;       # remove variation SKU place holder from XML
    $request =~ s#__SINGLE_SKU__#$is_xml#;   # NOTE: SKU here is UPC (manufacturer SKU), not TTB SKU.

    # add quantity
    if ( $totalQty ) {
      $request =~ s#__quantityXML__#<Quantity>$totalQty</Quantity>#; 
    }
    else {
      $request =~ s/__quantityXML__//; # remove the place holder from the XML
    }
  }

  $self->{request} = $request;
  $self->{objHeader}->remove_header('X-EBAY-API-CALL-NAME');
  $self->{objHeader}->push_header  ('X-EBAY-API-CALL-NAME'=>'ReviseItem' );

  my $verification_ok;
  my $i = $self->{item_lookup_table}->{ $Title };

  my $data =<<DATA;
Title     : $Title
Variation : $Variation
SKU       : $SKU
Weight    : $Weight
Supplier  : $Supplier
Location  : $Location

DATA

  # Submit Revise Item request
  $self->submit_request();

} # end UPDATE_EBAY


exit 0;



####################################################################################################
#
# SUBROUTINES
#
####################################################################################################


####################################################################################################
# Submit Request
####################################################################################################
sub submit_request {
  my $self = shift;

  my ($objRequest, $objUserAgent, $objResponse);
  my $request_sent_attempts = 0;

  RESEND_REQUEST:
  $request_sent_attempts++;

  # Create UserAgent and Request objects
  $objUserAgent = LWP::UserAgent->new;
  $objRequest   = HTTP::Request->new(
    "POST",
    "https://api.ebay.com/ws/api.dll",
    $self->{objHeader},
    $self->{request}
  );

  # Submit Request
  $objResponse = $objUserAgent->request($objRequest);		# SEND REQUEST

  # Parse Response object to get Acknowledgement 
  my $response_hash = XMLin( $objResponse->content,ForceArray=>['Variation','NameValueList','VariationSpecificPictureSet'] );
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
  }

} # end submit_request()


################################################################################
# Get UPC from Item Specifics
################################################################################
sub get_UPC {
	my $is = shift;   # item->{ItemSpecifics}

	# Search Item Specifics for UPC
	for my $s ( @{$is->{NameValueList}} ) {
		next unless ( $s->{Name} eq 'UPC' );
		return $s->{Value}; # found UPC
	}

  return ''; # did not find UPC
}

################################################################################
# Get Brand from Item Specifics
################################################################################
sub get_Brand {
	my $is = shift;   # item->{ItemSpecifics}

	# Search Item Specifics for Brand
	for my $s ( @{$is->{NameValueList}} ) {
		next unless ( $s->{Name} =~ /^brand$/i );
		return $s->{Value}; # found Brand
	}

  return ''; # did not find Brand
}

#TODO: not sure if this is needed
################################################################################
# GET ITEM SPECIFICS XML
################################################################################
sub get_item_specifics_xml {
	my $is  = shift;   # item->{ItemSpecifics}
	my $upc = shift;
	my $xml = '';

	# build hash of 
	my $ish;
	$ish->{ItemSpecifics}->{NameValueList} = [];
	for my $s ( @{$is->{NameValueList}} ) {
		push($ish->{ItemSpecifics}->{NameValueList}, { Name=>$s->{Name}, Value=>$s->{Value} } );
	}

	# overwrites UPC item specific, if it existed
  push($ish->{ItemSpecifics}->{NameValueList}, { Name=>'UPC', Value=>$upc } )
	  if ($upc);

  $xml = XMLout($ish, NoAttr=>1, RootName=>undef, KeyAttr=>{})
	  if ( $is or $upc );

	return $xml;
}


################################################################################
# GET NEXT SKU
################################################################################
# TODO: Currently not used, but might add this ability back in, so leaving the code here (same logic as AppendMissingSKUs.pl)
sub get_next_sku() {

  my $dbh = $self->{dbh};

  # Get next sku value
  my ($prefix,$sequence) = $dbh->selectrow_array('select sku_prefix, sku_nextval from dbo.ttb_next_sku');

  # update dbo.ttb_next_sku
  $dbh->do('update dbo.ttb_next_sku set sku_nextval = sku_nextval+1');

  $sequence = sprintf("%07s",$sequence);

  return $prefix . $sequence;
}



