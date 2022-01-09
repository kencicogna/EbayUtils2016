#!/usr/bin/perl

# Outputting .csv:
#   embedded double quoted => double them ( " => "" )
#   embedded commas => double quotes around cell value ( one,two =>  "one,two" )

 

use strict;
use Getopt::Std;
use Data::Dumper 'Dumper';
use Text::CSV_XS;
use DBI;

$|=1;
 
my $ODBC     = 'BTData_PROD_SQLEXPRESS';

my $rownum=0;
my $isParent = 0;
my $header_row1=[];
my $header_row2=[];
my $us_listings = {};
my $parentSite = '';
my $parentItemID = '';
my $type = '';

my %opts;
getopts('i:s',\%opts);

# -i <input file>  - Ebay File Exchange (Standard price/quantity)
# -s               - Skip duplicate SKU's

die "\nUsage: $0 -i <Ebay FileExchange file>\n\n" unless $opts{i};
my $inputfile = $opts{i};
(my $outputfile = $inputfile) =~ s/csv$/upload.csv/;

my $skip_dups = $opts{s};

# Init
my $all_skus = {};   # check for dups


# DB Connection
my $dbh = DBI->connect( "DBI:ODBC:$ODBC", 'shipit', 'shipit',
                  { 
                    RaiseError       => 0, 
                    AutoCommit       => 1, 
                    FetchHashKeyName => 'NAME_lc',
                    LongReadLen      => 100000,
                  } 
                )
    || die "\n\nDatabase connection not made: $DBI::errstr\n\n";

# Create csv parser object
my $csv = Text::CSV_XS->new ({ binary => 1, auto_diag => 1 });

open my $fh, "<:encoding(unicode)", $inputfile or die "can't open $inputfile: $!";

while (my $row = $csv->getline ($fh)) {

  $rownum++;

  # header row 1
  if ( $rownum == 1 ) {
    $header_row1 = $row;
    splice( @$header_row1, 5, 3 );  # remove unwanted columns 
    next;
  }

  # header row 2
  if ( $rownum == 2 ) {
    $header_row2 = $row;
    splice( @$header_row2, 5, 3 );  # remove unwanted columns 
    next;
  }

  # Get Columns
  my $itemID        = $row->[1];
  my $site          = $row->[3];
  my $hasVariations = $row->[9] ? 1 : 0;
  my $sku           = defined $row->[10] ? $row->[10] : '';

  # Process rows

  if ( $itemID ) {

    # Parent Row
    $isParent=1;

    die 'Site (US/UK/AU/etc.) not defined' unless $site;

    if ( $hasVariations ) {
      ################################################################################
      # Parent listing with Variations
      ################################################################################
      $type = 'listing with variations';
      $parentSite = $site;
      $parentItemID = $itemID;
    }
    else {
      ################################################################################
      # Non-variation listing
      ################################################################################
      $type = 'Non-variation listing';
      $parentSite = '';
      $parentItemID = '';
    }

    # This line needs to here, so that ParentSite get set, before skipping to the next record
    next if ( $site ne 'US' ); 

    # Only count US site SKU's (we know the SKU is duplicated across sites)
    if ($sku) {
      $all_skus->{$sku}->{count}++;
      push( @{$all_skus->{$sku}->{rows}}, $rownum);
    }

    $us_listings->{$itemID}->{parent} = $row;

    if ( ! $sku ) {
      $us_listings->{$itemID}->{update}++;
    }

  }
  else {
    ################################################################################
    # Variation row
    ################################################################################
    $isParent=0;

    next if ( $parentSite ne 'US' );

    if ($sku) {
      $all_skus->{$sku}->{count}++;
      push( @{$all_skus->{$sku}->{rows}}, $rownum);
    }

    push( @{$us_listings->{$parentItemID}->{variations}}, $row);

    if ( ! $sku ) {
      $us_listings->{$parentItemID}->{update}++;
    }
  }

}
close $fh;

my $dups;
for my $s ( keys %$all_skus ) {
  if ( $all_skus->{$s}->{count} > 1 ) {
    print "\nDuplicate SKU found: '$s' on rows ", join(', ',@{$all_skus->{$s}->{rows}}) ;
    $dups++;
  }
}
die "\n\nERROR: $dups dupilcate SKU's found. Fix on eBay, repull file from eBay, and rerun this program." if ( $dups && !$skip_dups );


#
# Output 
#
 
# Create csv writer object
my $csv = Text::CSV_XS->new ({ binary => 1, eol => $/ });

# Open output file
open my $outfh, ">", $outputfile or die "Can't open $outputfile: $!";

# Write header row
$csv->print ($outfh, $header_row1) or $csv->error_diag;
$csv->print ($outfh, $header_row2) or $csv->error_diag;

# Find rows that need to be updated
foreach my $id ( %$us_listings ) {

  my $new_sku;
  my $listing = $us_listings->{$id};

  if ( $listing->{update} ) {
    # print Dumper($listing);
    
    # Get sku for parent record (if needed)
    if ( ! $listing->{parent}->[10] ) {
      $new_sku = get_next_sku();
      $listing->{parent}->[10] = $new_sku;
    }

    # remove unwanted columns
    splice( @{$listing->{parent}}, 5, 3 );

    # Write parent record
    $csv->print ($outfh, $listing->{parent}) or $csv->error_diag;

    # Write child records
    if ( defined $listing->{variations} ) {
      for my $child ( @{$listing->{variations}}  ) {

        # Get sku for child record (if needed)
        if ( ! $child->[10] ) {
          $new_sku = get_next_sku();
          #$listing->{parent}->[10] = $new_sku;
          $child->[10] = $new_sku;
        }

        # remove unwanted columns
        splice( @$child, 5, 3 );

        # Write child record
        $csv->print ($outfh, $child) or $csv->error_diag;

      }
    }
  }

}

close $outfh or die "$outputfile: $!";

 
exit;


################################################################################
# Subroutines
################################################################################

sub get_next_sku() {

  # Get next sku value
  my ($prefix,$sequence) = $dbh->selectrow_array('select sku_prefix, sku_nextval from dbo.ttb_next_sku');

  # update dbo.ttb_next_sku
  $dbh->do('update dbo.ttb_next_sku set sku_nextval = sku_nextval+1');

  $sequence = sprintf("%07s",$sequence);

  return $prefix . $sequence;
}







