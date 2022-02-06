package EndiciaAPICall;

use strict;
use SOAP::Lite;
#use SOAP::Lite +trace => 'all';

use MIME::Base64;
use Moose;

use Cwd;
use DBI;
use POSIX qw/strftime/;
use XML::Simple qw(XMLin XMLout);
#use XML::LibXML::PrettyPrint;
use File::Slurp 'read_file';
use File::Copy 'move';
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

#use LWP::UserAgent;
#use HTTP::Request;
#use HTTP::Headers;

# Description: Calls Endicia API to get a postage label for International E-packet and IPA mail classes
#
# METHODS:
# SetFields()  : Sets all the name address fields
#                Parameters:  Package object
#
# GetLabel()   : Makes the call to the API to get the postage label
#
# PrintLabel() : Sends the label image to the printer
#                Parameters: Optionally accepts server_IPv4_address and Printer name
#                e.g. PrintLabel('192.168.1.74','ZDesigner LP2844');
#

# IMPORTANT HELPERS:
#
#   Endicia Documentation:        http://surveygizmolibrary.s3.amazonaws.com/library/4508/Endicia_Label_Server_8_6_Final.pdf
#   Endicia Test Label Server:    https://elstestserver.endicia.com/LabelService/EwsLabelService.asmx
#   Endicia GetPostageLabel Test: https://elstestserver.endicia.com/LabelService/EwsLabelService.asmx?op=GetPostageLabelXML
#
#   Base64 decoder:  http://www.motobit.com/util/base64-decoder-encoder.asp
#   ZPL file viewer: http://labelary.com/viewer.html
#   EPL file viewer: Could not find one :(

# TODO:
#   1. add RequestID tag
#   2. calculate dimensions for epacket, max size is 24'  (LxWxH < 24 ...I think)


#-------------------------------------------------------------------------------
# Attributes
#-------------------------------------------------------------------------------

has environment         => ( is => 'rw', isa => 'Str', default=>'', trigger => \&_setHeaderValues );  # e.g. 'production' (determines which API to use)
has LabelFormat         => ( is => 'rw', isa => 'Str', default=>'ZPLII');  #  Could EPL2 or ZPLII, depending on the printer
has LabelFileExtension  => ( is => 'rw', isa => 'Str', default=>'zpl');    #  should correspond to LabelFormat 

# Actuals, returned from Endicia
has TrackingNumber      => ( is => 'rw', isa => 'Str', default=>'' );  # returned from Endicia in Response 
has ActualPostageCost   => ( is => 'rw', isa => 'Num', default=>0  );  
has APIResponse         => ( is => 'rw', isa => 'Object'           );  # Response object from API call (includes epl2 or zpl image)

# API call info
has CallName            => ( is => 'rw', isa => 'Str', default=>'GetPostageLabel' );  # Default API call
has Uri                 => ( is => 'rw', isa => 'Str', default=>'' );  # See Endicia documentation
has Proxy               => ( is => 'rw', isa => 'Str', default=>'' );  # See Endicia documentation
has RequesterID         => ( is => 'rw', isa => 'Str', default=>'' );  # Get from Endicia during setup
has AccountID           => ( is => 'rw', isa => 'Int', default=>0  );  # Get from Endicia during setup 
has PassPhrase          => ( is => 'rw', isa => 'Str', default=>'' );  # Get from Endicia during setup
has EndiciaAuthToken    => ( is => 'rw', isa => 'Str', default=>'' );  # Get from Endicia during setup (token is read from a file)

has LabelData           => ( is => 'rw', isa => 'HashRef'           );  # Label definition (including Name/Adress info)
has XMLRequest          => ( is => 'rw', isa => 'Str', default=>''  );  # Label definition as XML


#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------

