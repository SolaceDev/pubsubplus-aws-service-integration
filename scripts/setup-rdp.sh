#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This script will setup and configure a RDP (Rest Delivery Point) to be used
# for AWS resources integration.
#
## Params: pass these params as environment variables
#    see more details in the help below
#
# Required:
INTEGRATION_NAME="$INTEGRATION_NAME"
# Required:
INTEGRATION_API_URL="$INTEGRATION_API_URL"
# Required:
BROKER_SEMP_URL="$BROKER_SEMP_URL"
# Required:
ADMIN_PASSWORD="$ADMIN_PASSWORD"
# Optional:
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
# Optional:
BROKER_MESSAGE_VPN="${BROKER_MESSAGE_VPN:-default}"
# Optional:
HTTP_AUTH_HEADER_NAME="${HTTP_AUTH_HEADER_NAME:-}"
# Optional:
HTTP_AUTH_TOKEN_VALUE="${HTTP_AUTH_TOKEN_VALUE:-}"
#
# xmllint installed is a pre-requisite
exists()
{
  command -v "$1" >/dev/null 2>&1
}
if ! exists xmllint; then
  echo 'xmllint not found on the PATH'
  echo '	Please install xmllint (you can get it e.g. from installing package libxml2-utils)'
  echo '	Or if you have already installed it, add it to the PATH shell variable'
  echo "	Current PATH: ${PATH}"
  exit 1
fi
#
# Provide help if needed
if [ "$#" -gt  "0" ] ; then
  if [ "$1" = "-h" ] || [ "$1" = "--help" ] ; then
    echo "Usage (define variables to be used for the script first in one command, like this):
    INTEGRATION_NAME=<name to be used to identify this AWS resource integration> \\
    INTEGRATION_API_URL=<the full URL to the API in the API Gateway. Example: https://fcxc1lcnsk.execute-api.eu-west-1.amazonaws.com/DEVELOPMENT/send> \\
    BROKER_SEMP_URL=<the full management access URL for the event broker to be configured. Example: http://34.23.45.23:8080> \\
    ADMIN_PASSWORD=<the management admin user password> \\
    [ADMIN_USERNAME=<the management admin username, default is 'admin'>] \\
    [BROKER_MESSAGE_VPN=<the message VPN to setup, default is 'default'>] \\
    [HTTP_AUTH_HEADER_NAME=<for public integration, the HTTP Authorization Header name>] \\
    [HTTP_AUTH_TOKEN_VALUE=<for public integration, the HTTP Authorization Token value>] \\
    setup_rdp.sh
    
    Check script inline comments for more details."
    exit 1
  else
    echo "Requires argument(s), check -h or --help"
    exit 1
  fi
fi
#
# Check for minimum params
if [[ -z "$INTEGRATION_NAME" ]]; then
	>&2 echo "INTEGRATION_NAME must be defined, see -h for help"
	exit 1
fi
if [[ -z "$INTEGRATION_API_URL" ]]; then
	>&2 echo "INTEGRATION_API_URL must be defined, see -h for help"
	exit 1
fi
if [[ -z "$BROKER_SEMP_URL" ]]; then
	>&2 echo "BROKER_SEMP_URL must be defined, see -h for help"
	exit 1
fi
if [[ -z "$ADMIN_PASSWORD" ]]; then
	>&2 echo "ADMIN_PASSWORD must be defined, see -h for help"
	exit 1
