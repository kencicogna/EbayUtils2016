SELECT
   firstname
  ,lastname
  ,ebayuserid
  ,emailaddress
  ,phonenumber
  ,company
  ,addressline1
  ,addressline2
  ,addressline3
  ,city
  ,zipbefore
  ,zip
  ,state 
  ,countryname
  ,country
  ,qtysold
  ,archived_flag                             -- A (Archived - The listing (and related sales) were archived before shipped)
  ,trackingnum_exists_flag                   -- T (Tracking number existing for this record - Already shipped?)
  ,ship_priority_flag                        -- P (Priority mail - buyer selected/paid for priority mail)
  ,mult_order_id_flag                        -- M (Multiple order id's / buyer paid separately - update tracking manually in ebay)
  ,notes_flag                                -- N (Notes from the customers - check the CustomerCheckoutNotes Report)
  ,shipping_address
  ,item_price
  ,paid_on_date
  ,dom_intl_flag
  ,title
  ,variation
  ,shippingaddressid
  ,shippingcharged
  ,ebay_order_id
  ,ebay_item_id
  ,ebay_sale_id
  ,ebay_transaction_id
FROM tty_package
;
