SELECT
   A.firstname
  ,A.lastname
  ,B.ebayuserid
  ,B.email as emailaddress
  ,B.phone as phonenumber
  ,A.company
  ,A.addressline1
  ,A.addressline2
  ,A.addressline3
  ,A.city
  ,C.zipbefore
  ,A.zip
  ,A.state 
  ,case when (A.state='PR' and A.country='PR')
          or (A.state='VI' and A.country='VI') 
	then 'United States' 
        else C.countryname 
   end as countryname
  ,case when (A.state='PR' and A.country='PR')
          or (A.state='VI' and A.country='VI')
        then 'US' 
        else A.country 
   end as country
  ,S.qtysold
  ,case WHEN cast(S.isarchive as int) > 0   
        THEN char(65) ELSE '' END 
  as archived_flag                             -- A (Archived - The listing (and related sales) were archived before shipped)
  ,case WHEN S.trackingnum <> ''            
        THEN char(84) ELSE '' END 
  as trackingnum_exists_flag                   -- T (Tracking number existing for this record - Already shipped?)
  ,case WHEN S.shippingco like '%priority%' 
        THEN char(80) ELSE '' END 
  as ship_priority_flag                        -- P (Priority mail - buyer selected/paid for priority mail)
  ,case WHEN mult_orders.distinct_orders > 1   
        THEN char(77) ELSE '' END 
  as mult_order_id_flag                        -- M (Multiple order id's / buyer paid separately - update tracking manually in ebay)
  ,case WHEN S.datepaymentcleared is null   
        THEN char(69) ELSE '' END 
  as echeck_flag                               -- E (possible E-Check - no payment cleared date)
  ,case WHEN S.customercheckoutnotes <> ''  
        THEN char(78) ELSE '' END 
  as notes_flag                                -- N (Notes from the customers - check the CustomerCheckoutNotes Report)
  ,S.customercheckoutnotes
  ,upper
  ( 
      case when len(A.company)>0 then A.company else space(1) end 
    + case when len(A.addressline1)>0 then space(1) + A.addressline1 else space(0) end 
    + case when len(A.addressline2)>0 then space(1) + A.addressline2 else space(0) end 
    + case when len(A.addressline3)>0 then space(1) + A.addressline3 else space(0) end 
    + case when len(a.city)>0 
      then space(1) 
        + case when C.zipbefore <> 0 then A.zip + space(1) else space(0) end  
        + A.city 
        + space(1)
        + A.state 
        + case when upper(isnull(C.countryname,space(1))) in ('UNITED KINGDOM','GREAT BRITAIN') 
              then space(1) else space(2) end  
        + case when C.zipbefore <> 0 then space(1) else A.zip end 
      else space(0) 
      end  
    + case when len(A.country)>0 and upper(A.country)<>upper(ST.countryid) 
      then space(1) + isnull(C.countryname, space(0)) else space(0) end
  ) as shipping_address
  ,S.saleprice as item_price
  ,convert(varchar, S.datepaymentreceived, 101) as paid_on_date
  ,case when upper(A.country) in ('US','PR','AA','GU', 'VI') then 'D'   -- Domestic package destination
        else                                                'I'   -- International package destination
    end as dom_intl_flag
  ,S.title
  ,S.variationskuname as variation
  ,S.variationSpecifics as variationXMLKey
  ,L.VariationPicturesHostURLS as variationsXML
  ,P.Pic1Loc as primaryPicture
  ,S.shippingaddressid
  ,S.shippingcharged
  ,S.orderid       as ebayOrderID
  ,S.ebayid        as ebayItemID
  ,S.saleid        as ebaySaleID
  ,S.transactionid as ebayTransactionID
FROM SALES S
  LEFT JOIN BUYERS    B          ON B.BUYERID = S.BUYERID 
  LEFT JOIN LISTINGS  L          ON S.LISTINGID = L.LISTINGID  
  LEFT JOIN SHIPDESTTEMPLATES ST ON L.SHIPDESTTEMPLATEID = ST.SHIPDESTTEMPLATEID  
  LEFT JOIN ADDRESSES A          ON S.SHIPPINGADDRESSID = A.ADDRESSID   -- where the package is being shipped to
--  LEFT JOIN ADDRESSES A1         ON S.BILLINGADDRESSID = A1.ADDRESSID   -- buyers billing address
  LEFT JOIN COUNTRIES C          ON A.COUNTRY = C.COUNTRYCODE
  LEFT JOIN PICTURES P           ON L.PicURLID = P.PictureID
  LEFT JOIN 
            (select a.buyerid, a.shippingaddressid, count(*) as distinct_orders
               from   (select distinct b.buyerid, s.shippingaddressid, s.orderid
                         from buyers b left join sales s on b.buyerid = s.buyerid
                        where s.statusid=15) a 
              group by a.buyerid, a.shippingaddressid having count(*)>1
            ) MULT_ORDERS 
            ON S.buyerid = MULT_ORDERS.buyerid and 
               S.shippingaddressid = MULT_ORDERS.shippingaddressid
WHERE S.STATUSID = 15
ORDER BY A.firstname, A.lastname