sub _SetFields {
  # Set all the fields based on the values from the package
  my $self = shift;
  my $p    = shift;
  my $label = {};

  my $isConsolidatorLabel = $p->mailclass =~ /(IPA|CommercialePacket)/i ? 1 : 0;

  # Label Request Settings for Consolidator Labels
  #   Set the Test attribute set to "NO".
  #   Set the LabelSize attribute to 4x6.
  #   Set <IncludePostage> to FALSE.
  #   Set <PrintConsolidatorLabel> to TRUE.
  #   <MailpieceDimensions> are required for all MailClass options except Bound Printed Matter. 

  # API info
  $label->{RequesterID} = $self->RequesterID;
  $label->{AccountID} = $self->AccountID;   
  $label->{PassPhrase} = $self->PassPhrase;
#  $label->{Token} = $self->EndiciaAuthToken;        # Use either 'AccountID'+'PassPhase  OR  'Token' 
  $label->{PartnerCustomerID} = "TheTeachingToyBox"; # Mandatory, but used only for internal purposes
  $label->{PartnerTransactionID} = "1";              # Mandatory, but used only for internal purposes

  # Label Options
  $label->{DateAdvance} = $p->date_advance;
  $label->{Stealth} = "TRUE";                       # Default but nice to be explicit here
  $label->{ValidateAddress} = "TRUE";               # Default but nice to be explicit here
  $label->{NonDeliveryOption} = "Return";

  if ( $isConsolidatorLabel ) {
    $label->{IncludePostage} = "FALSE";             # Required for consolidator only
    $label->{PrintConsolidatorLabel} = "TRUE";      # Required for consolidator only
  }

  # Package info
  $label->{MailClass} = $p->mailclass;              # what's the class for ePacket?
  $label->{MailpieceShape} = $p->mailpiece;         # default=Parcel
  $label->{WeightOz} = $p->total_weight_oz;
  $label->{MailpieceDimensions}->{Length} = 6;      # TODO: default dimensions until we get this info in the database
  $label->{MailpieceDimensions}->{Width}  = 4;      # NOTE: Endicia states to put the longest dimension as the 'Length'
  $label->{MailpieceDimensions}->{Height} = 4;      #       to get the best rates.
  $label->{Value} = $p->total_price;

  # Sender
  $label->{FromName} = "The Teaching Toy Box";
  $label->{ReturnAddress1} = "1157 Verona Ridge Dr.";
  # $label->{ReturnAddress2} = "";
  $label->{FromCity} = "Aurora";
  $label->{FromState} = "IL";
  $label->{FromPostalCode} = "60506";
  $label->{FromCountry} = "US";
  $label->{FromPhone} = "7081231234";
  $label->{FromEMail} = 'theteachingtoybox@gmail.com';
  
  # Receipient
  $label->{ToName} =  $p->firstname .' '. $p->lastname;
  $label->{ToCompany} =  $p->company         if $p->company;

  fix_long_addresses($p);  # Endicia label server requires a max of 47 characters on each address line    
  $label->{ToAddress1} =  $p->addressline1;
  $label->{ToAddress2} =  $p->addressline2   if ( defined $p->addressline2 && length($p->addressline2)>0 );
  $label->{ToAddress3} =  $p->addressline3   if ( defined $p->addressline3 && length($p->addressline3)>0 );
  $label->{ToAddress4} =  $p->addressline4   if ( defined $p->addressline4 && length($p->addressline4)>0 );
  $label->{ToCity} =  $p->city;
  $label->{ToState} =  $p->state;
  $label->{ToPostalCode} = $p->dom_intl_flag eq 'D' && length($p->zip) > 5
                         ? substr($p->zip,0,5)
                         : $p->zip;
  $label->{ToCountry} =  $p->countryname;
  $label->{ToCountryCode} =  $p->country;
  $label->{ToEMail} =  $p->emailaddress;

  # Receipient Phone Number - Domestic must be exactly 10 digits
  #                           Intl must be 1-30  digits
  my $phone = $p->phonenumber;
  $phone =~ s/[^\d]//;
  if ( $p->dom_intl_flag eq 'D' ) {
    $label->{ToPhone} =  $phone if ( $phone =~ /^\d{10}$/ );
  }
  else {
    $label->{ToPhone} =  $phone if ( $phone =~ /^\d{1,30}$/ );
  }

  # Customs 
  if ( $p->dom_intl_flag eq 'I' ) {               # true if IPA/E-Packet
    $label->{Description} = "Childs Toy";
    $label->{CustomsCertify} = "TRUE";
    $label->{CustomsSigner} = "Amy Sepelis";
    $label->{CustomsSendersCopy} = "FALSE";                      # Do not print page 4; senders copy of Form2976A/CP72
    $label->{CustomsInfo}->{ContentsType} = "Merchandise";
    $label->{CustomsInfo}->{ContentsExplanation} = "Childs Toy";
    $label->{CustomsInfo}->{NonDeliveryOption} = "Return";
    $label->{CustomsInfo}->{CustomsItems}->{CustomsItem} = {
      Description => 'Childs Toy',
      Quantity   => '1',
      Weight      => $p->total_weight_oz,
      Value       => $p->total_price,
      HSTariffNumber => '950300',       # See https://www.usitc.gov/tata/hts/bychapter/index.htm  Chapter 95 
                                        # Endicia spec only allows for a 6 digit number (eventhough it can be 8 digits)
      CountryOfOrigin => 'US',          # Origin is 'US', but I think this is wrong... it should probably be China
    };

    # Customs form type
    if ( $p->mailclass eq 'PriorityMailInternational' ) {
      $label->{IntegratedFormType} = "Form2976A"; # CP72 - 4-part customs form (used for intl priority PARCEL mail piece)
      $label->{CustomsFormType} = 'Form2976A';    # TODO: tag possibly outdated?  CP72 - 4-part customs form
    }
    else {
      $label->{IntegratedFormType} = "Form2976";  #  CN22 - required when LabelSubType='Integrated'?
    }

    # Customs format for Canada vs rest of world
    if ( $label->{ToCountryCode} eq 'CA' ) {
      $label->{CustomsInfo}->{EelPfc} = "NOEEI 30.36";
    }
    else {
      # Rest of world 
      $label->{CustomsInfo}->{EelPfc} = "NOEEI 30.37(a)";
    }

  } # end customs form


  # Store data structure for label. This gets output as XML, then wrapped as SOAP object.
  $self->LabelData($label);
}