fi
echo "Using:"
echo "INTEGRATION_NAME=$INTEGRATION_NAME"
echo "INTEGRATION_API_URL=$INTEGRATION_API_URL"
echo "BROKER_SEMP_URL=$BROKER_SEMP_URL"
echo "ADMIN_PASSWORD=$ADMIN_PASSWORD"
echo "ADMIN_USERNAME=$ADMIN_USERNAME"
echo "BROKER_MESSAGE_VPN=$BROKER_MESSAGE_VPN"
echo "HTTP_AUTH_HEADER_NAME=$HTTP_AUTH_HEADER_NAME"
echo "HTTP_AUTH_TOKEN_VALUE=$HTTP_AUTH_TOKEN_VALUE"
echo "#############################################################"
echo
#
# Analyse API URL - example: https://fcxc1lcnsk.execute-api.eu-west-1.amazonaws.com/DEVELOPMENT/send
IFS='/' read -r protocol empty baseUrl apiStage apiPath <<< "$INTEGRATION_API_URL"
IFS='.' read -r gwId apiRegionUrl <<< "$baseUrl"
#
## Functions
function semp_query {
  # Variables:
  count_search=""
  name=$1
  password=$2
  url=$3
  query=$4
  value_search=$5
  script_name="semp_query"
  verbose=0

  if [[ ${url} = "" || ${name} = "" || ${password} = "" || ${query} = "" ]]; then
    echo "`date` ERROR: url, name, password and query are madatory fields" >&2
    echo  '<returnInfo><errorInfo>missing parameter</errorInfo></returnInfo>'
    exit 1
  fi
  if [ `curl --write-out '%{http_code}' --silent --output /dev/null -u ${name}:${password} ${url} -d "<rpc><show><version/></show></rpc>"` != "200" ] ; then
    echo  "<returnInfo><errorInfo>management host is not responding</errorInfo></returnInfo>"
    exit 1
  fi
  query_response=`curl -sS -u ${name}:${password} ${url} -d "${query}"`
  # Validate first char of response is "<", otherwise no hope of being valid xml
  if [[ ${query_response:0:1} != "<" ]] ; then
    echo  "<returnInfo><errorInfo>no valid xml returned</errorInfo></returnInfo>"
    exit 1
  fi
  query_response_code=`echo $query_response | xmllint -xpath 'string(/rpc-reply/execute-result/@code)' -`

  if [[ -z ${query_response_code} && ${query_response_code} != "ok" ]]; then
      echo  "<returnInfo><errorInfo>query failed -${query_response_code}-</errorInfo></returnInfo>"
      exit 1
  fi
  #echo "`date` INFO: query passed ${query_response_code}" >&2
  if [[ ! -z $value_search ]]; then
      value_result=`echo $query_response | xmllint -xpath "string($value_search)" -`
      echo  "<returnInfo><errorInfo></errorInfo><valueSearchResult>${value_result}</valueSearchResult></returnInfo>"
      exit 0
  fi
  if [[ ! -z $count_search ]]; then
      count_line=`echo $query_response | xmllint -xpath "$count_search" -`
      count_string=`echo $count_search | cut -d '"' -f 2`
      count_result=`echo ${count_line} | tr "><" "\n" | grep -c ${count_string}`
      echo  "<returnInfo><errorInfo></errorInfo><countSearchResult>${count_result}</countSearchResult></returnInfo>"
      exit 0
  fi
}
##
#
# Setting up aws trusted root
echo "`date` INFO: Setting up aws trusted root (may report fail if already setup)"
online_results=$(semp_query ${ADMIN_USERNAME} ${ADMIN_PASSWORD} ${BROKER_SEMP_URL}/SEMP \
    "<rpc><authentication><create><certificate-authority><ca-name>aws</ca-name></certificate-authority></create></authentication></rpc>" \
    "/rpc-reply/execute-result/@code")
ca_created=`echo ${online_results} | xmllint -xpath "string(returnInfo/valueSearchResult)" -`
echo "`date` INFO: certificate-authority created status: ${ca_created}" 

wget -q -O ./AmazonRootCA1.pem -nv https://www.amazontrust.com/repository/AmazonRootCA1.pem
online_results=$(semp_query ${ADMIN_USERNAME} ${ADMIN_PASSWORD} ${BROKER_SEMP_URL}/SEMP \
    "<rpc><authentication><certificate-authority><ca-name>aws</ca-name><certificate><raw-data>`awk '{printf \"%s\\n\", $0}' AmazonRootCA1.pem`</raw-data></certificate></certificate-authority></authentication></rpc>" \
    "/rpc-reply/execute-result/@code")
ca_loaded=`echo ${online_results} | xmllint -xpath "string(returnInfo/valueSearchResult)" -`
echo "`date` INFO: certificate-authority file loaded status: ${ca_loaded}"
rm -f ./AmazonRootCA1.pem
#
# Setting up PubSub+ Queue
echo "`date` INFO: Setting up PubSub+ Queue"
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"queueName\":\"aws_service_${INTEGRATION_NAME}_${apiPath}_queue\",\"egressEnabled\":true,\"ingressEnabled\":true,\"permission\":\"delete\"}" \
    "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/queues"
