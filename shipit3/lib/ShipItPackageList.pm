package ShipItPackageList;

use Wx qw[:everything];
use Moose;
use ShipItPackage;
use ShipItItem;
use ShipItEbayAPICallGetOrders;

use Carp;
use List::MoreUtils;
use Data::Dumper 'Dumper';
use XML::Simple;
use HTML::Entities;
use XML::Entities 'decode';
use Text::Unidecode 'unidecode';
use Storable 'dclone';
use DBI;
use Spreadsheet::WriteExcel;

#-------------------------------------------------------------------------------
# Attributes
#-------------------------------------------------------------------------------
has id            => ( is => 'rw', isa => 'Int', );
has type          => ( is => 'rw', isa => 'Str', );
has packages      => ( is => 'rw', isa => 'HashRef',  default => sub { {} } );
has packages_byID => ( is => 'rw', isa => 'HashRef',  default => sub { {} } );
has packages_ary  => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has sql           => ( is => 'rw', isa => 'Str', );
has dbh           => ( is => 'ro', isa => 'Object', );
has packageTypes  => ( is => 'rw', isa => 'HashRef',  default => sub { {} } );


#-------------------------------------------------------------------------------
# Methods
#-------------------------------------------------------------------------------
sub load {
  my $self = shift;
  my $cfg  = shift;
  my $parent_window = shift;
  my ($sql, $sth);

  $self->_loadPackageTypes();

  my $connection_string = 'DBI:' . $cfg->{db_type} . ':' . $cfg->{database};   # e.g. DBI:ODBC:BTData_PROD_SQLEXPRESS

  # Get Next package id
  # TODO: delete?
  #  $sql = 'select next_batch_id from TTY_Next_ID';
  #  $sth = $self->dbh->prepare($sql) || die "\nERROR: failed to prepare statement. SQL: $sql";
  #  $sth->execute()               || die "\nERROR: failed to get next batch ID. SQL: $sql";
  #  my $nextid = ($sth->fetchrow_array);
  my $nextid = 0;

  # TODO: Some of these values only apply to BlackThorne
  # Define IND values
  my $ind = {
    A => 'A - Archived sale',
    T => 'T - Tracking number exists',
    P => 'P - Priority shipping requested',
    M => 'M - Multiple orders paid separately',
    E => 'E - E-Check payment possible (no paid_on_date)',
    N => 'N - Notes from buyer exist',
  };

  my $row = 1;
  my ($pkg, $id);
  my %pkg_id;
  my $location_map = {};

  # TODO: this should be using the ODBC connection specified in the shipit.ini file
  #DBI->connect( "DBI:ODBC:BTData_PROD_SQLEXPRESS",
  my $dbhpl = DBI->connect( $connection_string,
                'shipit',
                'shipit',
                { 
                  RaiseError       => 1, 
                  AutoCommit       => 1, 
                  FetchHashKeyName => 'NAME_lc',
                  LongReadLen      => 32768,
                } 
              )
  || die "\n\nDatabase connection not made: $DBI::errstr\n\n";

  # SQL - Prepare Insert to PickList table
  #
  # my $sthpl = $dbhpl->prepare( 'insert into picklist_test (location, image_url, quantity, title, variation, di_flag) values (?,?,?,?,?,?)') or die "can't prepare stmt";
  my $sthpl = $dbhpl->prepare( 'insert into picklist (location, image_url, quantity, title, variation, di_flag, sku, item_picked) values (?,?,?,?,?,?,?,0)') 
                  or die "can't prepare stmt";

  # Truncate existing PickList table
  # $dbhpl->do( 'truncate table picklist_test' ) or die "can't execute stmt";
  $dbhpl->do( 'truncate table picklist' ) or die "can't execute stmt";

  # Load the locations data
  #
  # and create location and packaging lookup
  eval {
#     $sth = $dbhpl->prepare( 'select title,variation,location,packaging,bubblewrap,packaged_weight from tty_storagelocation where title is not null and active=1' ) 
    $sth = $dbhpl->prepare( 'select title,variation,location,packaging,bubblewrap,packaged_weight,sku from Inventory where title is not null and active=1' ) 
      or die "can't prepare sql to get location data";
    $sth->execute() or die "can't execute sql to get location data";
  };
  if ($@) {
    die "\n\nERROR: $@";
  }

  my $all_locations = $sth->fetchall_arrayref();

  for my $r ( @$all_locations ) {
    my $t = $r->[0];                    # Title
    my $v = $r->[1] ? $r->[1] : ' ';    # Variation

    # TODO: Probably can clean this up. At some point I needed to clean up the titles in order for them to match. 
#      $t =~ s/^\s+//;
#      $t =~ s/\s+$//;
#      $t =~ s/\&/&amp;/g;
#      $v =~ s/\&/&amp;/g;

    $location_map->{ $t }->{ $v }->{location} = $r->[2]; 
    $location_map->{ $t }->{ $v }->{packaging} = $r->[3]; 
    $location_map->{ $t }->{ $v }->{bubble_wrap} = $r->[4]; 
    $location_map->{ $t }->{ $v }->{packaged_weight} = $r->[5]; 
    $location_map->{ $t }->{ $v }->{SKU} = $r->[6]; 
  }

  # Get the list of packages
  my $results_hashref = {};
  if ( $cfg->{db_dbms} =~ /^api$/i ) {   
    ################################################################################  
    #  Get EBAY Orders 
    #    TODO: get Amazon orders and Ebay orders from other accounts
    ################################################################################ 

    # Ebay API call - Get Orders awaiting shipment
    my $objOrders = ShipItEbayAPICallGetOrders->new( environment=>'production' );
    $objOrders->sendRequest;

    # Build the $results_hashref hash
    for my $o ( @{ $objOrders->orders } ) {
      for my $i ( @{$o->{TransactionArray}->{Transaction}} ) {
        my $all_shippingAddressIds = {};

        die "ERROR: transactionID not defined",Dumper($o) if ( ! $i->{TransactionID} ) ;

        my $h = $results_hashref->{ $i->{TransactionID} } = {};   # get txn id from current record

        my($fname,$lname) = $o->{ShippingAddress}->{Name} =~ /([^\s]+?)\s+(.*)/;
        $fname = $fname ? $fname : $o->{ShippingAddress}->{Name};

        $h->{ebayuserid}   = $o->{BuyerUserID};
        $h->{firstname}    = $fname;
        $h->{lastname}     = $lname;
        $h->{emailaddress} = $o->{Buyer}->{Email};
        $h->{phonenumber}  = $o->{ShippingAddress}->{Phone};
        $h->{company}      = $o->{ShippingAddress}->{Company};
        $h->{addressline1} = $o->{ShippingAddress}->{Street1};
        $h->{addressline2} = $o->{ShippingAddress}->{Street2};
        $h->{addressline3} = $o->{ShippingAddress}->{Street3};
        $h->{city}         = $o->{ShippingAddress}->{CityName};
        $h->{state}        = $o->{ShippingAddress}->{StateOrProvince} || ' ';
        $h->{zipbefore}    = '';
        $h->{zip}          = $o->{ShippingAddress}->{PostalCode};
        $h->{countryname}  = $o->{ShippingAddress}->{CountryName};
        $h->{country}      = $o->{ShippingAddress}->{Country};
        $h->{ebayOrderID}  = $o->{OrderID};
        $h->{paid_on_date} = substr($o->{PaidTime},0,10);

        # NOTE: For U.S. Territories, the USPS requires shippers to use the two-character 
        #       abbreviation for the state/region and United States for the country.
        #
        # REFERENCE: 
        #   https://help.shipstation.com/hc/en-us/articles/206640527-What-is-the-address-format-needed-when-shipping-to-Puerto-Rico-and-other-US-Territories-
        #
        if ( $h->{countryname} =~ /American Samoa/i ) {
          $h->{state}        = 'AS';
          $h->{country}      = 'US';
          $h->{countryname}  = 'United States';
        }
        elsif ( $h->{countryname} =~ /Guam/i ) {
          $h->{state}        = 'GU';
          $h->{country}      = 'US';
          $h->{countryname}  = 'United States';
        }
        elsif ( $h->{countryname} =~ /Northern Mariana Islands/i ) {
          $h->{state}        = 'MP';
          $h->{country}      = 'US';
          $h->{countryname}  = 'United States';
        }
        elsif ( $h->{countryname} =~ /Puerto Rico/i ) {
          $h->{state}        = 'PR';
          $h->{country}      = 'US';
          $h->{countryname}  = 'United States';
        }
        elsif ( $h->{countryname} =~ /.*Virgin Island.*/i ) {
          $h->{state}        = 'VI';
          $h->{country}      = 'US';
          $h->{countryname}  = 'United States';
        }

        $h->{shippingcharged} = $i->{ActualShippingCost}->{content} || '0';   # TODO: divide by total number of items?

        $h->{shippingaddress} = lc("$h->{addressline1} $h->{addressline2} $h->{city} $h->{state} $h->{zip} $h->{countryname}");
        $h->{shippingaddressid} = $h->{shippingaddress};

        $all_shippingAddressIds->{ $h->{shippingaddress} }++;

        $h->{archived_flag}           = '';
        $h->{trackingnum_exists_flag} = '';
        $h->{ship_priority_flag}      = $o->{ShippingServiceSelected} =~ /.*priority.*/i ? 'P' : '';
        $h->{echeck_flag}             = $h->{paid_on_date} ? '' : 'E';
        $h->{customercheckoutnotes}   = '';
        $h->{customercheckoutnotes}   = $o->{BuyerCheckoutMessage} if (defined $o->{BuyerCheckoutMessage});
        $h->{customercheckoutnotes}   .= $o->{NotestoYourself}     if (defined $o->{NotestoYourself});
        $h->{notes_flag}              = $h->{customercheckoutnotes} ? 'N' : '';
        $h->{mult_order_id_flag}      = (defined $all_shippingAddressIds->{ $h->{shippingaddress} } and 
                                        $all_shippingAddressIds->{ $h->{shippingaddress} } > 1) ? 'M' : '';

        if ( $h->{echeck_flag} eq 'E' ) {
          print Dumper($o),"\n",Dumper($h); exit;
        }

        $h->{qtysold}       = $i->{QuantityPurchased};
        $h->{item_price}    = $i->{TransactionPrice}->{content};

        # TODO: Set US territories and military destinations to 'D' for domestic
        $h->{dom_intl_flag} 
           = ( $h->{countryname} =~ /^(U.?S.?)|(United States)|(Puerto Rico)|(Virgin Islands \(U.?S.?\))|(Guam)\*$/i ) ? 'D' : 'I';
#          = ($h->{countryname} =~ /^(United States)|(Puerto Rico)|(Virgin Islands \(U.S.\))|(Guam)\*$/i or $h->{state}   =~ /(^AA$)|(^AE$)|(^AP$)/i) ? 'D' : 'I';

        $h->{ebayitemid}        = $i->{Item}->{ItemID};
        $h->{ebaysaleid}        = '';                      # TODO: $o->{SalesRecordNumber};  Not needed?
        $h->{ebaytransactionid} = $i->{TransactionID};

        $h->{primarypicture}  = $i->{GalleryURL} || 'http://www.amysepelis.com/ebay_images/missing.png';

        $h->{title}             = $i->{Item}->{Title};
        if ( $h->{title} =~ /.*\]$/ ) {
          $h->{variation} = $h->{title};
          $h->{variation} =~ s/^.*\[(.*?)\]$/$1/;
          $h->{title}     =~ s/\s*\[.*?\]$//; 
          #$h->{variation}         =~ s/"/''/g;
        }
        else {
          # TODO: does this cause a problem matching to value on table (I don't think we store a space there)
          $h->{variation}         = ' ';
        }

        $h->{variationxmlkey}   = $h->{variation};

        # Fix weird characters
        for my $fieldname ( qw(firstname lastname company address addressline1 addressline2 addressline3 city state countryname) )
        {
          # TODO: need full list of characters to fix OR find a module that will fix them all
          $h->{$fieldname} =~ s/&amp;#7;//g  if ( defined $h->{$fieldname} );    # bell?
        }

      } # end of transaction loop
    } # end orders loop

  } # END db_dbms=/api/ (Ebay API get orders)


  ################################################################################
  #
  # Loop over items returned (each row is an item in a package)
  #
  ################################################################################
  my $pick_list = {};
  for my $row_key ( keys %{$results_hashref} ) {
    my $r = $results_hashref->{$row_key};
		my $address;
    my $pkg_pk = $r->{ebayuserid} . $r->{shippingaddressid};     # Unique identifier for a package 

    if ( ! defined $pkg_id{$pkg_pk} ) {
      # New package
      $pkg_id{$pkg_pk} = $nextid++;               # Assign new id, increment id for the next new package
    }
    $id = sprintf('LIN%05d', $pkg_id{$pkg_pk});    # LIN prefix for "LinnWorks"
    $pkg = $self->packages->{$id}; 

    # NEW PACKAGE
    if ( ! defined $self->packages->{$id} ) {
      $self->packages->{$id} = ShipItPackage->new();
      $pkg = $self->packages->{$id}; 

      map { $r->{$_} = '' unless defined $r->{$_} } keys %$r;     # Assign defaults if undefined

      eval {
        $pkg->id           ( $id                               );
        $pkg->ebayuserid   ( $r->{ebayuserid}                  );
        $pkg->firstname    ( $r->{firstname} || ' '            );   
        $pkg->lastname     ( $r->{lastname}  || ' '            );   
        $pkg->buyer        ( "$r->{lastname}, $r->{firstname}" );
  #      $pkg->buyer        ( $r->{firstname} );
        $pkg->company      ( $r->{company}                     );
        $pkg->addressline1 ( $r->{addressline1}                );
        $pkg->addressline2 ( $r->{addressline2}                ) if $r->{addressline2};
        $pkg->addressline3 ( $r->{addressline3}                ) if $r->{addressline3};
        $pkg->city         ( $r->{city}                        );
        $pkg->state        ( $r->{state} || ' '                );
        $pkg->zip          ( $r->{zip}                         );
        $pkg->countryname  ( $r->{countryname}                 );
        $pkg->country      ( $r->{country}                     );
        $address           = "$r->{addressline1}\n";
        $address          .= "$r->{addressline2}\n"   if $r->{addressline2};
        $address          .= "$r->{addressline3}\n"   if $r->{addressline3};
        $address          .= "$r->{city} $r->{state}, $r->{zip}\n";
        $address          .= "$r->{countryname}";
        $pkg->address      ( $address );
        $pkg->status_type  ( 'info' );
        $pkg->total_weight_oz( 0 );
        $pkg->weight_oz    ( 0 );
        $pkg->weight_lbs   ( 0 );
        $pkg->total_items  ( 0 );
        $pkg->total_price  ( 0.00 );
        $pkg->shipping_cost( 0.00 );
        $pkg->mailclass    ('');                         # NOTE: Used to override defaults only, however it could be
        $pkg->mailpiece    ('');                         #       changed, so that a default value was put in here
        $pkg->dom_intl_flag( $r->{dom_intl_flag} );
        $pkg->emailaddress ( $r->{emailaddress});
      };
      if ($@) {
        print "\n\nID: $id\n\n",Dumper($r);
        die "ERROR: $@ \nRECORD: ",Dumper($r);
      }

      my $phonenumber;
      $phonenumber = $r->{phonenumber} || '0000';
      $pkg->phonenumber  ( $phonenumber );

	    $pkg->status       ( 'S' );                      # Staged

	    $pkg->customercheckoutnotes   ( $r->{customercheckoutnotes}   );
      $pkg->archived_flag           ( $r->{archived_flag}           );
      $pkg->trackingnum_exists_flag ( $r->{trackingnum_exists_flag} );
      $pkg->ship_priority_flag      ( $r->{ship_priority_flag}      );
      $pkg->mult_order_id_flag      ( $r->{mult_order_id_flag}      );
      $pkg->echeck_flag             ( $r->{echeck_flag}             );
      $pkg->notes_flag              ( $r->{notes_flag}              );
    }
    else {
      # Get the checkout notes from each item
      $pkg->customercheckoutnotes( $pkg->customercheckoutnotes . "\n" . $r->{customercheckoutnotes} )
        if ( $r->{customercheckoutnotes} && $pkg->customercheckoutnotes ne $r->{customercheckoutnotes});
    }

    # Get correct image for this Item
    my $picture;
    if ( !defined $picture || scalar($picture) =~ /.*(ARRAY|HASH).*/ ) { 
      $picture = $r->{primarypicture};
    }

    # TODO: this is a fix... not sure how some pics are getting joined together with a 
    if ( $picture =~ /.*;.*/ ) { 
      print Dumper($r); 
    }

    # TODO: for testing
    if ( ! $r->{ebayitemid} ) {
      print "ERROR: NO EbayItemID",Dumper($r); exit;
    }

    ##
    ## GET ITEM LOCATION IF IT EXISTS
    ##
    my $item_location;
    my ( $packaging, $bubble_wrap, $packaged_weight, $sku );
    my $pl_title =  $r->{title};
    $pl_title =~ s/\[.*?\]$//;
    my $pl_variation = $r->{variationxmlkey} || ' ';
    if ( defined  $location_map->{ $pl_title }->{ "$pl_variation" } ) {
      $item_location =  $location_map->{ $pl_title }->{ "$pl_variation" }->{location} || ' ';
      $packaging = $location_map->{ $pl_title }->{ "$pl_variation" }->{packaging};
      $bubble_wrap = $location_map->{ $pl_title }->{ "$pl_variation" }->{bubble_wrap};
      $packaged_weight = $location_map->{ $pl_title }->{ "$pl_variation" }->{packaged_weight};
      $sku = $location_map->{ $pl_title }->{ "$pl_variation" }->{SKU};
    }

    # add item to pick list
    $pick_list->{ $pkg->dom_intl_flag }->{ $item_location }{ $pl_title }->{ $pl_variation }->{QTY} += $r->{qtysold};
    $pick_list->{ $pkg->dom_intl_flag }->{ $item_location }{ $pl_title }->{ $pl_variation }->{IMG} = $picture;      
    $pick_list->{ $pkg->dom_intl_flag }->{ $item_location }{ $pl_title }->{ $pl_variation }->{SKU} = $sku;      

    # Build array of items in package
    my $item;
    eval {
    $item = ShipItItem->new( ebayItemID         => $r->{ebayitemid},
                             ebayTransactionID  => $r->{ebaytransactionid},
                             qtysold            => $r->{qtysold}, 
                             price              => $r->{item_price}, 
                             title              => $r->{title},
                             variation          => $r->{variationxmlkey},
                             paid_on_date       => $r->{paid_on_date},
                             indstr             => '',
                             ship_priority_flag => $r->{ship_priority_flag},
                             status             => '',
                             image_url          => $picture,
                             location           => $item_location,
                             packaging          => $packaging,
                             bubble_wrap        => $bubble_wrap,
                             packaged_weight    => $packaged_weight,
                            );
    };
    if ($@) {
      # TODO: maybe can take this out...
      print "\n\nERROR ON PICTURE: ",Dumper($picture);
      print "\nscalar pic: ",scalar($picture);
      print "\n\n";
      die $@;
    }

    push( @{$pkg->{items}}, $item );

    $pkg->total_items  ( $pkg->total_items + $item->qtysold );
    $pkg->total_price  ( $pkg->total_price + ($item->price * $item->qtysold) );

    # Each line can have mult ind's
    for my $i ( sort ($r->{archived_flag}, $r->{trackingnum_exists_flag}, $r->{ship_priority_flag}, $r->{mult_order_id_flag}, $r->{echeck_flag}, $r->{notes_flag} ) ) {
      $pkg->indhash->{$i} = 1 
        if $i;
    }

    $item->indstr( join('',keys %{ $pkg->indhash }) );

  } # end while fetchrow

  # TODO: delete?
  # Update Next package id in the table
