#!/bin/bash

#GCP_PROJECT comes from external env var (for securitry reasons)
export GCP_VERBOSITY='warning'
export GCP_ZONE='us-central1-c'
export GKE_CHANNEL='rapid'
export GKE_VERSION='1.18.9-gke.1501'
export GKE_NODES=3
export GKE_MACHINE='n1-standard-2'
export PROMETHEUS_NS='monitoring'
export ISTIO_NS='istio-system'
export ISTIO_VERSION=1.7.2
export LITMUS_VERSION=1.8.1


update_gcloud_sdk() 
{
  which gcloud
  gcloud components install beta --quiet
  gcloud components update --quiet
  which gcloud
}

gcloud_get_info() 
{
  echo '--- gcloud version ---'
  gcloud version
  echo '--- gcloud info ---'
  gcloud info --anonymize
}

create_cluster() 
{
  local GKE_CLUSTER="$1"
  echo "### list clusters [before create]:"
  gcloud container clusters list --verbosity="$GCP_VERBOSITY" --project="$GCP_PROJECT" --quiet
  echo "### create cluster: $GKE_CLUSTER"
  # https://cloud.google.com/istio/docs/istio-on-gke/installing
  # https://cloud.google.com/istio/docs/istio-on-gke/versions
  # NB: Istio is still a 'beta' feature : see blelow
  # --addons=Istio \
  # --istio-config=auth='MTLS_PERMISSIVE' \
  gcloud beta container clusters create "$GKE_CLUSTER" \
      --cluster-version="$GKE_VERSION" \
      --num-nodes="$GKE_NODES"  \
      --machine-type="$GKE_MACHINE"  \
      --project="$GCP_PROJECT"  \
      --zone "$GCP_ZONE"  \
      --release-channel "$GKE_CHANNEL"  \
      --quiet \
      --verbosity="$GCP_VERBOSITY"
  echo "### list clusters [after create]:"
  gcloud container clusters list --verbosity="$GCP_VERBOSITY" --project="$GCP_PROJECT"
  echo "### check istio:"
  kubectl get services -n "$ISTIO_NS"
  kubectl get pods -n "$ISTIO_NS"
}

delete_cluster() 
{
  local GKE_CLUSTER="$1"
  echo "### list clusters [before delete]:"
  gcloud container clusters delete "$GKE_CLUSTER" \
      --project="$GCP_PROJECT" \
      --zone "$GCP_ZONE" \
      --quiet \
      --verbosity="$GCP_VERBOSITY" 
  echo "#### list clusters [after delete]:"
}

gcloud_get_credentials() 
{
  echo "### get credentials & config for kubectl: "
  gcloud container clusters get-credentials "$GKE_CLUSTER" --zone "$GCP_ZONE" --project="$GCP_PROJECT"
}

cluster_info()
{
  echo "### cluster info: "
  kubectl cluster-info
  echo "### get nodes: "
  kubectl get nodes
  echo "### get namespaces: "
  kubectl get namespaces
  echo "### get services: "
  kubectl get services --all-namespaces
  echo "### get deployments: "
  kubectl get deployments --all-namespaces
  echo "### get pods: "
  kubectl get pods --all-namespaces
}

deploy_k8s_dashboard() 
{
  echo "### deploy k8s dashboard: "
  kubectl apply -f 'https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.4/aio/deploy/recommended.yaml'
  echo "### wait for deployments to become available: "
  kubectl wait --for=condition=available --timeout=500s -n kubernetes-dashboard deployment/kubernetes-dashboard
  kubectl wait --for=condition=available --timeout=500s -n kubernetes-dashboard deployment/dashboard-metrics-scraper
  echo "### dashboard services: "
  kubectl get services -n kubernetes-dashboard
  kubectl get services -n kubernetes-dashboard | ((wc -l | grep 3) && echo 'no unexpected new service')
  echo "### dashboard services: "
  kubectl get pods -n kubernetes-dashboard
  kubectl get pods -n kubernetes-dashboard | ((wc -l | grep 3) && echo 'no unexpected new pod')
  #kubectl create serviceaccount 'dashboard-admin-sa'
  #kubectl create clusterrolebinding 'dashboard-admin-sa' --clusterrole='cluster-admin' --serviceaccount='default:dashboard-admin-sa'
  #kubectl get secrets
}

