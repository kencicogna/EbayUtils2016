#!/usr/bin/perl -w 

use strict;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request;
use HTTP::Headers;
use HTML::Restrict;
use DBI;
use XML::Simple qw(XMLin XMLout);
# use XML::Tidy;
use Date::Calc 'Today';
use Data::Dumper 'Dumper';			$Data::Dumper::Sortkeys = 1;
use File::Copy qw(copy move);
use POSIX;
use Getopt::Std;
use Storable 'dclone';

use HTML::Entities;
use XML::Entities qw(decode numify);
use Text::Unidecode 'unidecode';

#binmode(STDOUT, ":encoding(UTF-8)");


my $a = 'pe&amp;#233;a colata';

my $d = XML::Entities::decode('all',$a);

my $e = HTML::Entities::decode_entities( $d );

print "\na: '$a'";
print "\nd: '$d'";
print "\ne: '$e'";


print "\n\n";
