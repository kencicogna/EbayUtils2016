use strict;
use XML::Simple;
use File::Slurp;

our $outfile_ext = 'EPL2';

my $RequesterID = '2502641';
my $AccountID   = '2502641';
my $PassPhrase  = 'its only a FLESH w0und!';
my $Token = read_file('token.txt') or die;

#my $MailClass      = 'CommercialePacket';
#my $MailClass      = 'FirstClassMailInternational';
my $MailClass      = 'IPA';
#my $MailClass      = 'PriorityMailInternational';
my $MailpieceShape = 'Parcel';  # could be flat ( large flat envelop? ) or letter ( for stickers; change printer or label size (maybe print half label) )
my $DateAdvance    = 0; 
my $WeightOz       = 3;
my $value          = 19.99;

my $isConsolidatorLabel = 1;    # 1 - international IPA or ePacket
if (  $MailClass eq 'FirstClassMailInternational' ) {
  $isConsolidatorLabel = 0;
}


# <LabelRequest tag attributes: 
#   Test=>"YES",                      # TEST Label -> No Postage
#   LabelType=>"",                    # NOTE: Gets type from MailClass
#   LabelSubtype=>"",                 # NOTE: May need this for International / consolidater?
#   LabelSize=>"4x6",                 # 4x6 Domestic / 4x6c International  (may need to also set label type/subtype to 'Integrated'
#   ImageFormat=>"PNG",               # PNG(default) for testing, but maybe need 'ZPLII' for Production to ZEBRA Printer
#   ImageResolution=>"300", 
#   ImageRotation=>"", 
#   LabelTemplate=>""

my $xml_main;

if ( $MailClass eq 'CommercialePacket' ) {
  $xml_main = qq/\n<LabelRequest Test="NO" LabelSize="4x6" ImageFormat="$outfile_ext"
                    LabelType="International" LabelSubtype="Integrated" ImageResolution="203" >/;
}
elsif ( $MailClass eq 'PriorityMailInternational' ) {
  $xml_main = qq/\n<LabelRequest Test="YES" LabelSize="4x6c" ImageFormat="$outfile_ext"
                    LabelType="International" LabelSubtype="Integrated" ImageResolution="203" >/;
}
else {
  $xml_main = qq/\n<LabelRequest Test="YES" LabelSize="4x6" ImageFormat="$outfile_ext"
                    LabelType="International" LabelSubtype="Integrated" ImageResolution="203" >/;
}

my $xml = {};
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
# PackageTypeIndicator 
      # Null     => Package Type is regular (Default).
      # Softpack => Commercial Plus Cubic price for the soft pack packaging alternative ????
$xml->{IncludePostage} = "FALSE";
$xml->{PrintConsolidatorLabel} = "TRUE"         if $isConsolidatorLabel;
#$xml->{ReplyPostage} = "";                     # set to TRUE if we want to print RETURN SHIPPING labels
#$xml->{PrintScanBasedPaymentLabel} = "";       # ALSO, I think this has to do with RETURN SHIPPING labels
$xml->{Stealth} = "TRUE";                       # Default but nice to be explicit here
$xml->{ValidateAddress} = "TRUE";               # Default but nice to be explicit here

# User defined (optional):            # or are they mandatory???
$xml->{Description} = "Childs Toy";

# INFO that could be print on the label  ( could be useful? )
#  $xml->{RubberStamp1} = "";
#  $xml->{RubberStamp2} = "";
#  $xml->{RubberStamp3} = "";

# Sender Info:
$xml->{FromName} = "The Teaching Toy Box";
#$xml->{FromCompany} = "";
$xml->{ReturnAddress1} = "415 W. Belden Avenue";
$xml->{ReturnAddress2} = "Suite J";
#$xml->{ReturnAddress3} = "";
#$xml->{ReturnAddress4} = "";
$xml->{FromCity} = "Addison";
$xml->{FromState} = "IL";
$xml->{FromPostalCode} = "60101";
#$$xml->{FromZIP4} = "";
$xml->{FromCountry} = "US";
$xml->{FromPhone} = "7081231234";
$xml->{FromEMail} = 'theteachingtoybox@gmail.com';

