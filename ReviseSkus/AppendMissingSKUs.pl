#!/usr/bin/perl

# Outputting .csv:
#   embedded double quoted => double them ( " => "" )
#   embedded commas => double quotes around cell value ( one,two =>  "one,two" )

 

use strict;
use Data::Dumper 'Dumper';
use Text::CSV_XS;
use DBI;
 
my $basefile = 'FileExchange_Response_47120668';
my $ODBC     = 'BTData_PROD_SQLEXPRESS';

my $rownum=0;
my $isParent = 0;
my $header_row;
my $us_listings = {};
my $parentSite = '';
my $parentItemID = '';
my $type = '';


# DB Connection
my $dbh = DBI->connect( "DBI:ODBC:$ODBC", 'shipit2', 'shipit2',
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

open my $fh, "<:encoding(unicode)", "$basefile.csv" or die "can't open $basefile.csv: $!";

while (my $row = $csv->getline ($fh)) {

  # header row
  if ( $rownum++ == 0 ) {
    $header_row = $row;

    # remove unwanted columns
    splice( @$header_row, 5, 3 );

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

    next if ( $site ne 'US' );

    $us_listings->{$itemID}->{parent} = $row;

    # Debug
    if ( ! $sku ) {
      $us_listings->{$itemID}->{update}++;
      #print "\n\nType: $type\nSKU:$sku\nID: $itemID\nTitle: $row->[2]\nParent Site: $parentSite\nSite: $site\nVariations: $row->[9]\n";
    }

  }
  else {
    ################################################################################
    # Variation row
    ################################################################################
    $isParent=0;

    next if ( $parentSite ne 'US' );

    push( @{$us_listings->{$parentItemID}->{variations}}, $row);

    # Debug
    if ( ! $sku ) {
      $us_listings->{$itemID}->{update}++;
      #print "\n\tType: Variation\n\tSKU: $sku\n\tID: $itemID\n\tTitle: $row->[2]\n\tParent Site: $parentSite\n\tSite: $site\n\tVariations: $row->[9]\n";
    }
  }

}
close $fh;


#
# Output 
#
 
# Create csv writer object
my $csv = Text::CSV_XS->new ({ binary => 1, eol => $/ });

# Open output file
open my $outfh, ">", "$basefile.out.csv" or die "$basefile.out.csv: $!";

# Write header row
$csv->print ($outfh, $header_row) or $csv->error_diag;

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
          $listing->{parent}->[10] = $new_sku;
        }

        # remove unwanted columns
        splice( @$child, 5, 3 );

        # Write child record
        $csv->print ($outfh, $child) or $csv->error_diag;

      }
    }
  }

}

close $outfh or die "$basefile.out.csv: $!";

 
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