deploy_istio() 
{
  local ISTIO_NS="istio-system" 
  echo "###  create istio ns:  $ISTIO_NS" 
  kubectl delete ns "$ISTIO_NS" || true
  kubectl create ns "$ISTIO_NS" 
  echo "### working directory: $(pwd)"
  curl -L https://istio.io/downloadIstio | sh -
  export PATH="$PATH:$(pwd)/istio-1.7.2/bin"
  echo "### istioctl location: $(which istioctl)"
  echo "### istioctl version: $(istioctl version --remote=false)"
  echo "###  istioctl install --set profile=demo" 
  istioctl install --set profile=demo
  check_istio "$ISTIO_NS" 
  echo "###  istio services:" 
  kubectl get services -n "$ISTIO_NS" 
  kubectl get services -n "$ISTIO_NS"  | ((wc -l | grep 4) && echo 'no unexpected new service')
  echo "### istio pods:" 
  kubectl get pods -n "$ISTIO_NS" 
  kubectl get pods -n "$ISTIO_NS"  | ((wc -l | grep 4) && echo 'no unexpected new pod')
}

deploy_istio_addons() 
{
  echo "### deploy istio addons:" 
  # install of addons may have to be repeated accorcding to https://istio.io/latest/docs/setup/getting-started/#dashboard (true most of time....)
  kubectl apply -f "istio-$ISTIO_VERSION/samples/addons" || kubectl apply -f "istio-$ISTIO_VERSION/samples/addons"
  echo "### check istio addons:" 
  kubectl wait --for=condition=available --timeout=500s deployment/prometheus -n istio-system
  kubectl wait --for=condition=available --timeout=500s deployment/grafana -n istio-system
  kubectl wait --for=condition=available --timeout=500s deployment/jaeger -n istio-system
  kubectl wait --for=condition=available --timeout=500s deployment/kiali -n istio-system
}

# see https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
activate_istio_for_ns() 
{
  local ISTIO_APPL_NS="$1"
  echo "#### activate istio for ns: $ISTIO_APPL_NS"
  kubectl label namespace --overwrite "$ISTIO_APPL_NS" istio-injection='enabled'
  kubectl get namespaces -L istio-injection
}

deactivate_istio_for_ns() 
{
  local ISTIO_APPL_NS="$1"
  echo "#### deactivate istio for ns: $ISTIO_APPL_NS"
  kubectl label namespace "$ISTIO_APPL_NS" istio-injection-
  kubectl get namespaces -L istio-injection
}


analyze_istio_config() 
{
  local ISTIO_APPL_NS="$1"
  echo "#### analyze istio config for ns: $ISTIO_APPL_NS"
	istioctl analyze --output-threshold Info --namespace "$ISTIO_APPL_NS"
}

deploy_polaris() 
{
  kubectl apply -f https://github.com/FairwindsOps/polaris/releases/latest/download/dashboard.yaml
  kubectl get namespaces | grep polaris
  kubectl wait --for=condition=available --timeout=500s deployment/polaris-dashboard -n polaris
  #kubectl port-forward --namespace polaris svc/polaris-dashboard 8080:80
}

deploy_kube_hunter() 
{
  kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-hunter/master/job.yaml
  kubectl describe job kube-hunter
  #kubectl logs <pod name>
}

deploy_kube_bench() 
{
  # https://github.com/aquasecurity/kube-bench/issues/266
  kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/master/job-gke.yaml
  kubectl describe job kube-bench
  #kubectl logs <pod name>
}

deploy_litmus_operator() 
{
  echo "### install litmus choas engine: "
  kubectl apply -f "https://litmuschaos.github.io/litmus/litmus-operator-v$LITMUS_VERSION.yaml"
  echo "### get pods in ns litmus:"
  kubectl get pods -n litmus
  #chaos-operator-ce-
  echo "### check crds defined by litmus:"
  kubectl get crds
  kubectl get crds | grep 'chaosengines.litmuschaos.io'
  kubectl get crds | grep 'chaosexperiments.litmuschaos.io'
  kubectl get crds | grep 'chaosresults.litmuschaos.io'
  echo "### check apis defined by litmus:"
  kubectl api-resources
  kubectl api-resources | grep 'chaosengines'
  kubectl api-resources | grep 'chaosexperiments'
  kubectl api-resources | grep 'chaosresults'
}

delete_litmus_operator() 
{
  echo "### delete litmus operator: "
  kubectl delete -f "https://litmuschaos.github.io/litmus/litmus-operator-v$LITMUS_VERSION.yaml"
  
}