# Recipient Info:
$xml->{ToName} = "Ken Cicogna";
$xml->{ToCompany} = "Blah Blah Company, LLC";
$xml->{ToAddress1} = "4 Southgate";
$xml->{ToCity} = "Chichester";
$xml->{ToState} = "";
$xml->{ToPostalCode} = "PO19 8DJ";
#$xml->{ToZIP4} = "";
#$xml->{ToDeliveryPoint} = "";       # ?????
$xml->{ToCountry} = "United Kingdom"; # Is this needed????
$xml->{ToCountryCode} = "GB";             

$xml->{ToPhone} = "1231231234";
$xml->{ToEMail} = 'ken@yahoo.com';

$xml->{Value} = "$value";

if ( $MailClass eq 'PriorityMailInternational' ) {
  $xml->{IntegratedFormType} = "Form2976A"; # CP72 - 4-part customs form (used for intl priority PARCEL mail piece)
  # (below) outdated label?
  $xml->{CustomsFormType} = 'Form2976A';           # = CP72 - 4-part customs form (used for intl priority I think)
}
else {
  $xml->{IntegratedFormType} = "Form2976";  #  CN22 - required when LabelSubType='Integrated'
  # (below) outdated label?
  #$xml->{CustomsFormType} = 'Form2976';            # = CN22 - required when LabelSubType='Integrated'
}

$xml->{CustomsCertify} = "TRUE";
$xml->{CustomsSigner} = "Amy Sepelis";

$xml->{CustomsSendersCopy} = "FALSE";             # does not print page 4; senders copy of Form2976A/CP72

$xml->{CustomsInfo}->{ContentsType} = "Merchandise";
$xml->{CustomsInfo}->{ContentsExplanation} = "Childs Toy";
$xml->{CustomsInfo}->{NonDeliveryOption} = "Return";

if ( $xml->{ToCountryCode} eq 'CA' ) {
  $xml->{CustomsInfo}->{EelPfc} = "NOEEI 30.36";
}
else {
  # Rest of world 
  $xml->{CustomsInfo}->{EelPfc} = "NOEEI 30.37(a)";
}

$xml->{CustomsInfo}->{CustomsItems}->{CustomsItem} = {
  Description => 'Childs Toy',
  Quantity   => '1',
  Weight      => $WeightOz,
  Value       => $value,
  HSTariffNumber => 9000,
  CountryOfOrigin => 'US',   # currently I think it's the country we are sending it to... 
                                        # which is wrong I think, it should probably be China
};

#$xml->{CustomsInfo}->{RecipientTaxID} = "";                    # needed for Brazil?

#$xml->{ContentsExplanation} = "";
$xml->{NonDeliveryOption} = "Return";    # Not sure if this is needed. there's one in CustomsInfo tag, but that only apply's to Intl. Maybe domestic is 'Return' by Default?           

# No Attributes
my $xmlout = XMLout( $xml, NoAttr=>1, RootName=>undef, KeyAttr=>{});

# Add tags with Attributes
my $xml2;
$xml2->{Services} = {
  # DeliveryConfirmation=>"",    # replaced by USPSTracking tag
  USPSTracking=>"ON",
  RegisteredMail=>"OFF",
#  MailClassOnly=>"OFF",
# all OFF by Default:
#   CertifiedMail=>"",
#   COD=>"",
#   ElectronicReturnReceipt=>"",
#   InsuredMail=>"",
#   RestrictedDelivery=>"",
#   ReturnReceipt=>"",
#   SignatureConfirmation=>"",
#   SignatureService=>"",
#   HoldForPickup=>"",
#   MerchandiseReturnService=>"",
#   OpenAndDistribute=>"",
#   AdultSignature=>"",
#   AdultSignatureRestrictedDelivery=>"",
#   AMDelivery=>"",
};

$xml2->{ResponseOptions} = { PostagePrice=>"TRUE" };    # tells Endicia to return the ACTUAL POSTAGE PRICE in the Response Object

my $xmlout2 = XMLout( $xml2, NoAttr=>0, RootName=>undef, KeyAttr=>{});


# print $xml_main;
# print $xmlout;
# print $xmlout2;

our $xmloutput = <<END;
$xml_main
$xmlout
$xmlout2
</LabelRequest>
END


