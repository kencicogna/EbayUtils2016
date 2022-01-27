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

has activelistings      => ( is => 'rw', isa => 'ArrayRef'          );  # Result - Order details array reference

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
    my $responseObj = $self->submitXMLPostRequest();

		# Pagination - we have to handle it here since the TotalNumerOfPages tag can be in different places
    if ( $pagenumber==1 ) {
      die if ( ! defined $responseObj->{ActiveList}->{PaginationResult}->{TotalNumberOfPages} );
      $maxpages = $responseObj->{ActiveList}->{PaginationResult}->{TotalNumberOfPages};
    }

		# get items from this page of results 
    for my $item  ( @{$responseObj->{ActiveList}->{ItemArray}->{Item}} ) {
      push( @$all_items, $item );
    }

    print STDERR "\nActive Listing Page: $pagenumber / $maxpages";

    $pagenumber++;
  }
  while ( $pagenumber <= $maxpages );

  $self->activeListings( $all_items );

} # end sendRequest




1;
