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

our $ES_eBayAuthToken = 'AgAAAA**AQAAAA**aAAAAA**/89cWg**nY+sHZ2PrBmdj6wVnY+sEZ2PrA2dj6wHlIKoCZCBogmdj6x9nY+seQ**4EwAAA**AAMAAA**Qk4PPbHKGx2DPqAeO0Dumf0k2WyACkgfnG9eeB2Hiobbxd2iZ5n3I/YbPMaYduNN+JXxejyhONith2q9PNpf3ZjX2WHI/v3jkvDp64W/IGwCPSU6H9exrg/1eQECbnqaVEWuI5T+7Zv7M9zyQC9R0wphcJC6dG5R2BC96qQVlJIVzveitGchlx2whXgAWnbz5tZhnsgjsHRrXzUXGoQCbxgsmGrpKKYoSBZLvl2r4gWKFO0/iNOoDBQiLL7q00nI3wDlCODjAu6QtJqgAzRLBjNBX9TGljUP/MQLHG37kFRhSvhGBt7rPjkMaqW/CFar4GtCWP/0rK/8OUFDvGIKjhHWJ8c+UTCMtb1N83MMj+Sm8JvrpACOGKV65yKEzyvFQtG9TmL/OiPuPX7/ouRI2IHRYoJ7RKbC6u9YYtvdRBL7xsjiXbkIMlAeVxv2aeZNhaf4WaXLKCAYC8DQPjX9pE/FiM/D0B3LofIobVO79IQJz61eh1+pF2zBYWQ9bSELZLBXHsRYmPVC6b21tyBTatloDTzddVVRSqVn5eg/pW73Sq5EOmwhBYiKfp8xFkpjCRvP+VDQowetVv7XF733/RBEMUpnhzK1oyr8y5sPzpJ+uGtLzqVmARDKCYcX1xo5B046/QHpiJlxQubac80XweKguowFJP+jOh6MfqRHZtj8TNcS1XHzO3/ZAj9Mt7Wu7TFSlctG557ESJXa/rxehfQKsm3Cc3MHYE9aBPmrrweuGK/n3UMPstxPb+aqXjV/';


1;