#  $sql = "update TTY_Next_ID set next_batch_id=$nextid";
#  $sth = $self->dbh->do($sql) || die "\nERROR: failed to execute update statement. SQL: $sql";

  # Loop through all packages (sorted by buyer)
	for my $id  ( sort { $self->packages->{$a}->firstname . $self->packages->{$a}->lastname 
					       cmp   $self->packages->{$b}->firstname . $self->packages->{$b}->lastname }  
								keys   %{$self->packages} ) {

    # current package
		my $pkg = $self->packages->{$id};

    # process all indicators, build up 'Notes' field
		my ($indstr,$notes) = ('','');
    for my $i ( sort keys %{$pkg->indhash} ) {
      $indstr .= $i;
      $notes  .= "$ind->{$i}\n"; 
    }

    $pkg->notes  ( $notes  ) if $notes; 
    $pkg->notes  ( $pkg->notes . $pkg->customercheckoutnotes );
    if ( $indstr ) {
      $pkg->indstr ( $indstr );
      # TODO: I feel like we should still give a warning if we get one of these flags
      # $pkg->notes  ( $pkg->notes . "\nWarning Flags: " . $indstr );
    }

    # Set attribute packages_ary
		push( @{$self->packages_ary}, $pkg );

    # Set attribute packages_byID
    $self->packages_byID->{ $pkg->id } = $pkg;

    # TODO: still needs to be fixed as of 2015/04/04 !!!
    # Fix foreign characters (unicode/UTF8)
    for my $unicode_field ( qw(firstname lastname company address addressline1 addressline2 addressline3 city state countryname buyer notes) )
    {
    #  print "\nB:",$pkg->$unicode_field;
      my $fix = $pkg->$unicode_field;
      utf8::decode($fix);
      $fix =~ s/&amp;#7;//g;
      $pkg->$unicode_field( $fix );

      # clean up wierd characters (this is coming from eBay, as near as I can tell...)
      #my $f  = XML::Entities::decode('all', $pkg->$unicode_field);
      #my $f2 = XML::Entities::decode('all', $f);
      #$pkg->$unicode_field( $f2 );

    #  print "\nF: $f";
    #  print "\n2: $f2";
    #  print "\nA: ",$pkg->$unicode_field;

      $pkg->$unicode_field( unidecode($pkg->$unicode_field) );

    #  print "\nU: ",$pkg->$unicode_field,"\n";

      # TODO: Shouldn't have to do this anymore because we are using XML::Simple::XMLout() !
#      # Fix character with special meaning in XML
#      $pkg->{$unicode_field} =~ s/&/&amp;/mg;
#      $pkg->{$unicode_field} =~ s/</&lt;/mg;
#      $pkg->{$unicode_field} =~ s/>/&gt;/mg;
#      $pkg->{$unicode_field} =~ s/"/&quot;/mg;
#      $pkg->{$unicode_field} =~ s/'/&#39;/mg
    }
    
	}

  #
  # PickList
  #
  for my $diflag ( keys %$pick_list ) {

    # TODO: Now that we have the PickList app, there's really no need to create the .xls file

    # open file
    my $picklist =  "$cfg->{pick_list_filebase}_$diflag.xls";

    my $wb;
    TESTOPEN:
    eval {
       $wb = Spreadsheet::WriteExcel->new( $picklist ) or die;
    };
    if ($@) {
      my $msgbox = Wx::MessageDialog->new( $parent_window, "You must close '$picklist' before continuing!" , 'WARNING', wxOK|wxICON_EXCLAMATION );
      $msgbox->ShowModal();
      goto TESTOPEN
    }

    my $ws = $wb->add_worksheet();
    $ws->set_landscape();
    $ws->set_margins(.22,.22,.22,.22);
    $ws->fit_to_pages(1, 0);

    
    my $fmt_center = $wb->add_format();
    $fmt_center->set_align('center');

    # Store items by bin/rack location to picklist table
    my $pl = $pick_list->{ $diflag };
    my $row=0;
    my ($maxloc,$maxcnt,$maxtitle,$maxvar) = (0,0,0,0);

    for my $loc ( sort keys %$pl ) {
      for my $title ( sort keys %{$pl->{$loc}} ) {
        for my $var ( sort keys %{$pl->{$loc}->{$title}} ) {
          my $cnt = $pl->{$loc}->{$title}->{$var}->{QTY};

          # TODO: for sizing Excel columns. Remove Excel file altogether.
          $maxloc = length($loc) > $maxloc ? length($loc) : $maxloc;
          $maxcnt = length($cnt) > $maxcnt ? length($cnt) : $maxcnt;
          $maxtitle = length($title) > $maxtitle ? length($title) : $maxtitle;
          $maxvar = length($var) > $maxvar ? length($var) : $maxvar;
          $ws->write($row,0,$loc);
          $ws->write($row,1,$cnt,$fmt_center);
          $ws->write($row,2,$title);
          $ws->write($row,3,$var);

          my $image_url = $pl->{$loc}->{$title}->{$var}->{IMG};
          my $sku = $pl->{$loc}->{$title}->{$var}->{SKU};

          $sthpl->execute( $loc, $image_url, $cnt, $title, $var, $diflag, $sku ) or die "can't update PickList table";

          $row++;
        }
      }
    }

    $ws->set_column('A:A',$maxloc);
    $ws->set_column('B:B',$maxcnt+2);
    $ws->set_column('C:C',$maxtitle);
    $ws->set_column('D:D',$maxvar);

    $wb->close();
  }

} # end load()

sub _loadPackageTypes
{
  my $self = shift;

  my $sql = q/select package+' '+package_type as package_type_name, packageid from ttb_package_types/;
  my $sth;

  eval {
    $sth = $self->dbh->prepare( $sql ) or die "can't prepare sql to get location data";
    $sth->execute() or die "can't execute sql to get location data";
  };
  if ($@) {
    die "\n\nERROR: $@";
  }

  my $all_types = $sth->fetchall_hashref('package_type_name');
  $sth->finish();

  for my $type ( keys %{$all_types} ) {
    $self->{packageTypes}->{$type} = $all_types->{$type}->{packageid};
  }

}


1;
