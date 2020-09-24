#!/bin/bash

source "$(dirname $0)/k8s_library.sh"

set -e
trap 'catch $? $LINENO' EXIT
catch() {
  if [ "$1" != "0" ]; then
    echo "Error $1 occurred on $2"
  fi
}

# variables below can be inherited from environmemt
if [[ -z ${GKE_CLUSTER+x} ]]   ; then export GKE_CLUSTER='microservice-demo-cluster' ; fi ; echo "gke cluster: $GKE_CLUSTER"
if [[ -z ${APPL_VERSION+x} ]]  ; then export APPL_VERSION='v0.2.0' ; fi ; echo "appl version: $APPL_VERSION"
if [[ -z ${GKE_CREATE+x} ]]    ; then export GKE_CREATE='true' ; fi ; echo "gke create: $GKE_CREATE"
if [[ -z ${APPL_DEPLOY+x} ]]   ; then export APPL_DEPLOY='true' ; fi ; echo "appl deploy: $APPL_DEPLOY"
if [[ -z ${APPL_NS+x} ]]       ; then export APPL_NS='default' ; fi ; echo "appl namespace: $APPL_DEPLOY"
if [[ -z ${WITH_ISTIO+x} ]]    ; then export WITH_ISTIO='true' ; fi ; echo "with istio: $WITH_ISTIO" 
if [[ -z ${APPL_DELETE+x} ]]   ; then export APPL_DELETE='false' ; fi ; echo "appl delete: $APPL_DELETE"
if [[ -z ${GKE_DELETE+x} ]]    ; then export GKE_DELETE='false' ; fi ; echo "gke delete: $GKE_DELETE"

update_gcloud_sdk

gcloud_get_info

if [[ "$GKE_CREATE" == *'true'* ]]
then
  create_cluster $GKE_CLUSTER
fi

gcloud_get_credentials

deploy_k8s_dashboard

deploy_polaris

if [[ "$WITH_ISTIO" == *'true'* ]]
then
    deploy_istio
    deploy_istio_addons
fi 

if [[ "$APPL_DEPLOY" == *'true'* ]]
then

  if [[ "$WITH_ISTIO" == *'true'* ]]
  then
    activate_istio_for_ns "$APPL_NS"

    echo "### deploy appl istio manifests:"
    kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/istio-manifests/frontend-gateway.yaml"
    kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/istio-manifests/frontend.yaml"
    kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/istio-manifests/whitelist-egress-googleapis.yaml"
  fi

  echo "### deploy application: "
  kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/release/kubernetes-manifests.yaml"
  echo "### wait for resources to become available: "
  kubectl wait --for=condition=available --timeout=500s deployment/adservice
  kubectl wait --for=condition=available --timeout=500s deployment/cartservice
  kubectl wait --for=condition=available --timeout=500s deployment/checkoutservice
  kubectl wait --for=condition=available --timeout=500s deployment/currencyservice
  kubectl wait --for=condition=available --timeout=500s deployment/emailservice
  kubectl wait --for=condition=available --timeout=500s deployment/frontend
  kubectl wait --for=condition=available --timeout=500s deployment/loadgenerator
  kubectl wait --for=condition=available --timeout=500s deployment/paymentservice
  kubectl wait --for=condition=available --timeout=500s deployment/productcatalogservice
  kubectl wait --for=condition=available --timeout=500s deployment/recommendationservice
  kubectl wait --for=condition=available --timeout=500s deployment/shippingservice
  kubectl get service frontend-external
  while [[ $(kubectl get service 'frontend-external' | grep 'frontend-external' | awk '{print $4}') == *'<pending>'* ]]
  do
    echo "sleep 5s to get public ip"
    sleep 5s
  done
  APPL_PUBLIC_IP=$(kubectl get service 'frontend-external' | grep 'frontend-external' | awk '{print $4}')
  echo "### public ip: $APPL_PUBLIC_IP"
  CURL_CHECK=$(curl "http://$APPL_PUBLIC_IP")
  if [[ "$CURL_CHECK" == *'Uh, oh!'* ]]
  then
  	echo "### curl check failed: $CURL_CHECK"
  else
  	echo "### curl check succeded" 
  fi
  while [[ "$REQUEST_COUNT"  -lt "50"  ]]
  do
    sleep 5
    REQUEST_COUNT=$(kubectl logs -l app=loadgenerator -c main | grep Aggregated | awk '{print $2}')
  done
  echo -e "load generator requests until now:\n$(kubectl logs -l app=loadgenerator -c main)"
  # ensure there are no errors hitting endpoints
  ERROR_COUNT=$(kubectl logs -l app=loadgenerator -c main | grep Aggregated | awk '{print $3}' | sed "s/[(][^)]*[)]//g")
  if [[ "$ERROR_COUNT" -gt "0" ]]
  then
    echo "load generator errors found: $(kubectl logs -l app=loadgenerator -c main)"
    exit 1
  fi
  analyze_istio_config "$APPL_NS"
fi

if [[ "$APPL_DELETE" == *'true'* ]]
then
  
  deactivate_istio_for_ns "$APPL_NS"
  
  echo "### delete application:"
  kubectl delete -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/release/kubernetes-manifests.yaml" || true
  #echo "### wait for delete completion:"
  #kubectl wait --for=delete --timeout=500s deployment/adservice
  #kubectl wait --for=delete --timeout=500s deployment/cartservice
  #kubectl wait --for=delete --timeout=500s deployment/checkoutservice
  #kubectl wait --for=delete --timeout=500s deployment/currencyservice
  #kubectl wait --for=delete --timeout=500s deployment/emailservice
  #kubectl wait --for=delete --timeout=500s deployment/frontend
  #kubectl wait --for=delete --timeout=500s deployment/loadgenerator
  #kubectl wait --for=delete --timeout=500s deployment/paymentservice
  #kubectl wait --for=delete --timeout=500s deployment/productcatalogservice
  #kubectl wait --for=delete --timeout=500s deployment/recommendationservice
  #kubectl wait --for=delete --timeout=500s deployment/shippingservice
  #kubectl get service frontend-external

  echo "### delete application istio manifests:"
  kubectl delete -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/istio-manifests/frontend-gateway.yaml"
  kubectl delete -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/istio-manifests/frontend.yaml"
  kubectl delete -f "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$APPL_VERSION/istio-manifests/whitelist-egress-googleapis.yaml"

fi

if [[ "$GKE_DELETE" == *'true'* ]]
then
  delete_cluster $GKE_CLUSTER
fi