sub _CreateXMLRequest {
  #
  # Converts XML object into XML Request
  #
  my $self = shift;
  my $label = $self->LabelData;
  my $image_format = $self->LabelFormat;
  my ( $xml_head, $xml_body, $xml_foot );

  # Label Request Settings for Consolidator Labels
  #   Set the Test attribute set to "NO".
  #   Set the LabelSize attribute to 4x6.
  #   Set <IncludePostage> to FALSE.
  #   Set <PrintConsolidatorLabel> to TRUE.
  #   <MailpieceDimensions> are required for all MailClass options except Bound Printed Matter. 

  # XML HEAD
  if ( $label->{MailClass} =~ /(IPA|CommercialePacket)/ ) {
    $xml_head = qq/\n<LabelRequest ImageFormat="$image_format" LabelType="International" LabelSubtype="Integrated" 
                      Test="NO" LabelSize="4x6" ImageResolution="203" >/;
  }
  elsif ( $label->{MailClass} eq 'PriorityMailInternational' ) {
    $xml_head = qq/\n<LabelRequest LabelSize="4x6c" ImageFormat="$image_format" LabelSubtype="Integrated" ImageResolution="203" >/;
  }
  else {
    $xml_head = qq/\n<LabelRequest ImageFormat="$image_format" ImageResolution="203" >/;
  }

  # TODO: Assign a unique "<RequestID>xxxxxx</RequestID>", this will ensure we got back the proper 
  #       response to our request

  # XML BODY
  $xml_body = XMLout( $self->{LabelData}, NoAttr=>1, RootName=>undef, KeyAttr=>{});

  # XML FOOT
  my $xml_tags_with_attr;
  $xml_tags_with_attr->{Services} = {
    USPSTracking=>"ON",
    RegisteredMail=>"OFF",
  };

  $xml_tags_with_attr->{ResponseOptions} = { PostagePrice=>"TRUE" };    # tells Endicia to return the ACTUAL POSTAGE PRICE in the Response Object

  $xml_foot = XMLout( $xml_tags_with_attr, NoAttr=>0, RootName=>undef, KeyAttr=>{});


  my $xml_request = <<END;
$xml_head
$xml_body
$xml_foot
</LabelRequest>
END

# TODO: for testing
   open my $xf, '>', "last_label_xml_request.txt";
   print $xf $xml_request;
   close $xf;
#   exit;

  $self->XMLRequest($xml_request);
}

sub _GetLabel {
  #
  # Calls Endicia API
  #
  my $self  = shift;
  my $call  = $self->CallName;
  my $proxy = $self->Proxy;
  my $uri   = $self->Uri;

  my $soap = SOAP::Lite->new( 
    proxy => $proxy,
    uri => $uri,
    on_action => sub {sprintf '"%s/%s"', @_}, 
    readable=>1,
    );

  # Wrap our XML up in a SOAP object and make the API call
  my $elements = SOAP::Data->type( 'xml' => $self->{XMLRequest} );

  # DEBUGGING
#  print "\n\nSOAP OBJ: ", Dumper($soap), "\n\n";
#  print "\n\nSOAP ELEMENTS: ", Dumper($elements), "\n\n";
#  print "\n\nSOAP CALL: ", Dumper($call), "\n\n";

  my $response;
  eval {
    $response = $soap->$call($elements);
  };
  if ($@) {
    # DEBUGGING
#    print "\n\nSOAP RESPONSE: ", Dumper($response), "\n\n";
#    print "\n\nSELF: ", Dumper($self),"\n\n";
    die "\n\nERROR: Soap call failed with error message: $@\n\n";
  }

  die $response->faultstring() if defined $response->fault();

  $self->APIResponse( $response );
}

