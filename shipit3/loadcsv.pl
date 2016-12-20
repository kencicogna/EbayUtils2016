#!/usr/bin/perl 

use strict;
use Parse::CSV;
use Text::CSV;
use Data::Dumper 'Dumper';
$Data::Dumper::SortKeys=1;

my $file = 'C:\\EbayOrders\\orders.csv';
print "\nFILE: $file";

open my $fh, '<', $file or die "can't open $file";

my @rows;
my $csv = Text::CSV->new ( { binary => 1 } )  # should set binary attribute.
                 or die "Cannot use CSV: ".Text::CSV->error_diag ();

my $colnames = $csv->getline($fh);
for ( @$colnames ) { s/ //g; }
$csv->column_names ( @$colnames );

while ( my $row = $csv->getline_hr( $fh ) ) {
  print Dumper($row);
  exit;
}


close $fh;
