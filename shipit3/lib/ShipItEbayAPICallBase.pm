package ShipItEbayAPICallBase;

use strict;
use Moose;

use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;

use Cwd;
use DBI;
use XML::Simple qw(XMLin XMLout);
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;


#-------------------------------------------------------------------------------
# Attributes
#-------------------------------------------------------------------------------

has environment         => ( is => 'ro', isa => 'Str', default=>'', trigger => \&_setHeaderValues, required=>1 );  # e.g. 'production' or anything else. Determines which ebay API endpoint is used.
has apiURL              => ( is => 'rw', isa => 'Str', default=>''    );  # Set when environment is set
has httpHeaders				  => ( is => 'rw', isa => 'Object'              );  # HTTP::Headers object
has XMLinForceArray     => ( is => 'rw', isa => 'ArrayRef'            );  # list of tags that should be returned as an array reference, even if there is only 1 element (normally returned as a simple value)

# API Call info
has devName             => ( is => 'rw', isa => 'Str', default=>''   );  # e.g. 'd57759d2-efb7-481d-9e76-c6fa263405ea'
has appName             => ( is => 'rw', isa => 'Str', default=>''   );  # e.g. 'KenCicog-a670-43d6-ae0e-508a227f6008'
has certName            => ( is => 'rw', isa => 'Str', default=>''   );  # e.g. '8fa915b9-d806-45ef-ad4b-0fe22166b61e'
has siteID              => ( is => 'rw', isa => 'Num', default=>0    );  # e.g. 0 (0 = USA)
has compatibilityLevel  => ( is => 'rw', isa => 'Int', default=>1235 );  # e.g. '899'
has apiDetailLevel      => ( is => 'rw', isa => 'Int', default=>0    );  # e.g. 0 ( )
has contentType         => ( is => 'rw', isa => 'Str', default=>''   );  # e.g. 'text/xml'
has eBayAuthToken       => ( is => 'rw', isa => 'Str', default=>''   );  # String or reads token from file (if file name is passed)

# Must Override
has callName            => ( is => 'rw', isa => 'Str', default=>''   );  # e.g. 'CompleteSale'
has requestXML          => ( is => 'rw', isa => 'Str', default=>''   );  # XML (request body)

#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------

sub _setHeaderValues() {
  # Set all the header values based on the environment selected
  my ($self,$environment) = @_;

  if ( $environment =~ /production/i ) {
    # PRODUCTION
    $self->apiURL            ( 'https://api.ebay.com/ws/api.dll'      );
    $self->devName           ( 'd57759d2-efb7-481d-9e76-c6fa263405ea' );
    $self->appName           ( 'KenCicog-a670-43d6-ae0e-508a227f6008' );
    $self->certName          ( '8fa915b9-d806-45ef-ad4b-0fe22166b61e' );
    $self->siteID            ( 0           );
    $self->compatibilityLevel( '1235'      ); # as of 1/20/2022
    $self->apiDetailLevel    ( 0           );
    $self->contentType       ( 'text/xml'  );

    $self->_setTokenFromFile ( 'cfg/ebay_api_production_token.txt' );
  }
  else {
    # DEVELOPMENT
    $self->apiURL            ( 'https://api.sandbox.ebay.com/ws/api.dll' );
    $self->devName           ( 'd57759d2-efb7-481d-9e76-c6fa263405ea'    );
    $self->appName           ( 'KenCicog-8d14-43e3-871a-5ff9825f4ca1'    );
    $self->certName          ( '288c8c46-75a9-46bb-a08e-80ca5305efd1'    );
    $self->siteID            ( 0          );
    $self->compatibilityLevel( '1235'      ); # as of 1/20/2022
    $self->apiDetailLevel    ( 0           );
    $self->contentType       ( 'text/xml' );

    $self->_setTokenFromFile ( 'cfg/ebay_api_development_token.txt' );
  }

  # define the HTTP header
  my $objHeader = HTTP::Headers->new;
  $objHeader->push_header('X-EBAY-API-CALL-NAME'           => $self->callName);
  $objHeader->push_header('X-EBAY-API-DEV-NAME'            => $self->devName );
  $objHeader->push_header('X-EBAY-API-APP-NAME'            => $self->appName );
  $objHeader->push_header('X-EBAY-API-CERT-NAME'           => $self->certName);
  $objHeader->push_header('X-EBAY-API-SITEID'              => $self->siteID  );
  $objHeader->push_header('X-EBAY-API-COMPATIBILITY-LEVEL' => $self->compatibilityLevel);
  $objHeader->push_header('X-EBAY-API-DETAIL-LEVEL'        => $self->apiDetailLevel );
  $objHeader->push_header('Content-Type'                   => $self->contentType);

	$self->httpHeaders($objHeader);

}


# 
# a.k.a. submit_request()
#
sub submitXMLPostRequest {
  my $self = shift;
  my $objUserAgent = LWP::UserAgent->new;
  $objUserAgent->timeout(300);

	# Request Object
  my $objRequest = HTTP::Request->new( 'POST', $self->apiURL, $self->httpHeaders, $self->requestXML);
	#print Dumper($objRequest); exit;
  my $request_sent_attempts = 0;

  RESEND_REQUEST:
  $request_sent_attempts++;

  # API call
  my $objResponse = $objUserAgent->request($objRequest);
	#print Dumper($objResponse); exit;

  # Parse response object to get Acknowledgement 
  my $response_hash = XMLin( $objResponse->content, ForceArray=>$self->XMLinForceArray );
  my $ack = $response_hash->{Ack};
  print "Response status : $ack\n";

  if ($objResponse->is_error || $ack !~ /success/i ) {
    print "Response msg.   : ", Dumper( $response_hash->{Errors} );
    print "Status          : ERROR: API call unsuccessful.";
    print $objResponse->error_as_HTML;

    # Resend update request
    if ( $request_sent_attempts < 3 ) {
      print "Attempting to resend update request.\n";
      goto RESEND_REQUEST;
    }

    die "Status          : API Call Failed.";
  }

	return $response_hash;

} # end sendRequest()


sub _setTokenFromFile {
  # Set eBayAuthToken field based on file contents
  use File::Slurp;
  my ($self,$string) = @_;

  if ( -f $string ) {
    my $eBayAuthToken = read_file( $string ) or die "can't read token file: '$string'";
    $eBayAuthToken =~ s/^\s+//;
    $eBayAuthToken =~ s/\s+$//;
    $self->eBayAuthToken($eBayAuthToken);
  } 
  else {
    $self->eBayAuthToken($string);
  }
}



1;
