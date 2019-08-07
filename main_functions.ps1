
$zoopla_key = "secret - obtain from https://developer.zoopla.co.uk/ and replace this string"


function invoke-zooplaApi
{
    <#  Create by Gidon Marcus to get zoopla data via the API, exemple: 
        (invoke-zooplaApi -zoopla_url "http://api.zoopla.co.uk/api/v1/" -zoopla_key "$zoopla_key" -zoopla_api_name "property_listings" -zoopla_q_array @{area = "london";page_size=1}).response.listing
        note: we do not manage the pages as part of the function as there is query quota. we have it managed later in the execution
    #>
    param([string]$zoopla_url,[string]$zoopla_api_name,[string]$zoopla_key,$zoopla_q_array)
    $zoopla_q_array_formatted = [string](($zoopla_q_array.keys | % {"&"+ $_ + "=" + $zoopla_q_array.$_}) -join "")
    $zoopla_invoke_full_url = ([string]($zoopla_url + $zoopla_api_name + ".xml?api_key=" + $zoopla_key + $zoopla_q_array_formatted))
    [xml]((Invoke-WebRequest $zoopla_invoke_full_url).content)
}

function get-nearest_postcode
{
    <#Create by Gidon Marcus to get post code from GPS coordinates, example: 
        (get-nearest_postcode -longitude (-0.188322) -latitude (51.42409)).postcode
    #>
    param([float]$latitude,[float]$longitude)
    ((Invoke-WebRequest ([string]("https://api.postcodes.io/postcodes?lon=" + $longitude + "&lat=" + $latitude))).content | ConvertFrom-Json).result | sort distance | select -First 1
}

function get-HM_data_per_postcode
{
    <#Create by Gidon Marcus to HMRC data from postcode, example: 
        get-HM_data_per_postcode -postcode "nw1 1ls"
    #>
    param([string]$postcode)
    $HM_items = $null
    $HM_page = ([string]("http://landregistry.data.gov.uk/data/ppi/transaction-record.json?_page=0&propertyAddress.postcode=" + $postcode.ToUpper()))
    while($HM_page)
    {
        $HM_json_data = ((Invoke-WebRequest $HM_page).Content| ConvertFrom-Json).result
        $HM_page = $HM_json_data.next
        $HM_items += $HM_json_data.items
    }
    $HM_items
}

$zoopla_q_array = 
@{
    area = "london"
    page_size = 100 # max 100.
    order_by = "price" # "price" (default) or "age" of listing.
    ordering = "ascending" # "descending" (default) or "ascending".
    listing_status = "sale" # "sale" or "rent".
    minimum_price  = 150000  #in GBP. When listing_status is "sale" this refers to the sale price and when listing_status is "rent" it refers to the per-week price.
    maximum_price = 320000	#Maximum price for the property, in GBP. See above
}
$zoopla_url = "http://api.zoopla.co.uk/api/v1/"
$zoopla_api_name = "property_listings"
$working_dataset = $null
$number_of_pages = 1..99
$number_of_pages | % {
    $_
    $zoopla_q_array.page_number = $_
    $zoopla_output = invoke-zooplaApi -zoopla_url $zoopla_url -zoopla_key $zoopla_key -zoopla_api_name $zoopla_api_name -zoopla_q_array $zoopla_q_array
    $working_dataset += $zoopla_output.response.listing
}
#save the dataset so we don't need to query it again and waste resources
$working_dataset  | Export-Clixml ("C:\temp\api\export_area_" + $zoopla_q_array.area + "_total_hits_" + $zoopla_output.response.result_count +"_last_page_" + $zoopla_q_array.page_number + "_max_price_" + $zoopla_q_array.maximum_price + ".xml")

#filtering with the dataset:
$filtered_dataset = $working_dataset  | ? {([int]($_.price) -gt 0) -and ($_.price_change.price | %{[int]$_})  -cgt ([int]($_.price)  + 70000)} 

