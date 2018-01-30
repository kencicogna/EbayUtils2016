package ShipItPackage;

use Moose;

has 'id'           => ( is => 'rw', isa => 'Str', default=>'' );                         # ShipIt's PackageID (e.g. 'TTY12345')
has 'ebayuserid'   => ( is => 'rw', isa => 'Str', default=>'' );
has 'indstr'       => ( is => 'rw', isa => 'Maybe[Str]', default=>'');
has 'indhash'      => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has 'firstname'    => ( is => 'rw', isa => 'Str', default=>' ' );
has 'lastname'     => ( is => 'rw', isa => 'Str', default=>' ' );
has 'buyer'        => ( is => 'rw', isa => 'Str', default=>'' );
has 'company'      => ( is => 'rw', isa => 'Str', default=>'' );
has 'address'      => ( is => 'rw', isa => 'Str', default=>'' );
has 'addressline1' => ( is => 'rw', isa => 'Str', default=>'' );
has 'addressline2' => ( is => 'rw', isa => 'Maybe[Str]', default=>''  );  # NOTE: there was not default set previous...
has 'addressline3' => ( is => 'rw', isa => 'Maybe[Str]', default=>''  );  # NOTE: there was not default set previous...
has 'addressline4' => ( is => 'rw', isa => 'Maybe[Str]', default=>''  );  # NOTE: there was not default set previous...
has 'city'         => ( is => 'rw', isa => 'Str', default=>'' );
has 'state'        => ( is => 'rw', isa => 'Str', default=>'' );
has 'zip'          => ( is => 'rw', isa => 'Str', default=>'' );
has 'countryname'  => ( is => 'rw', isa => 'Str', default=>'' );
has 'country'      => ( is => 'rw', isa => 'Str', default=>'' );
has 'emailaddress' => ( is => 'rw', isa => 'Str', default=>'' );
has 'phonenumber'  => ( is => 'rw', isa => 'Str', default=>'' );
has 'total_items'  => ( is => 'rw', isa => 'Int', default=>0  );
has 'total_price'  => ( is => 'rw', isa => 'Num', default=>0.00 );
has 'notes'        => ( is => 'rw', isa => 'Str', default=>'' );
has 'customercheckoutnotes' => ( is => 'rw', isa => 'Str', default=>'' );
has 'status_type'  => ( is => 'rw', isa => 'Str', default=>'' );
has 'weight_lbs'   => ( is => 'rw', isa => 'Int', default=>0);
has 'weight_oz'    => ( is => 'rw', isa => 'Int', default=>0);
has 'total_weight_oz' => ( is => 'rw', isa => 'Int', default=>0);
has 'mailclass'       => ( is => 'rw', isa => 'Str', default=>'' );
has 'mailpiece'       => ( is => 'rw', isa => 'Str', default=>'' );
has 'dom_intl_flag'   => ( is => 'rw', isa => 'Str', default=>'' );
has 'date_advance'    => ( is => 'rw', isa => 'Int', default=>0);  # number of days to adjust the shipping date 
has 'shipping_cost'   => ( is => 'rw', isa => 'Num', default=>0.00 );
has 'tracking_number' => ( is => 'rw', isa => 'Str', default=>'' );

has 'items'        => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );

has 'status'       => ( is => 'rw', isa => 'Str', default=>'', trigger => \&_upd_status_text);  # see status_test_map below
has 'status_text'  => ( is => 'rw', isa => 'Str', default=>'' );                               # see status_test_map below

# TODO: some of these are BlackThorne related and could be removed
has 'archived_flag'           => ( is => 'rw', isa => 'Str', default=>'' );
has 'trackingnum_exists_flag' => ( is => 'rw', isa => 'Str', default=>'' );
has 'ship_priority_flag'      => ( is => 'rw', isa => 'Str', default=>'' );
has 'mult_order_id_flag'      => ( is => 'rw', isa => 'Str', default=>'' );
has 'echeck_flag'             => ( is => 'rw', isa => 'Str', default=>'' );
has 'notes_flag'              => ( is => 'rw', isa => 'Str', default=>'' );


my $status_text_map = 
{
  S  => 'Staged',
  SE => 'Error Staging',
  T  => 'Tracking Updated',
  TE => 'Error Updating Tracking',
  P  => 'Printed Label',
  PE => 'Error Printing Label',
};

sub _upd_status_text
{
  my ($self,$status_cd) = @_;

  if ( defined $status_text_map->{$status_cd} ) {
    $self->status_text( $status_text_map->{$status_cd} );
  }
  else {
    $self->status_text( 'Unknown Status Code' );
  }
}


1;
