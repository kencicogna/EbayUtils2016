
use strict;
#use SOAP::Lite 'trace', 'debug';     # dumps Request / Response values
use SOAP::Lite;
use MIME::Base64;
#use MIME::Entity;
use File::Slurp;
use File::Copy 'copy';
use Data::Dumper;
use XML::LibXML::PrettyPrint;
use Getopt::Std;
$|=1;

my $SERVER = '192.168.1.74'; # TTB-SERVER
my $PRINTER = 'ZDesigner LP 2844'; # This could vary from computer to computer

my %opts;
getopts('id', \%opts);
if ( $opts{i} ) {
  require "./xml_intl.pl";
} elsif ( $opts{d} ) {
  require "./xml_dom.pl";
} else {
  my $f = $0;
  $f =~ s/.*\\//;
  die "\n\nError: Must supply -i or -d\n\nUsage: $f  [-i] [-d]\n\n-i => international label\n-d => domestic label\n\n";
}

our $xmloutput;
our $outfile_ext;

$|=1;

my $ext = $outfile_ext;

my $call  = 'GetPostageLabel';                                                       # Method name
my $uri   = "www.envmgr.com/LabelService";                                           # xmlns  ($call gets added to this to make up the SOAPAction)
my $proxy = 'https://elstestserver.endicia.com/LabelService/EwsLabelService.asmx';   # WebService name/url
my $resultPath = "//${call}Results";                                                 # Name of first tag inside the 'Response' tag ( i.e. inside <${call}Response xmlns=...> )

my $soap = SOAP::Lite->new( 
    proxy => $proxy,
    uri => $uri,
    on_action => sub {sprintf '"%s/%s"', @_}, 
    readable=>1,
    );

my $elements = SOAP::Data->type(  'xml' => $xmloutput );
my $response = $soap->$call($elements);

# print "\nSOAP:",Dumper($soap);
# print "\nELEMENTS:",Dumper($soap);


die $response->faultstring() if defined $response->fault();

#print Dumper($xmloutput); # input request

my $response_hash = $response->result;

print "\n\nRESPONSE: ",Dumper($response_hash);
exit;

for my $k ( keys %$response_hash ) {

  if ( $k eq 'Label' and defined $response_hash->{$k}->{Image} ) {
    if ( ref($response_hash->{$k}->{Image}) !~ /array/i ) {
      $response_hash->{$k}->{Image} = [ $response_hash->{$k}->{Image} ];
    }

    my $n = 1;
    for my $imgB64 ( @{ $response_hash->{$k}->{Image} } ) {
      my $epl_file = "Intl_label_$n.$ext";
      open my $fh, '>', $epl_file;
      my $img = MIME::Base64::decode_base64($imgB64);
      binmode $fh;
      print $fh $img;
      close $fh;

      # TODO: ..... this no longer works, not sure why,
      #       However, lpr seems to be a good replacement, except DNS lookup 
      #       doesn't work, so we have to hard-code the IP address
      copy $epl_file, '\\\\TTB-SERVER\\ZDesigner LP 2844'; 
      #system( qq/lpr -S $SERVER -P "$PRINTER" -o l $epl_file/ );

      if ( $? == 0 ) {
        print "\nLabel Printed Successfully\n";
      }
      else {
        print "\nError Printing Label\n";
      }

      $n++;
    }
    next;
  }

  if ( $k eq 'Base64LabelImage' or $k eq 'Label') {                                       # Domestic only?
    open my $fh, '>', "label.$ext";
    my $img = MIME::Base64::decode_base64($response_hash->{$k});
    binmode $fh;
    print $fh $img;
    close $fh;

    # This line actually prints the label!
    copy "label.$ext", '\\\\NINJA2\\ZDesigner LP 2844';

    next;
  }

  if ( ref($response_hash->{$k}) =~ /hash/i ) {
    print "\n$k - ",Dumper($response_hash->{$k});
  }
  else {
    print "\n$k - $response_hash->{$k}";
  }
}

print "\n\n";
exit;

#print Dumper($response);

foreach my $type ($response->valueof($resultPath)) {
  next unless ($type); ## ignore any undefs
  print "TYPE: $type\n";
  if ( ref($type) =~ /HASH/ ) {

    # TODO: Do something with the values here
    print Dumper($type);

  }
}



exit(0);
