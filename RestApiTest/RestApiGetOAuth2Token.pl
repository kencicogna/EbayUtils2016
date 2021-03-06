#!/usr/bin/perl -w 
# generated by wxGlade 0.6.5 (standalone edition) on Fri Nov 30 13:55:30 2012
# To get wxPerl visit http://wxPerl.sourceforge.net/

# Change log
# 2016/03/12 added to git

use strict;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request;
use HTTP::Headers;
use HTML::Restrict;
use HTML::Entities;
use MIME::Base64;
use Date::Calc 'Today';
use Data::Dumper 'Dumper';			
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse = 0;
$Data::Dumper::Indent = 1;
use POSIX;
use Getopt::Std;
use Storable 'dclone';

use lib '../cfg';
use EbayConfig;
use JSON;
use URI::Encode qw(uri_encode uri_decode);

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

my $REVISE_ITEM = defined $opts{r} ? 1 : 0;
my $DEBUG       = defined $opts{D} ? 1 : 0;
my $infile      = defined $opts{I} ? $opts{I} : '';
my $outfile     = defined $opts{O} ? $opts{O} : 'dump';
my $ReturnAll   = defined $opts{A} ? 1 : 0;

print "\n\nGetting User Access token......\n\n";


###################################################
# EBAY API INFO                                   #
###################################################
my $devid = $EbayConfig::ES_DevID;
my $appid = $EbayConfig::ES_AppID;   # client ID
my $certid = $EbayConfig::ES_CertID;  # client's secret key
my $authenticationCodeHTMLEncoded = $EbayConfig::ES_OAuthAuthenticationCode;
my $authenticationCode = uri_decode($authenticationCodeHTMLEncoded);
my $credentials = MIME::Base64::encode_base64("$appid:$certid");
chomp($credentials);

my $userAgent = LWP::UserAgent->new;
my $httpHeaders = HTTP::Headers->new;
$httpHeaders->push_header('Content-Type'  => 'application/x-www-form-urlencoded');
$httpHeaders->push_header('Authorization' => "Basic $credentials");


################################################################################
# MAIN
################################################################################

# eBay OAuth2 Token (expires in 5 minutes)
#  ...not sure whwere i got this. User Access token is good for 2 hours (7200 seconds)

my $userAccessToken = GetUserAccessToken( $authenticationCodeHTMLEncoded );

print "\n\nUSER ACCESS TOKEN: '$userAccessToken' \n\n";


exit;

####################################################################################################

# Getting a User Access token using the auth code
sub GetUserAccessToken {
  my $authCode = shift;
  my ($endpoint, $request, $requestBody, $response);

  $endpoint = 'https://api.ebay.com/identity/v1/oauth2/token';
  $requestBody = 
      join( '&', 
            (
              'grant_type=authorization_code',
	      'code='.$authCode,
	      'redirect_uri='.'Ken_Cicogna-KenCicog-a670-4-xcadx'
            )
          );

  $request = HTTP::Request->new(
    "POST",
    $endpoint,
    $httpHeaders,
    $requestBody
  );

  #print "\n httpHeaders : ",Dumper($httpHeaders);
  #print "\n requestBody : ",Dumper($requestBody);
  print "\n Request     : ",Dumper($request); exit;

  # Submit Request
  $response = $userAgent->request($request);		# SEND REQUEST
  print Dumper($response);

  return $response->content;
}


sub getOAuth2Code {
  my ($endpoint, $request, $requestBody, $response);

  # TODO: don't need to get auth every time... Also, don't need to get access token, use "refresh token"

  #
  # Getting an authorization code / Getting third-party permissions
  #
  $endpoint = 'https://signin.ebay.com/authorize?client_id=KenCicog-a670-43d6-ae0e-508a227f6008&response_type=code&redirect_uri=Ken_Cicogna-KenCicog-a670-4-xcadx&scope=https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.marketing https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.account https://api.ebay.com/oauth/api_scope/sell.fulfillment';

  $endpoint = encode_entities($endpoint);
  $requestBody = '';

  $request = HTTP::Request->new(
    "GET",
    $endpoint,
    $httpHeaders,
    $requestBody
  );

  # Send Request
  $response = $userAgent->request($request);

  if ( $response->content ) {
    open my $ofh, '>', 'auth.html';
    print $ofh $response->content;
    close $ofh;
  }

  print Dumper($response);
  exit;


  #
  # Getting a User access token using the auth code
  #
  $endpoint = 'https://api.ebay.com/identity/v1/oauth2/token';
  $requestBody = 
      join( '&', 
            (
              'grant_type='.$appid,
              '&redirect_uri=',
              '&scope=https://api.ebay.com/oauth/api_scope/sell.fulfillment'
            )
          );

  $request = HTTP::Request->new(
    "POST",
    $endpoint,
    $httpHeaders,
    $requestBody
  );

	print "\n httpHeaders : ",Dumper($httpHeaders);
	print "\n requestBody : ",Dumper($requestBody);
	print "\n Request     : ",Dumper($request);

  # Submit Request
  $response = $userAgent->request($request);		# SEND REQUEST
  print Dumper($response);

}