run_litmus_engine()
{
  local APPL_NS="$1"
  echo "#### deploy generic experiments in : $APPL_NS"
  #kubectl apply -f "https://hub.litmuschaos.io/api/chaos/$LITMUS_VERSION?file=charts/generic/experiments.yaml" -n "$APPL_NS"
  kubectl get chaosexperiments -n "$APPL_NS"
  kubectl get chaosexperiments -n "$APPL_NS" | wc -l | grep '22'
  kubectl apply -f "kubernetes/litmus/rbac.yaml" -n "$APPL_NS"
  #
  kubectl annotate deployment/frontend --overwrite litmuschaos.io/chaos="true" -n "$APPL_NS"
  kubectl label deployment/frontend --overwrite app='frontend' -n "$APPL_NS"
  #
  kubectl apply -f "kubernetes/litmus/chaos-engine.yaml" -n "$APPL_NS"
  kubectl describe chaosresult frontend-chaos-pod-delete -n "$APPL_NS"
}

deploy_prometheus() 
{
  #deploy_prometheus
  kubectl create namespace "$PROMETHEUS_NS"
  kubectl create -f 'kubernetes/prometheus/prometheus-cluster-role.yaml'
  kubectl create -f 'kubernetes/prometheus/prometheus-scrape-alerting.yaml'
  kubectl create -f 'kubernetes/promotheus/prometheus-deployment.yaml'
  kubectl get pods --namespace='monitoring'
  #kubectl port-forward prometheus-deployment-7bb6c5d7fd-d2zsf 8080:9090 -n monitoring
}

#to be used if istio addon is installed via this script
check_istio() 
{
  local ISTIO_SERVICES=(                                                                                                                                  
      'istiod'  
      'istio-ingressgateway'
      'istio-egressgateway'
    )
   check_services "$ISTIO_NS" "${ISTIO_SERVICES[@]}" 
   local ISTIO_PODS=(
      'istiod-'  
      'istio-ingressgateway-'
      'istio-egressgateway-'
     )
   check_pods "$ISTIO_NS" "${ISTIO_PODS[@]}"      
} 

#to be used if GKE istio addon is activated
check_gke_istio() 
{
  local ISTIO_SERVICES=(                                                                                                                                  
      'istio-citadel'  
      'istio-galley'  
      'istio-ingressgateway'
      'istio-pilot'   
      'istio-policy'   
      'istio-sidecar-injector'   
      'istio-telemetry'
    )
   check_services "$ISTIO_NS" "${ISTIO_SERVICES[@]}" 
   local ISTIO_PODS=(
      'istio-citadel-'
      'istio-galley-'
      'istio-ingressgateway-'
      'istio-pilot-'
      'istio-policy-'
      'istio-security-post-install-'
      'istio-sidecar-injector-'
      'istio-telemetry-'
     )
   check_pods "$ISTIO_NS" "${ISTIO_PODS[@]}"
   local PROMETHEUS_SERVICES=(  
       'promsd'
       'prometheus'
     )
   check_services "$ISTIO_NS" "${PROMETHEUS_SERVICES[@]}"   
   local PROMETHEUS_PODS=(         
      'promsd-'
      'prometheus-'
     )
   check_pods "$ISTIO_NS" "${PROMETHEUS_PODS[@]}"        
} 


check_services() 
{
  local NS="$1"
  shift
  local SERVICES=("$@")
  echo "check services in ns: $1 -> ${SERVICES[@]}"
  local KUBECTL=$(kubectl get services -n "$NS")
  echo "### kubectl<begin>"
  echo "$KUBECTL"
  echo "### kubectl<end>"
  check_strings "$KUBECTL" "${SERVICES[@]}"
}


check_pods() 
{
  local NS="$1"
  shift
  local PODS=("$@")
  echo "check pods in ns: $1 -> ${PODS[@]}"
  local KUBECTL=$(kubectl get pods -n "$NS")
  echo "### kubectl<begin>"
  echo "$KUBECTL"
  echo "### kubectl<end>"
  check_strings "$KUBECTL" "${PODS[@]}"
}

# https://askubuntu.com/questions/674333/how-to-pass-an-array-as-function-argument
check_strings() 
{
  local STR_COMMAND="$1"
  shift
  STR_ARRAY=("$@")
  
  for STR in "${STR_ARRAY[@]}"
  do
      #echo " $STR_COMMAND =?= *$STR*"
      if [[ ! "$STR_COMMAND" == *"$STR"* ]]
      then
          echo "### command string: $STR_COMMAND"
      		echo "### ERROR: no match for $STR"
      		exit 1
      fi
  done
}
