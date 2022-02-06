package ShipItEbayAPICallGetActiveListings;

use utf8;
use strict;

use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;

use Carp;
use Cwd;
use DBI;
use XML::Simple qw(XMLin XMLout);
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

use Moose;
extends 'ShipItEbayAPICallBase';

#-------------------------------------------------------------------------------
# Attributes
#-------------------------------------------------------------------------------

has activeListings      => ( is => 'rw', isa => 'ArrayRef'          );  # Result - Order details array reference

# override parent attributes
has +callName           => ( is => 'rw', isa => 'Str', default=>'GetMyeBaySelling' );  # e.g. 'CompleteSale'
has +requestXMLTemplate => ( is => 'rw', isa => 'Str', default=>''  );  # XML call body
has +requestXML         => ( is => 'rw', isa => 'Str', default=>''  );  # XML call body


#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------

sub _setCallNameSpecificInfo {
  my $self              = shift;
  my $api_call_name     = $self->callName;
  my $api_call_name_tag = $api_call_name . 'Request';
  my $eBayAuthToken     = $self->eBayAuthToken;

  my $requestXML = <<REQUEST_XML;
      <?xml version="1.0" encoding="utf-8"?>
      <$api_call_name_tag xmlns="urn:ebay:apis:eBLBaseComponents">

      <RequesterCredentials>
        <eBayAuthToken>$eBayAuthToken</eBayAuthToken>
      </RequesterCredentials>

      <WarningLevel>High</WarningLevel>

			<ActiveList>
			  <Include>true</Include>
			  <Pagination>
			  	<EntriesPerPage>100</EntriesPerPage>
			  	<PageNumber>__PAGE_NUMBER__</PageNumber>
			  </Pagination>
			</ActiveList>

			<OutputSelector>TotalNumberOfPages</OutputSelector>
			<OutputSelector>ItemID</OutputSelector>
			<OutputSelector>Title</OutputSelector>
			<OutputSelector>SKU</OutputSelector>
			<OutputSelector>VariationTitle</OutputSelector>
			<OutputSelector>SellingStatus</OutputSelector>

      </$api_call_name_tag>
REQUEST_XML

  $self->requestXMLTemplate( $requestXML );

	# XML Output field rules
	$self->XMLinForceArray( ['InternationalShippingServiceOption','ShippingServiceOptions','ShipToLocation','Variation', 
			                     'NameValueList','Order','Transaction','VariationSpecificPictureSet','PictureURL' ] );
}


sub sendRequest {
  my $self = shift;

  $self->_setCallNameSpecificInfo;  # sets request xml

  ################################################################################
  # Get list of Active Listings 
  ################################################################################
  my $all_items = [];
  my $pagenumber=1;
  my $maxpages;  

  print STDERR "\nFetching Active Listings...\n";

	do 
	{
		# Set page number desired
    $self->{requestXML} = $self->requestXMLTemplate;
    $self->{requestXML} =~ s/__PAGE_NUMBER__/$pagenumber/g;

		# Make API call
    my $response = $self->submitXMLPostRequest();

		# Pagination - we have to handle it here since the TotalNumerOfPages tag can be in different places
    if ( $pagenumber==1 ) {
      die if ( ! defined $response->{ActiveList}->{PaginationResult}->{TotalNumberOfPages} );
      $maxpages = $response->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
    }

		# get items from this page of results 
    for my $item  ( @{$response->{ActiveList}->{ItemArray}->{Item}} ) {

			# Ignore listings on foreign sites 
			# TODO: This is not perfect, ideally we need to call getItem API to get the actual Site, unfortunately this API does not return it.
			next if ( defined $item->{SellingStatus}->{ConvertedCurrentPrice} );

      push( @$all_items, $item );
    }

    print STDERR "\nActive Listing Page: $pagenumber / $maxpages";

    $pagenumber++;

		# TODO: testing - remove this line
		#$pagenumber = 100;
  }
  while ( $pagenumber <= $maxpages );

  $self->activeListings( $all_items );

	#	print "\n\n",Dumper($self->activeListings);
	# my $cnt = @{ $self->activeListings };
	# print "\n\n-- cnt=$cnt -------------------------------------\n\n";
	# exit;

} # end sendRequest




1;
