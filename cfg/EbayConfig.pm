package EbayConfig;
#
# ES - Ebay Setup
#

use HTTP::Headers;

our $ES_compatibility_level = '965';

our $ES_http_header = HTTP::Headers->new;
$ES_http_header->push_header('X-EBAY-API-COMPATIBILITY-LEVEL' => $ES_compatibility_level );
$ES_http_header->push_header('X-EBAY-API-DEV-NAME'  => 'd57759d2-efb7-481d-9e76-c6fa263405ea');
$ES_http_header->push_header('X-EBAY-API-APP-NAME'  => 'KenCicog-a670-43d6-ae0e-508a227f6008');
$ES_http_header->push_header('X-EBAY-API-CERT-NAME' => '8fa915b9-d806-45ef-ad4b-0fe22166b61e');
$ES_http_header->push_header('X-EBAY-API-CALL-NAME' => '__API_CALL_NAME__');
$ES_http_header->push_header('X-EBAY-API-SITEID'    => '0'); # usa
$ES_http_header->push_header('Content-Type'         => 'text/xml');

our $ES_eBayAuthToken = 'AgAAAA**AQAAAA**aAAAAA**V4qTVw**nY+sHZ2PrBmdj6wVnY+sEZ2PrA2dj6wHlIKoCZCBogmdj6x9nY+seQ**4EwAAA**AAMAAA**je5Z/K9tCMgE7ket3dY7hCsrwke2TWRJGyn453db9lJCn5uNa1OlmZFIsjq0rhfIJIw1/1kN5yJWS7Q+egsS8ramLyIFF9kfdi6snBEE7mRtqUn4pOFgh4QbcTRe2djP9Zts5ssHf8/JWL3E1l/8lESolBWsqml4NLpgUF99qnsM+S7uvlrHXqVt/d0fdQgE9dKL+cVH0H5gqP0YC+VaBbpr9e+KRzwqWRY85CrLQHMtXRAczUZ/mJew87B4g++wC20VhFOkiPExLk55cFt0hBwIqo9Q5Y077MXQmscTzMBqM/aeBBxFByoQtxC0CswLSkTShFLo5GFz6747rMC4oSvpeoM1iqcsfzgYrX3eZoATwIBAnileDOo6Z4/LegWEf8zQxed36i9mv0yIiEPjW0gOh3qiUadapahkuFgllUi2gtWMeshRgwNk44SdrPkMbgVDq4EJPZKQ8N1KbLp5X+nL8OasRZ0BpQyjSFXuRKGf3dK3tz0PMiaZ8DHOJnxA4yVv97LaB4QLm/33HW3KOWDnvQ1UhUEnzdzPNitrW13UpPwV3vTKsE3N03Jv669mI2rAfZU0jTFztLEIC//3Y7OmeTzD9kdW5C88q5+COAA5mqWsfWbN7MC7ftgcYB+gEMGlv0ngr4JFkzo/pl4pX2jT53zDkfMRt/V0IRPJySm3DsPNbUEUI/PXsDqi9wETTt/W0ihguent5NOntus+mK3rbmV/jUoVSY7jE1Z2TmQE7avsamEwwyMYarfoT4cA';


1;
