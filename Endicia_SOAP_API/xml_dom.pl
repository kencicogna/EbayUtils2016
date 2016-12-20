use strict;
use XML::Simple;

our $outfile_ext = 'EPL2';

my $RequesterID = '2502641';
my $AccountID   = '2502641';
my $PassPhrase  = 'its only a FLESH w0und!';
my $Token = read_file('token.txt') or die;

my $MailClass      = 'First';        # ok
#my $MailClass      = 'Priority';     # ok
#my $MailClass      = 'MediaMail';    # Warning - 'M' didn't print. Could be printer driver issue.
#$my $MailClass      = 'ParcelSelect';  # error - must set 'SortType'

my $MailpieceShape = 'Parcel';  # could be flat ( large flat envelop? ) or letter ( for stickers; change printer or label size (maybe print half label) )
my $isConsolidatorLabel = 0;    # 1 - international IPA or ePacket
my $DateAdvance    = 0; 
my $WeightOz       = 3;
my $value          = 19.99;

my $xml_main = qq/\n<LabelRequest Test="YES" LabelSize="4x6" ImageFormat="$outfile_ext" >/;

my $xml = {};
$xml->{PrintConsolidatorLabel} = "TRUE"         if $isConsolidatorLabel;
$xml->{PartnerTransactionID} = "1";
$xml->{RequesterID} = "$RequesterID";
$xml->{AccountID} = "$AccountID";
$xml->{PassPhrase} = "$PassPhrase";
$xml->{Token} = "$Token";
$xml->{MailClass} = "$MailClass";               # what's the class for ePacket?
$xml->{MailpieceShape} = "$MailpieceShape";     # default=Parcel
$xml->{DateAdvance} = "$DateAdvance";
$xml->{WeightOz} = "$WeightOz";
$xml->{MailpieceDimensions}->{Length} = 6;
$xml->{MailpieceDimensions}->{Width}  = 4;
$xml->{MailpieceDimensions}->{Height} = 4;
$xml->{IncludePostage} = "FALSE";
$xml->{Stealth} = "TRUE";                       # Default but nice to be explicit here
$xml->{ValidateAddress} = "TRUE";               # Default but nice to be explicit here

$xml->{Description} = "Childs Toy";
#  $xml->{RubberStamp1} = "";

# Sender Info:
$xml->{FromName} = "The Teaching Toy Box";
$xml->{ReturnAddress1} = "415 W. Belden Avenue";
$xml->{ReturnAddress2} = "Suite J";
$xml->{FromCity} = "Addison";
$xml->{FromState} = "IL";
$xml->{FromPostalCode} = "60101";
#$xml->{FromZIP4} = "";
$xml->{FromCountry} = "US";
$xml->{FromPhone} = "7081231234";
$xml->{FromEMail} = 'theteachingtoybox@gmail.com';

# Recipient Info:
$xml->{ToName} = "Ken Cicogna";
$xml->{ToCompany} = "Blah Blah Company, LLC";
$xml->{ToAddress1} = "7 Park Road Ct.";
#$xml->{ToAddress2} = "";
#$xml->{ToAddress3} = "";
#$xml->{ToAddress4} = "";
$xml->{ToCity} = "Lombard";
$xml->{ToState} = "IL";
$xml->{ToPostalCode} = "60148";
#$xml->{ToZIP4} = "";
#$xml->{ToDeliveryPoint} = "";       # ?????
$xml->{ToCountry} = "United States"; 
$xml->{ToCountryCode} = "US";             
$xml->{ToPhone} = "1231231234";
$xml->{ToEMail} = 'ken@yahoo.com';

# Package / Customs info
$xml->{Value} = "$value";
$xml->{NonDeliveryOption} = "Return";    # Not sure if this is needed. there's one in CustomsInfo tag, but that only apply's to Intl. Maybe domestic is 'Return' by Default?           
# $xml->{EmailMiscNotes} = "";

# No Attributes
my $xmlout = XMLout( $xml, NoAttr=>1, RootName=>undef, KeyAttr=>{});

# Add tags with Attributes
my $xml2;
$xml2->{Services} = {
  # DeliveryConfirmation=>"",    # replaced by USPSTracking tag
  USPSTracking=>"ON",
  RegisteredMail=>"OFF",
};

$xml2->{ResponseOptions} = { PostagePrice=>"TRUE" };    # tells Endicia to return the ACTUAL POSTAGE PRICE in the Response Object

my $xmlout2 = XMLout( $xml2, NoAttr=>0, RootName=>undef, KeyAttr=>{});

our $xmloutput = <<END;
$xml_main
$xmlout
$xmlout2
</LabelRequest>
END