#Adding exact postcode to the filtered dataset
$filtered_dataset | % {
    $neerst_postcode_data = get-nearest_postcode -longitude $_.longitude -latitude $_.latitude
    $_ | 
    Add-Member -MemberType NoteProperty -Name neerst_postcode -Value $neerst_postcode_data.postcode -Force -PassThru |
    Add-Member -MemberType NoteProperty -Name neerst_postcode_disatance -Value $neerst_postcode_data.distance -Force
} 

#print all the attributes for one property (used to look for relevant ones for the next line)
$filtered_dataset  | select -Last 1 *

#select interesting  attributes
$selected_atr_dataset = $filtered_dataset | select property_type,displayable_address,category,num_bedrooms,status,neerst_postcode,neerst_postcode_disatance,details_url  -ExpandProperty price_change 

#print to screen
$selected_atr_dataset | ft

#print to html and open
$selected_atr_dataset | ConvertTo-Html -Fragment -Property neerst_postcode,neerst_postcode_disatance,property_type,displayable_address,category,num_bedrooms,date,price,percent,status,details_url| Out-File c:\gidi\html.html
 c:\gidi\html.html

 #open all selected properties in a browser
$selected_atr_dataset | select  -Unique details_url | select -Skip 4 |% {. "C:\Program Files (x86)\Mozilla Firefox\firefox.exe" $_.details_url}

#select a house and play with HM data - this was never embedded as part of the main dataset like we did with the post code, as it was not reliable
$selected_house  = ($filtered_dataset | ? displayable_address -Match "Baldry" | select -First 1)
$HM_data_selected_house = get-HM_data_per_postcode -postcode $selected_house.neerst_postcode
$HM_data_selected_house | ? {$_.propertyAddress.paon-match 2} | select pricepaid,newbuild,transactionDate -ExpandProperty propertyAddress | sort _about,transactionDate| ft pricepaid,newbuild,transactionDate,street,paon,saon


#some tests on postcode_properties API - it never worked - missing argument????
<# 
$zoopla_sessionid =  (invoke-zooplaApi -zoopla_url "http://api.zoopla.co.uk/api/v1/" -zoopla_key "$zoopla_key" -zoopla_api_name "get_session_id").response
$prp = (invoke-zooplaApi -zoopla_url "http://api.zoopla.co.uk/api/v1/" -zoopla_key "$zoopla_key" -zoopla_api_name "postcode_properties" -zoopla_q_array @{postcode = $selected_house.neerst_postcode;page_size=100;}).response.agent

 $prp |%{

(invoke-zooplaApi -zoopla_url "http://api.zoopla.co.uk/api/v1/" -zoopla_key "$zoopla_key" -zoopla_api_name "refine_estimate" -zoopla_q_array @{
session_id  = $zoopla_sessionid.session_id
property_id = $_.property_id
property_type  =$selected_house.property_type
num_bedrooms = $selected_house.num_bedrooms
num_bathrooms = $selected_house.num_bathrooms
num_receptions = $selected_house.num_recepts
tenure = "leasehold"
page_size=100}).response
     }
 (invoke-zooplaApi -zoopla_url "http://api.zoopla.co.uk/api/v1/" -zoopla_key "$zoopla_key" -zoopla_api_name "average_area_sold_price" -zoopla_q_array @{area = $selected_house.neerst_postcode;page_size=1;output_type="outcode"}).response
 (invoke-zooplaApi -zoopla_url "http://api.zoopla.co.uk/api/v1/" -zoopla_key "$zoopla_key" -zoopla_api_name "zed_index" -zoopla_q_array @{area = $selected_house.neerst_postcode;page_size=1;output_type="outcode"}).response

 http://api.zoopla.co.uk/api/v1/average_sold_prices.xml?postcode=NW1+1LS&output_type=county&area_type=streets&api_key=



#>