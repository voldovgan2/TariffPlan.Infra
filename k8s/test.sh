#!/bin/bash
set -euo pipefail

DELAY=10
TARIFF_BASE="http://nowlege.com/tariff-api/api/Tariff"
SIMCARD_API_BASE="http://nowlege.com/simcard-api/api/SimCard"
SIMCARD_VIEW_BASE="http://nowlege.com/simcard-view/api/SimCard"

CREATE_TARIFF_DRAFT_BODY='{
  "name": "Simple",
  "perMinuteCost": 0.25,
  "smsCost": 0.1,
  "connectionFee": 0.15,
  "perSecondBilling": 10,
  "externalIncomingCallPerSecondReward": 0.2,
  "bonusForRecharge": {
    "amount": 100,
    "value": 10,
    "expiresIn": 30
  },
  "serviceBundle": {
    "recurring": {
      "price": 300,
      "callMinutesAmount": 500,
      "smsAmount": 500,
      "expiresIn": 28
    },
    "daily": {
      "price": 15,
      "callMinutesAmount": 10,
      "smsAmount": 10,
      "expiresIn": 1
    }
  },
  "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
}'

CREATE_SIMCARD_TEMPLATE='{
  "number": "+380666666666",
  "tariff": {
    "id": "REPLACE",
    "name": "REPLACE_NAME",
    "perMinuteCost": 0.25,
    "smsCost": 0.1,
    "connectionFee": 0.15,
    "perSecondBilling": 10,
    "externalIncomingCallPerSecondReward": 0.2,
    "bonusForRecharge": {
      "amount": 100,
      "value": 10,
      "expiresIn": 30
    },
    "serviceBundle": {
      "recurring": {
        "price": 300,
        "callMinutesAmount": 500,
        "smsAmount": 500,
        "expiresIn": 28
      },
      "daily": {
        "price": 15,
        "callMinutesAmount": 10,
        "smsAmount": 10,
        "expiresIn": 1
      }
    }
  },
  "defaultExpiration": 180,
  "amountToExtendExpiration": 10,
  "balance": 10,
  "discountForPersonalization": 10
}'

start_env() {
	cd Helm
	helm install infra ./infra -n tariff-plan-app --create-namespace
	helm install application ./application -n tariff-plan-app --create-namespace
	kubectl apply -f ingress.yaml
	local hosts_entry=$(getHostEntry)
	if [[ -n "$hosts_entry" ]]; then
		if ! grep -qF "$hosts_entry" /etc/hosts; then
			sudo sh -c "echo '$hosts_entry' >> /etc/hosts"
		fi
   	fi
   	cd ../
}

stop_env() {
   	if kubectl get namespace tariff-plan-app >/dev/null 2>&1; then
   	    local hosts_entry=$(getHostEntry)
	    if [[ -n "$hosts_entry" ]]; then
		    if grep -qF "$hosts_entry" /etc/hosts; then
        	    sudo sed -i '' "\|$hosts_entry|d" /etc/hosts
    	    fi
   	    fi
        kubectl delete namespace tariff-plan-app
    fi
}

getHostEntry () {
	local ingress_ip=$(getIngress)
	echo "$ingress_ip	nowlege.com"
}

getIngress() {
	local ingress_ip
	local i=0
	while (( i < 10 )); do
    	local ingress_json=$(kubectl get ingress tariff-plan-ingress -n tariff-plan-app -o json)
    	if echo "$ingress_json" | jq -e '.status.loadBalancer.ingress | length > 0' >/dev/null; then
    		ingress_ip=$(echo "$ingress_json" | jq -r '.status.loadBalancer.ingress[0].ip')
        	break
    	fi
    	sleep 10
    	((i++))
	done
	echo "$ingress_ip"
}

post() {
    local url=$1
    local request_body=$2
    local info=$3
    local response=$(curl -X POST \
        -sS \
        -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        "$url")
    local status=$(tail -n1 <<< "$response")
    local response_body=$(sed '$d' <<< "$response")
    if [[ $status = "200" ]]; then
        local value=$(jq -r '.' <<< "$response_body")
        echo "$value"
        return 0
    else
        echo "$info failed: - $status"
        return 1
    fi
}

put() {
    local url=$1
    local request_body=$2
    local info=$3
    local response=$(curl -X PUT \
        -sS \
        -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        "$url")
    local status=$(tail -n1 <<< "$response")
    if [[ $status = "200" ]]; then
        return 0
    else
        return 1
    fi
}

get() {
    local url=$1
    local info=$2
    local response=$(curl -X GET \
        -sS \
        -w "\n%{http_code}" \
        "$url")
    local status=$(tail -n1 <<< "$response")
    local response_body=$(sed '$d' <<< "$response")
    if [[ $status = "200" ]]; then
        local value=$(jq -r '.' <<< "$response_body")
        echo "$value"
        return 0
    else
        echo "$info failed: - $status"
        return 1
    fi
}

echo "This script needs sudo access to modify /etc/hosts"
sudo -v

echo "Stopping env (just in case)"
stop_env

echo "Starting env..."
start_env

echo "Running tests..."

info="Step 1"
echo "$info - Create tariff draft"
tariff_draft_id=$(post "$TARIFF_BASE/create-tariff-draft" "$CREATE_TARIFF_DRAFT_BODY" "$info")
echo "$info - OK"

info="Step 2"
echo "$info - Create tariff"
create_tariff_body=$(jq -n --arg id "$tariff_draft_id" '$id')
tariff_id=$(post "$TARIFF_BASE/create-tariff" "$create_tariff_body" "$info")
echo "$info - OK"

info="Step 3"
echo "$info - Get tariff"
tariff=$(get "$TARIFF_BASE/get-tariff/$tariff_id" "$info")
echo "$info - OK"

info="Step 4"
echo "$info - Create simcard"
tariff_name=$(jq -r '.name' <<< "$tariff")
create_simcard_body=$(jq --arg id "$tariff_id" --arg name "$tariff_name" '.tariff.id = $id | .tariff.name = $name' <<< "$CREATE_SIMCARD_TEMPLATE")
simcard_id=$(post "$SIMCARD_API_BASE/create" "$create_simcard_body" "$info")
echo "$info - OK"

info="Step 5"
echo "$info - Get simcard"
sleep "$DELAY"
simcard=$(get "$SIMCARD_VIEW_BASE/get-simcard/$simcard_id" "$info")
echo "$info - OK"

info="Step 6"
echo "$info - Update tariff"
new_tariff_name="Free"
update_tariff_body=$(jq --arg name "$new_tariff_name" '.name = $name' <<< "$tariff")
put "$TARIFF_BASE/update-tariff" "$update_tariff_body" "$info"
echo "$info - OK"

info="Step 7"
echo "$info - Get tariff"
tariff=$(get "$TARIFF_BASE/get-tariff/$tariff_id" "$info")
tariff_name=$(jq -r '.name' <<< "$tariff")
if [[ $tariff_name = $new_tariff_name ]]; then
    echo "$info - OK"
else
    echo "$info failed: $tariff_name != $new_tariff_name"
    exit 1
fi

info="Step 8"
echo "$info - Get simcard"
sleep "$DELAY"
simcard=$(get "$SIMCARD_VIEW_BASE/get-simcard/$simcard_id" "$info")
simcard_tariff_name=$(jq -r '.tariff.name' <<< "$simcard")
if [[ $simcard_tariff_name = $new_tariff_name ]]; then
    echo "$info - OK"
else
    echo "$info failed: $simcard_tariff_name != $new_tariff_name"
    exit 1
fi

echo "Stopping env..."
stop_env
echo "Done"

