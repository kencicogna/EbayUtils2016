
use strict;
use DBI;
use Data::Dumper 'Dumper';
use Getopt::Std 'getopts';

my $ODBC = 'BTData_PROD_SQLEXPRESS';

# Command line options
my %opts;
my $options = 'i:';
die "error: cant get opts" unless ( getopts($options,\%opts) );
die "error: Input file does not exist" unless ( -f $opts{i} );

my $inputfile = $opts{i};

open my $fh, '<', $inputfile;

my $dbh =
  DBI->connect( "DBI:ODBC:$ODBC",
                'shipit',
                'shipit',
                { 
                  RaiseError       => 1, 
                  AutoCommit       => 1, 
                  FetchHashKeyName => 'NAME_lc',
                  LongReadLen      => 100000,
                } 
              )
  || die "\n\nDatabase connection not made: $DBI::errstr\n\n";

my $sth_sel = $dbh->prepare( q/select title,variation from Inventory where ebayItemID = ? and replace( isnull(variation,''), '"', '') = ? and active=1/ );
my $sth_upd = $dbh->prepare( q/update Inventory set cost = ? where ebayItemID = ? and replace( isnull(variation,''), '"', '') = ? and cost is null/ );

my $linenum=0;
while ( <$fh> ) 
{
  chomp;
  $linenum++;
  next if ( $linenum==1 );      # ONLY IF FILE HAS A HEADER ROW

  my @line = split(/\t/);

  my $ebayid = $line[0];
  my $title = $line[1];
  my $var = $line[2];
  my $cost = $line[3];

  next unless $cost;

  # clean up double quotes around variations
  $var =~ s/"//g;

  # Find match
  $sth_sel->execute( $ebayid, $var );

  my $matches = 0;
  while ( my @match = $sth_sel->fetchrow_array ) {
    $matches++;
  }

  # Display results 
  #print "\n$linenum:\t$matches\t$cost \t$ebayid\t$title ($var)"  if ( $matches==0 or $matches>1);
  #print "\n$linenum:\t$matches\t$cost \t$ebayid\t$title ($var)"  if ( $matches>1);

  # UPDATE DB
  if ( $matches==1) {
    print "\n$linenum:\t$matches\t$cost \t$ebayid\t$title ($var)";
    $sth_upd->execute( $cost, $ebayid, $var );
  }
 
}

close($fh);


print "\n\n";
exit;
