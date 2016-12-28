#!/usr/bin/perl -w -- 

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
use List::MoreUtils qw/ uniq /;

my %opts;
getopts('i:D',\%opts);

die "\n\nMust supply -i <infile>" unless $opts{i};

my $DEBUG = $opts{D} ? 1: 0;
my $infile = $opts{i};

###################################################
# EBAY API INFO                                   #
###################################################

# define the HTTP header
my $objHeader = HTTP::Headers->new;
$objHeader->push_header('X-EBAY-API-COMPATIBILITY-LEVEL' => '899');
$objHeader->push_header('X-EBAY-API-DEV-NAME'  => 'd57759d2-efb7-481d-9e76-c6fa263405ea');
$objHeader->push_header('X-EBAY-API-APP-NAME'  => 'KenCicog-a670-43d6-ae0e-508a227f6008');
$objHeader->push_header('X-EBAY-API-CERT-NAME' => '8fa915b9-d806-45ef-ad4b-0fe22166b61e');
$objHeader->push_header('X-EBAY-API-CALL-NAME' => 'ReviseFixedPriceItem');
$objHeader->push_header('X-EBAY-API-SITEID'    => '0'); # usa
$objHeader->push_header('Content-Type'         => 'text/xml');

# eBayAuthToken
my $eBayAuthToken = 'AgAAAA**AQAAAA**aAAAAA**CQTJVA**nY+sHZ2PrBmdj6wVnY+sEZ2PrA2dj6wHlIKoCZCBogmdj6x9nY+seQ**4EwAAA**AAMAAA**IjIgU4Mg/eixJ7OQDRd60pU4NWyjtHgmki3+78wP5Vdt8qXeUz9lAbiDgkWaTbHHxBS2J+GvPSZZ9c+24CHqWIxORvV0OK1M176YGUAUPY7YXq8Z2XSTUp+pmq7In/SjzNc17Aqg+CUZsYDn1mnyoRGyW3rT5uk6TtCStBcckV1q55Jg0JomVxUtC68NPC+4JDCqOEqHVOok7pTR8dNa7wTZiSZCoKodX7c8wnBStPkGHhw3G3ogeU0FmKudl1IMsV1zUlJ0E5dCq9GF/2wxgQQAdH29RXcVUHKDE5zAXSmUIvrmIRKG2xDOnxUSjsRMQJZ8dN/wEKXtjQK4NYCBqwmqo+7uMsUwbqjF6X320t/eksCLbG8tL+QtLN9PwrpbAUnnMHnn/LI+sEb1BaFHBI0O9eqYKJII/bVaYwFNilqq4qe1wR+qF2Ge9Fa6jYvdKMwhVvYZmily6mIDhJEX4VUQ3B9wx6tx6Bnm49/2LNblVY+toRI+rqdMnjVAQTXPeWzxmUqSK4Ql0Jn7pm0ul7v9Zt9/LYNRpjId7NoEC//q/5rvBxGIBSLe3KzrSR2r/Xuu9IMfrJbq3bvoMBpgr5Iy7+K2vXPmfXkQ3VuXocoAJIvuZTrSLIY6DSqfdc5oxk0RObGcShP+grojI1FpWGULDDYM5Uxlbj3FNSGc7X/U2MslXt0dZ5Ao0dtf4oz63oEHQV1sfEToouUEhML7Sz9exfEfZy35LqR6RuTOXDyTG1gFweFCkK6F54eZgdLZ';


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
    <Storefront>
      <StoreCategoryID>__StoreCategoryID1__</StoreCategoryID>
      __StoreCategoryID2__
    </Storefront>
</Item>
</ReviseFixedPriceItemRequest>
END_XML

# Sample categories
#  'Games -> Travel'      => '4804260015',
#  'Keychains'            => '4892022015',
#  'Kids in the Kitchen'  => '6135675015',
#  'Manipulatives'        => '21230776',
#  'Medical / Allergy ID' => '5526339015',
#  'Music'                => '2577028015',
#  'Novelty Toys -> Bacon'=> '4581613015',

# Sample Ebay item: 
#   title              : (1) Bendy Man Smiley Bendable Fidget Stress Relief Toy Occupational Therapy ASD
#   item ID            : 371230749640
#   primary category   : 17978938 ( fidget & sensory -> tactile )
#   secondary category : 17838314 ( occupational therapy -> occ ther )
#   UPC                : 085761127562
#   domestic shipping  : free
#   intl shipping      : 2.99 + 1.50

#   title              : Batman Bendable Flexible Action Figure Comics Justice League Gray Suit
#   item ID            : 281397589490
#   primary category   : 17860381 ( pretend play -> pretend play )
#   secondary category : n/a
#   UPC                : 85761189133
#   domestic shipping  : free
#   intl shipping      : 5.99 + 2.50


###########################################################
# END EBAY API INFO                                       #
###########################################################

# Load ebay item_id / new categories file
open my $fh, '<', $infile;
my @all_lines = <$fh>;
close $fh;

# Loop over each ebay item_id / new categories
for my $line ( @all_lines ) {

  chomp($line);
  my  ($item_id, $cat1, $cat2) = split(/,/,$line);

  my $request = $request_reviseitem_default;

  # Update request with store categories
  $request =~ s/__ItemID__/$item_id/;           
  $request =~ s/__StoreCategoryID1__/$cat1/;           
  if ( $cat2 ) {
    $request =~ s#__StoreCategoryID2__#<StoreCategory2ID>$cat2</StoreCategory2ID>#;           
  }
  else {
    $request =~ s#__StoreCategoryID2__##;
  }

  print Dumper($request) if $DEBUG;

  my $self;
  $self->{objHeader} = $objHeader;
  $self->{request} = $request;

  my $r = submit_request($self);

  print Dumper($r) if $DEBUG;

}


exit;




####################################################################################################
sub submit_request {
  my $self = shift;

	################################################################################
  # Update Ebay
	################################################################################
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
  my $response_hash = XMLin( $objResponse->content,ForceArray=>['Variation'] );
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