sub PrintLabel {
  my $self    = shift;
  my $package = shift;
  my $config  = shift;

  my $timestamp = strftime("%Y%m%d%H%M%S", localtime);
  my $ext = $self->LabelFileExtension;

  my $SERVER = $config->{LabelPrinterServer};
  my $PRINTER = $config->{LabelPrinter};                        # Printer 'Share" name 
                                                                # goto printer properties, click on sharing tab
  my $labelDir = $config->{APILabelImageDirectory};
  my $archiveDir = $config->{APILabelImageArchiveDirectory};

  die "ERROR: Both printer and server must be defined in the .ini config file. config:",Dumper($config) 
    if ( !$SERVER && !$PRINTER );

  $self->_SetFields( $package ); # Sets XML object
  $self->_CreateXMLRequest();    # Converts XML object into XML Request 
  $self->_GetLabel();            # Call Endicia API 

  die $self->APIResponse->faultstring() if defined $self->APIResponse->fault();

  my $response_hash = $self->APIResponse->result;
  die $response_hash->{ErrorMessage} if $response_hash->{ErrorMessage};

  # TODO: check $k->{Status} -- I think it should be 0
  # Get Information from API response, such as Tracking Number, Actual Shipping Cost, etc...
  $self->TrackingNumber( $response_hash->{TrackingNumber} );
  $self->ActualPostageCost( $response_hash->{FinalPostage} ) if defined $response_hash->{FinalPostage};

  #
  # Get the Label image(s) from the response object, save it as a file, and send the file to the printer.
  #
  for my $k ( keys %$response_hash ) {

    if ( $k eq 'Label' and defined $response_hash->{$k}->{Image} ) {

      # Make sure it always returns an array reference to making looping easier
      if ( ref($response_hash->{$k}->{Image}) !~ /array/i ) {
        $response_hash->{$k}->{Image} = [ $response_hash->{$k}->{Image} ];
      }

      # International labels (I think)
      my $n = 1;
      for my $imgB64 ( @{ $response_hash->{$k}->{Image} } ) {
        # Convert/Decode the image
        my $img = MIME::Base64::decode_base64($imgB64);

        # Write image to a file
        my $img_filename = "Intl_label_$n.$ext"; 
        my $img_file = "$labelDir/$img_filename";
        $img_file =~ s#/#\\#g;
        open my $fh, '>', "$img_file";
        binmode $fh;
        print $fh $img;
        close $fh;

        # NOTE: When using 'copy', make sure the print is shared!
        #       lpr seems to be a good replacement, except DNS lookup doesn't work, so we need to use ip address.
        # my $print_command = qq/lpr -S $SERVER -P "$PRINTER" -ol $img_file/;
        my $print_command = qq/copy "$img_file" "\\\\$SERVER\\$PRINTER"/;
        my $ret = qx/$print_command/;
        chomp($ret);

        print "\n\n$print_command\n\n";

        if ($?) {
          die "\nERROR: Failed to print label image file: '$img_file'. \nServer='$SERVER' \nPrinter='$PRINTER' \nMsg='$ret' \nCmd='$print_command'";
        }
        else {
          move $img_file, "$archiveDir/$img_filename.$timestamp";
        }
          
        $n++;
      }
      next;
    }

    if ( $k eq 'Base64LabelImage' or $k eq 'Label') {   # Domestic labels (I think)
      # Convert/Decode the image
      my $img = MIME::Base64::decode_base64($response_hash->{$k});

      # Write image to a file
      my $img_filename = "label.$ext";
      my $img_file = "$labelDir/label.$ext";
      $img_file =~ s#/#\\#g;
      open my $fh, '>', "$img_file";
      binmode $fh;
      print $fh $img;
      close $fh;

      #my $print_command = qq/lpr -S $SERVER -P "$PRINTER" -ol $img_file/;
      my $print_command = qq/copy "$img_file" "\\\\$SERVER\\$PRINTER"/;
      my $ret = qx/$print_command/;
      chomp($ret);

      if ($?) {
        die "\nERROR: Failed to print label image file: '$img_file'. \nServer='$SERVER' \nPrinter='$PRINTER' \nMsg='$ret' \nCmd='$print_command'";
      }
      else {
        move $img_file, "$archiveDir/$img_filename.$timestamp";
      }

      next;
    }


    # TODO: For Testing?
#     if ( ref($response_hash->{$k}) =~ /hash/i ) {
#       print "\n$k - ",Dumper($response_hash->{$k});
#     }
#     else {
#       print "\n$k - $response_hash->{$k}";
#     }
  }

} # End PrintLabel