#
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"msgVpnName\":\"${BROKER_MESSAGE_VPN}\",\"queueName\":\"aws_service_${INTEGRATION_NAME}_${apiPath}_queue\",\"subscriptionTopic\":\"solace-aws-service-integration_${INTEGRATION_NAME}/${apiPath}\"}" \
     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/queues/aws_service_${INTEGRATION_NAME}_${apiPath}_queue/subscriptions" 
#
# Setting up Rest Delivery Endpoint
echo "`date` INFO: Setting up Rest Delivery Endpoint"
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"enabled\":true,\"msgVpnName\":\"${BROKER_MESSAGE_VPN}\",\"restDeliveryPointName\":\"aws_service_rpd_${INTEGRATION_NAME}\"}" \
     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/restDeliveryPoints"
# Create queue binding
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"msgVpnName\":\"${BROKER_MESSAGE_VPN}\",\"postRequestTarget\":\"/${apiStage}/${apiPath}\",\"queueBindingName\":\"aws_service_${INTEGRATION_NAME}_${apiPath}_queue\",\"restDeliveryPointName\":\"aws_service_rpd_${INTEGRATION_NAME}\"}" \
     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/restDeliveryPoints/aws_service_rpd_${INTEGRATION_NAME}/queueBindings"
# Create the REST Consumer - notice enabled is false, will enable later
if [ "" == "$HTTP_AUTH_HEADER_NAME" ]; then
    # No HTTP Header authentication scheme defined
    httpHeaderAdditionalDetails=""
else
    # Define HTTP Header authentication for the RDP
    httpHeaderAdditionalDetails=",\"authenticationScheme\":\"http-header\",\"authenticationHttpHeaderName\":\"${HTTP_AUTH_HEADER_NAME}\",\"authenticationHttpHeaderValue\":\"${HTTP_AUTH_TOKEN_VALUE}\""
fi
echo httpHeaderAdditionalDetails: "$httpHeaderAdditionalDetails"
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"enabled\":false,\"msgVpnName\":\"${BROKER_MESSAGE_VPN}\",\"remoteHost\":\"${baseUrl}\",\"remotePort\":443,\"restConsumerName\":\"aws_service_rc_${INTEGRATION_NAME}\",\"tlsEnabled\":true${httpHeaderAdditionalDetails}}" \
     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/restDeliveryPoints/aws_service_rpd_${INTEGRATION_NAME}/restConsumers"

# Turn off enforcing trusted CN for the entire VPN - security risk: uncomment only if this is desired
#curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
#     --request PATCH \
#     --header "content-type:application/json" \
#     --data '{"msgVpnName":"default","restTlsServerCertEnforceTrustedCommonNameEnabled":false}' \
#     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}"

# Add trusted CN to the REST Consumer - not required if enforcing trusted CN for the entire VPN is turned off
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"msgVpnName\":\"${BROKER_MESSAGE_VPN}\",\"restConsumerName\":\"aws_service_rc_${INTEGRATION_NAME}\",\"restDeliveryPointName\":\"aws_service_rpd_${INTEGRATION_NAME}\",\"tlsTrustedCommonName\":\"*.${apiRegionUrl}\"}" \
     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/restDeliveryPoints/aws_service_rpd_${INTEGRATION_NAME}/restConsumers/aws_service_rc_${INTEGRATION_NAME}/tlsTrustedCommonNames"
# Now enable the REST Consumer
curl --user ${ADMIN_USERNAME}:${ADMIN_PASSWORD} \
     --request PATCH \
     --header "content-type:application/json" \
     --data "{\"msgVpnName\":\"${BROKER_MESSAGE_VPN}\",\"restConsumerName\":\"aws_service_rc_${INTEGRATION_NAME}\",\"restDeliveryPointName\":\"aws_service_rpd_${INTEGRATION_NAME}\",\"enabled\":true}" \
     "${BROKER_SEMP_URL}/SEMP/v2/config/msgVpns/${BROKER_MESSAGE_VPN}/restDeliveryPoints/aws_service_rpd_${INTEGRATION_NAME}/restConsumers/aws_service_rc_${INTEGRATION_NAME}"


