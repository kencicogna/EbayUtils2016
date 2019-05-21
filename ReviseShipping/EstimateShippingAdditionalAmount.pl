use strict;
use POSIX qw(ceil);
use Data::Dumper 'Dumper';
use Fatal qw(open close);

$Data::Dumper::Sortkeys = 1;

#
# Calculate Addition amount
#

my $stats = {};

# Ounces per item
for my $ozs ( 1..15, 15.999, 16..20 ) {

  # Number of items purchased
  for my $items ( 1..10 ) {

    my $fc_cost_one_item  = 'n/a';
    my $fc_total_cost     = 'n/a';
    my $fc_total_packages = 'n/a';
    my $fc_packages       = {};

    my $total_weight_ozs = $ozs * $items;
    my $total_weight_lbs = $total_weight_ozs/16;


    if ( $ozs < 16 ) {
      $fc_cost_one_item  = fc_get_cost( $ozs );
      $fc_total_packages = ceil($total_weight_ozs/15.999); 
      $fc_packages       = fc_get_pkg_details($items, $ozs);
      for ( keys %$fc_packages ) {
        $fc_total_cost += $fc_packages->{$_}->{total_cost};
      }
    }

    $stats->{$ozs}->{$items}->{total_ozs} = $total_weight_ozs;
    $stats->{$ozs}->{$items}->{total_lbs} = $total_weight_lbs;
    $stats->{$ozs}->{$items}->{fc_cost_1} = $fc_cost_one_item;

    $stats->{$ozs}->{$items}->{fc_total_cost} = $fc_total_cost; 
    $stats->{$ozs}->{$items}->{fc_packages} = $fc_packages;
    $stats->{$ozs}->{$items}->{fc_tot_pkgs} = scalar keys %$fc_packages;
      
    $stats->{$ozs}->{$items}->{pri_total_cost} = pri_get_cost( $total_weight_lbs );

  }
}

#print Dumper($stats);



# TODO: Add additional cost and shipping collected column; insert fomulas:  "=(F33-F24)/10"
#       this will be a little trick, have to keep track of rows.
#
#       What about NOT offering the shipping discount ???


#
# Display output
#
#
open my $fh, '>', 'additional_amount_analysis.csv';
print $fh "Item Weight,Total Items,Total Oz,Total Lbs,First Class Packages,First Class Cost,Priority Cost,Additional Cost\n";

for my $itemWeight ( sort {$a<=>$b} keys %$stats ) {
  for my $totalItems ( sort {$a<=>$b} keys %{$stats->{$itemWeight}} ) {

    my $p = $stats->{$itemWeight}->{$totalItems};

    print $fh "$itemWeight,$totalItems,$p->{total_ozs},$p->{total_lbs},$p->{fc_tot_pkgs},$p->{fc_total_cost},$p->{pri_total_cost},\n";
  }
  print $fh "\n";
}

close $fh;

print "\n\n";
exit;




################################################################################
# Subroutines
################################################################################
sub fc_get_pkg_details  {
  my ($items,$ozs) = @_;

  my $pkgs  = {};

  my $pkg_num = 1;
  my $pkgs->{$pkg_num} = {items=>0,weight=>0,total_cost=>0};   # initialize first package
  my $current_package_weight = 0;

  for my $i ( 1..$items ) {

    $current_package_weight = $pkgs->{$pkg_num}->{weight};

    if ( $current_package_weight + $ozs >= 16 ) {
      # Calculate toal cost for current package
      $pkgs->{$pkg_num}->{total_cost} = fc_get_cost( $current_package_weight );

      # Put item in a new pkg
      $pkg_num++;
    }

    $pkgs->{$pkg_num}->{items}++;
    $pkgs->{$pkg_num}->{weight} += $ozs; 
  }

  # Calculate toal cost for last package
  $current_package_weight         = $pkgs->{$pkg_num}->{weight};
  $pkgs->{$pkg_num}->{total_cost} = fc_get_cost( $current_package_weight );

  return $pkgs;
}


################################################################################
sub fc_get_cost {

  my $ozs = shift;

  $ozs = $ozs > 15 && $ozs < 16 ? 15.999 : $ozs;

  # First Class Shipping Cost
  my $firstClassShipping = {
    1 =>	'2.96',
    2 =>	'2.96',
    3 =>	'2.96',
    4 =>	'2.96',

    5 =>	'3.49',
    6 =>	'3.49',
    7 =>	'3.49',
    8 =>	'3.49',

    9  =>	'4.19',
    10 => '4.19',
    11 => '4.19',
    12 => '4.19',

    13 => '5.38',
    14 => '5.38',
    15 => '5.38',
    15.999 =>	'5.38',
  };

  return $firstClassShipping->{$ozs};

}


