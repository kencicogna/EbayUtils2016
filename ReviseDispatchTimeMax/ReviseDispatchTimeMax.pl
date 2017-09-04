#!/usr/bin/perl -w 
# generated by wxGlade 0.6.5 (standalone edition) on Fri Nov 30 13:55:30 2012
# To get wxPerl visit http://wxPerl.sourceforge.net/

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
getopts('i:raDm:d:',\%opts);

# -a    => All items processing
# -i    => Item id of single itme to processing
# -r    => Revise item(s) on ebay
# -m    => Max number of items to process (debugging. use with -a)
# -D    => Debug mode 
# -d    => DispatchDaysMax

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

(! defined $opts{d}) && die "must supply -d <days>";
($opts{d} < 0 || $opts{d} > 20) && die "must supply -d <0-20 days>";

my $max_items           = defined $opts{m} ? $opts{m} : 0;
my $REVISE_ITEM         = defined $opts{r} ? 1 : 0;
my $DEBUG               = defined $opts{D} ? 1 : 0;
my $DispatchTimeMax     = $opts{d};

my $connect_string = $opts{P} ? 'DBI:ODBC:BTData_PROD_SQLEXPRESS' : 'DBI:ODBC:BTData_DEV_SQLEXPRESS';
print STDERR "\n*\n* Connection string: $connect_string\n*\n\n";

my ($request,$response_hash);

###################################################
# EBAY API INFO                                   #
###################################################

# define the HTTP header
my $header = $EbayConfig::ES_http_header;

# eBayAuthToken
my $eBayAuthToken = $EbayConfig::ES_eBayAuthToken;

# define the XML request
my $request_reviseitem_default = <<END_XML;
<?xml version='1.0' encoding='utf-8'?>
<ReviseFixedPriceItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
<RequesterCredentials>
  <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
</RequesterCredentials>
<WarningLevel>High</WarningLevel>
<Item>
  <ItemID>__ItemID__</ItemID>
__ITEM_DETAILS__
</Item>
</ReviseFixedPriceItemRequest>
END_XML

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


################################################################################
#
# Loop over each item_id from Ebay
#
################################################################################
my $item_count=0;
for my $item_id ( @all_items ) {

  my $item_details = {
    DispatchTimeMax => $DispatchTimeMax
  };

  my $item_details_xml = XMLout($item_details, NoAttr=>1, RootName=>'', KeyAttr=>{});

  # Initialize request headers
  $header->remove_header('X-EBAY-API-CALL-NAME');
  $header->push_header('X-EBAY-API-CALL-NAME' => 'ReviseFixedPriceItem');

  # Initialize request
  my $request = $request_reviseitem_default;
  $request =~ s/__ItemID__/$item_id/;
  $request =~ s/__ITEM_DETAILS__/$item_details_xml/;

  # Debug the XML before revising item
	if ( $DEBUG ) { 
		print "\n\nItem Details:\n",Dumper($item_details);
		print "\n\nItem Details XML:\n",Dumper($item_details_xml);
    print "\n\nREQUEST:",Dumper($request);
	}

	#
	# REVISE ITEM
	#
	if ( $REVISE_ITEM ) {
    eval {
      my $r = submit_request( $request, $header, 1 ); # return error object if the request fails
      if ( $r->{LongMessage} ) {
        my $error = $r->{LongMessage};
        print qq/\n$item_id,"$error"\n/;
        next;
      }
    };
    if ( $@ ) {
        print qq/$item_id,"ERROR: Submit ReviseFixedPriceItem failed. $@"\n/;
        next;
    }
	}

  # Debugging
	if ( $max_items and $item_count >= $max_items ) {
		print "\nMax Items  : $max_items";
		print "\nItem Count : $max_items";
		last;
	}
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
	  $response_hash = XMLin( "$content",  ForceArray=>[''] );
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