sub fix_long_addresses {
  # Endicia label server requires a max of 47 characters on each address line    
  # This method will split address line1 into multiple lines with a 
  # max of 47 characters and on a word boundary
  my $p = shift;

  my $len1 = length($p->addressline1);
  return if ( $len1 <= 47 ); 

  my $len2 = defined $p->addressline2 ? length($p->addressline2) : 0;
  my $len3 = defined $p->addressline3 ? length($p->addressline3) : 0;
  my $len4 = defined $p->addressline4 ? length($p->addressline4) : 0;

  my $a1 = $p->addressline1;
  my $a2 = $len2 ? $p->addressline2 : '';
  my $a3 = $len3 ? $p->addressline3 : '';
  my $a4 = $len4 ? $p->addressline4 : '';

  # Split address line 1
  my @lines = $a1 =~ /(.{1,47}\W)/gms;

  # Rearrange address lines, based on the number of lines address1 split into
  if ( @lines == 2 ) {
    die "Error: Can't fix long address, print manually." if ( $len4 );
    $p->addressline4( $p->addressline3 ) if ( $len3 );
    $p->addressline3( $p->addressline2 ) if ( $len2 );
    $p->addressline2( $lines[1] );
    $p->addressline1( $lines[0] );
  }
  elsif ( @lines == 3 ) {
    die "Error: Can't fix long address, print manually." if ( $len3 );
    $p->addressline4( $p->addressline2 ) if ( $len2 );
    $p->addressline3( $lines[2] );
    $p->addressline2( $lines[1] );
    $p->addressline1( $lines[0] );
  }
  elsif ( @lines == 4 ) {
    die "Error: Can't fix long address, print manually." if ( $len2 );
    $p->addressline4( $lines[3] );
    $p->addressline3( $lines[2] );
    $p->addressline2( $lines[1] );
    $p->addressline1( $lines[0] );
  }
  elsif ( @lines > 4 ) {
    die "Error: Can't fix long address, print manually." if ( $len2 );
  }

  # Log address change to console
  print <<END;
***************************
***** Address Updated *****
***************************
FROM:
  $a1
  $a2
  $a3
  $a4

TO:
  $p->{addressline1}
  $p->{addressline2}
  $p->{addressline3}
  $p->{addressline4}

END
}

sub _setTokenFromFile {
  # Set EndiciaAuthToken field based on file contents
  my ($self,$string) = @_;

  if ( -f $string ) {
    my $EndiciaAuthToken = read_file( $string ) or die "can't read token file: '$string'";
    $EndiciaAuthToken =~ s/^\s+//;
    $EndiciaAuthToken =~ s/\s+$//;
    $self->EndiciaAuthToken($EndiciaAuthToken);
  } 
  else {
    $self->EndiciaAuthToken($string);
  }
}

sub _setHeaderValues() {
  # Set all the header values based on the environment selected
  my ($self,$environment) = @_;

  if ( $environment =~ /production/i ) {
    # PRODUCTION
    $self->CallName          ( 'GetPostageLabel' );
    $self->Uri               ( 'www.envmgr.com/LabelService' );
    $self->Proxy             ( 'https://labelserver.endicia.com/LabelService/EwsLabelService.asmx' );
    $self->RequesterID       ( '1139691' );
    $self->AccountID         ( '1139691' );
    $self->PassPhrase        ( 'GiveMeTacos27' );   # different from password. To reset: http://www.endicia.com/support/forgot-passphrase.
    $self->_setTokenFromFile ( 'cfg/endicia_api_production_token.txt' );
  }
  else {
    # DEVELOPMENT
    $self->CallName          ( 'GetPostageLabel' );
    $self->Uri               ( 'www.envmgr.com/LabelService' );
    $self->Proxy             ( 'https://elstestserver.endicia.com/LabelService/EwsLabelService.asmx' );
    $self->RequesterID       ( '2502641' );
    $self->AccountID         ( '2502641' );
    $self->PassPhrase        ( 'its only a FLESH w0und!' );
#     $self->AccountID         ( '2513440' );
#     $self->PassPhrase        ( 'WeGotFunAndGames' );
    $self->_setTokenFromFile ( 'cfg/endicia_api_development_token.txt' );
  }
}


1;


