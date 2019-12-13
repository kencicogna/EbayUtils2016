
use strict;
use SOAP::Lite 'trace', 'debug';     # dumps Request / Response values
#use SOAP::Lite;
use File::Slurp;
use Data::Dumper;
#use XML::LibXML;

#my $acct='2502641';  
my $acct='2513440';  
my $requesterID='lxxx';               # same for all sandbox accounts
my $passPhrase='WeGotFunAndGames'; 


my $call  = 'GetVersion';                                                      # Method name
my $uri   = "www.envmgr.com/LabelService";                                           # xmlns  ($call gets added to this to make up the SOAPAction)
my $proxy = 'https://elstestserver.endicia.com/LabelService/EwsLabelService.asmx';   # WebService name/url
my $resultPath = "//${call}Results";                                                 # Name of first tag inside the 'Response' tag ( i.e. inside <${call}Response xmlns=...> )

my $soap = SOAP::Lite->new( 
    proxy => $proxy,
    uri => $uri,
    on_action => sub {sprintf '"%s/%s"', @_}, 
    readable=>1,
    );

#print Dumper($soap); exit;

# Make the Call. Pass GET/POST values needed to the Request.
my $elems = SOAP::Data->name("${call}Request" => \SOAP::Data->value( 
                  SOAP::Data->name('RequesterID' => $requesterID)->type('string'),
                  SOAP::Data->name('RequestID'   => '1')->type('string'),
                  SOAP::Data->name('CertifiedIntermediary'  => \SOAP::Data->value(
                    SOAP::Data->name('AccountID'  => $acct)->type('string'),
                    SOAP::Data->name('PassPhrase' => $passPhrase)->type('string'),
                    )
                  ),
                  SOAP::Data->name($call)->attr({xmlns=>$uri}) => ''
                  )
             )->attr({TokenRequested=>1})
;

my $response = $soap->$call($elems);

# my $response = $soap->call(
#       SOAP::Data->name($call)->attr({xmlns=>$uri}) => SOAP::Data->name('token')->value($token),
#       SOAP::Data->name('filter')                   => SOAP::Data->name('LastModifiedDate')->value('20150110') ),
#     );

die $response->faultstring() if defined $response->fault();

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