################################################################################
sub pri_get_cost {

  my $total_weight_lbs = shift;

  $total_weight_lbs = ceil($total_weight_lbs);  # round up

  # Priority Shipping Cost
  my $priorityShipping = {
    1  =>	'7.99',
    2  =>	'10.23',
    3  =>	'13.10',
    4  =>	'15.59',
    5  =>	'17.92',
    6  =>	'20.83',
    7  =>	'23.48',
    8  =>	'25.85',
    9  =>	'28.00',
    10 =>	'30.79',
    11 =>	'33.51',
    12 =>	'36.23',
    13 =>	'37.69',
    14 =>	'39.79',
    15 =>	'40.56',
  };

  return $priorityShipping->{$total_weight_lbs};
}











#
# Calculate Addition amount
#

my $stats = {};

# Ounces per item
#for my $ozs ( 1..15, 15.999, 16..20 ) {
for my $ozs ( 5 ) {

  # Number of items purchased
#  for my $items ( 1..10 ) {
  for my $items ( 10 ) {

    my $fc_cost_one_item  = 'n/a';
    my $fc_total_cost     = 'n/a';
    my $fc_total_packages = 'n/a';
    my $fc_packages       = {};

    my $total_weight_ozs = $ozs * $items;
    my $total_weight_lbs = ceil($total_weight_ozs/16);  # rounded up for priority

    if ( $ozs < 16 ) {
      $fc_cost_one_item  = fc_get_cost( $ozs );
      $fc_total_packages = ceil($total_weight_ozs/15.999); 
      $fc_packages       = fc_get_pkg_details($items, $ozs);
    }

    $stats->{$ozs}->{$items}->{ozs} = $total_weight_ozs;
    $stats->{$ozs}->{$items}->{lbs} = $total_weight_lbs;
    $stats->{$ozs}->{$items}->{fc_cost_1} = $fc_cost_one_item;
    $stats->{$ozs}->{$items}->{fc_packages} = $fc_packages;
    $stats->{$ozs}->{$items}->{fc_tot_pkgs} = scalar keys %$fc_packages

  }
}

print Dumper($stats);



print "\n\n";
exit;

sub fc_get_pkg_details  {
  my ($items,$ozs) = @_;

  my $pkgs  = {};

  my $pkg_num = 1;
  my $pkgs->{$pkg_num} = {items=>0,weight=>0,total_cost=>0};   # initialize first package
  my $current_package_weight = 0;

  for my $i ( 1..$items ) {

    $current_package_weight = $pkgs->{$pkg_num}->{weight};

    if ( $current_package_weight + $ozs >= 16 ) {
      # Calculate toal cost for current package
      $pkgs->{$pkg_num}->{total_cost} = fc_get_cost( $current_package_weight );

      # Put item in a new pkg
      $pkg_num++;
    }

    $pkgs->{$pkg_num}->{items}++;
    $pkgs->{$pkg_num}->{weight} += $ozs; 
  }

  # Calculate toal cost for last package
  $current_package_weight         = $pkgs->{$pkg_num}->{weight};
  $pkgs->{$pkg_num}->{total_cost} = fc_get_cost( $current_package_weight );

  return $pkgs;
}


sub fc_get_cost {

  my $ozs = shift;

  $ozs = $ozs > 15 && $ozs < 16 ? 15.999 : $ozs;

  # First Class Shipping Cost
  my $firstClassShipping = {
    1 =>	'2.96',
    2 =>	'2.96',
    3 =>	'2.96',
    4 =>	'2.96',

    5 =>	'3.49',
    6 =>	'3.49',
    7 =>	'3.49',
    8 =>	'3.49',

    9  =>	'4.19',
    10 => '4.19',
    11 => '4.19',
    12 => '4.19',

    13 => '5.38',
    14 => '5.38',
    15 => '5.38',
    15.999 =>	'5.38',
  };

  return $firstClassShipping->{$ozs};

}


# Priority Shipping Cost
my $priorityShipping = {
  1  =>	'7.99',
  2  =>	'10.23',
  3  =>	'13.10',
  4  =>	'15.59',
  5  =>	'17.92',
  6  =>	'20.83',
  7  =>	'23.48',
  8  =>	'25.85',
  9  =>	'28.00',
  10 =>	'30.79',
};












