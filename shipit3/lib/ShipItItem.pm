package ShipItItem;

use Moose;

has ebayItemID         => ( is => 'rw', isa => 'Str', default=>'');  # Ebay's ItemID
has ebayTransactionID  => ( is => 'rw', isa => 'Str', default=>'');  # Ebay's TransactionID
has ebayOrderID        => ( is => 'rw', isa => 'Str', default=>'');  # Ebay's OrderID
has ebaySaleID         => ( is => 'rw', isa => 'Str', default=>'');  # Ebay's SaleID
has title              => ( is => 'rw', isa => 'Str', default=>'');
has variation          => ( is => 'rw', isa => 'Str', default=>'');
has qtysold            => ( is => 'rw', isa => 'Str', default=>'');
has price              => ( is => 'rw', isa => 'Num', default=>0.00);
has paid_on_date       => ( is => 'rw', isa => 'Str', default=>'');
has indstr             => ( is => 'rw', isa => 'Str', default=>'');
has ship_priority_flag => ( is => 'rw', isa => 'Str', default=>'');
has status             => ( is => 'rw', isa => 'Str', default=>'');  # tracking updated, error, etc...
has image_url          => ( is => 'rw', isa => 'Str', default=>'');
has image              => ( is => 'rw', isa => 'Any', default=>'');
has location           => ( is => 'rw', isa => 'Maybe[Str]', default=>'');
has packaging          => ( is => 'rw', isa => 'Maybe[Str]', default=>'');
has bubble_wrap        => ( is => 'rw', isa => 'Maybe[Str]', default=>'');
has packaged_weight    => ( is => 'rw', isa => 'Maybe[Num]', default=>0.00);

1;
