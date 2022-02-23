#!/bin/bash
export master='192.168.0.23'
export node1='192.168.0.24'

##################### Run this on all Linux nodes #######################

#Update the server
sudo apt-get update -y; sudo apt-get upgrade -y

#Get Kernel version. Make sure it is >= v5.3
sudo hostnamectl

#Install helm on master
sudo snap install helm --classic

#Install containerd
sudo apt-get install containerd -y

#Configure containerd and start the service
sudo mkdir -p /etc/containerd
sudo su -
containerd config default  /etc/containerd/config.toml
exit

#Next, install Kubernetes. First you need to add the repository's GPG key with the command:
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add

#Add the Kubernetes repository
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"

#Install all of the necessary Kubernetes components with the command:
sudo apt-get install kubeadm kubelet kubectl -y

#Modify "sysctl.conf" to allow Linux Node’s iptables to correctly see bridged traffic
sudo nano /etc/sysctl.conf
    #Add this line: net.bridge.bridge-nf-call-iptables = 1

sudo -s
#Allow packets arriving at the node's network interface to be forwaded to pods. 
sudo echo '1' > /proc/sys/net/ipv4/ip_forward
exit

#Reload the configurations with the command:
sudo sysctl --system

#Load overlay and netfilter modules 
sudo modprobe overlay
sudo modprobe br_netfilter
  
#Disable swap by opening the fstab file for editing 
sudo nano /etc/fstab
    #Comment out "/swap.img"

#Disable swap from comand line also 
sudo swapoff -a

#Pull the necessary containers with the command:
sudo kubeadm config images pull

#************************************************** This section must be run only on the Master node*************************************************************************************************

#Make sure "kube-proxy" is not installed, we want cilium to use the new "eBPF" based proxy
sudo kubeadm init --skip-phases=addon/kube-proxy

#*****************************************************
#Once the "init" command has completed successfuly, run the "kubeadm join ..." 
#on all your other nodes before proceeding.

sudo kubeadm join 192.168.0.23:6443 --token 02isuy.nvm4did6lsjz9yne \
        --discovery-token-ca-cert-hash sha256:6eb28d136c080f635f9d6738da9999b3c04325925c5f93e769686fe4a9d753b8
#****************************************

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

#Install cilium CLI
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}

#Setup Helm repository
helm repo add cilium https://helm.cilium.io/

#Deploy Cilium release via Helm:
helm install cilium cilium/cilium --version 1.11.1 \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set k8sServiceHost=@$master \
    --set k8sServicePort=6443

#***If "kubectl get nodes" shows "Not Ready"
#***Or  "kubectl get pods -n kube-system" shows "coredns-*" as "Pending",
#**Reboot node(s)
kubectl get nodes
kubectl get pods -n kube-system -o wide

kubectl -n kube-system get pods -l k8s-app=cilium -o wide
MASTER_CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o wide |  grep master | awk '{ print $1}' )
echo $MASTER_CILIUM_POD

#validate that the Cilium agent is running in the desired mode (non kube-proxy)
kubectl exec -it -n kube-system $MASTER_CILIUM_POD -- cilium status | grep KubeProxyReplacement

#Validate that Cilium installation
cilium status --wait

#Review what network interfaces Cilium has created
ip link show

#Optionally copy the "/.kube" folder to other nodes
scp -r $HOME/.kube gary@$node1:/home/gary


#**************************************************Cluster installation tests*******************************************************
#Optionally untaintthe master node
kubectl taint node kube-master node-role.kubernetes.io/master-

#Schedule a Kubernetes deployment using a container from Google samples
kubectl create deployment hello-world --image=gcr.io/google-samples/hello-app:1.0

#Scale up the replica set to 4
kubectl scale --replicas=4 deployment/hello-world

#Get pod info
kubectl get pods -o wide

kubectl expose deployment hello-world --port=8080 --target-port=8080 --type=NodePort
kubectl get service hello-world

kubectl exec -it -n kube-system $MASTER_CILIUM_POD -- cilium service list

#Verify that iptables are not used
sudo iptables-save | grep KUBE-SVC

export CLUSTERIP=$(kubectl get service hello-world  -o jsonpath='{ .spec.clusterIP }')
echo $CLUSTERIP

PORT=$( kubectl get service hello-world  -o jsonpath='{.spec.ports[0].port}')
echo $PORT

curl http://$CLUSTERIP:$PORT

NODEPORT=$( kubectl get service hello-world  -o jsonpath='{.spec.ports[0].nodePort}')
echo $NODEPORT

curl http://$master:$NODEPORT


#***************************************************Setup Hubble******************************************************************
#https://docs.cilium.io/en/stable/gettingstarted/hubble_setup/

cilium hubble enable

#Enabling Hubble requires the TCP port 4245 to be open on all nodes running Cilium. This is required for Relay to operate correctly.

cilium status

#In order to access the observability data collected by Hubble, install the Hubble CL
export HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
rm hubble-linux-amd64.tar.gz{,.sha256sum}

#In order to access the Hubble API, create a port forward to the Hubble service from your local machine
cilium hubble port-forward&

hubble status
#If you get "Unavailable Nodes: ", follow below troubleshooting:
######Hubbel trouble shooting####

    #Get resolution from: https://github.com/cilium/hubble/issues/599
    kubectl delete secrets -n kube-system cilium-ca
    kubectl get secrets -n kube-system hubble-ca-secret -o yaml | sed -e 's/name: hubble-ca-secret/name: cilium-ca/;/\(resourceVersion\|uid\)/d' | kubectl apply -f -
    cilium hubble disable
    cilium hubble enable
    #Please note that the next time the hubble-generate-certs CronJob runs, 
    #it will override the TLS certificates for both Hubble and Relay signing them with hubble-ca-secret (i.e. not ciliium-ca). 
    #Relay should continue to work, but this could bring more incompatibility with the CLI (e.g. if you were to disable then re-enable Hubble again through the CLI).
    cilium hubble port-forward&
    hubble status
    hubble observe

#Setup Hubble UI
cilium hubble enable --ui

cilium hubble ui











#**********************************************************Hubble CLI#############################################################################
hubble observe -o jsonpb --last 1000 > flows.json
    # Note that the observe command ignores --follow, --last, and server flags when it
    #reads flows from stdin. The observe command processes and output flows in the same
    #order they are read from stdin without sorting them by timestamp.
    cat flows.json | hubble observe

hubble observe --pod deathstar --protocol http
hubble observe --pod deathstar --verdict DROPPED
#Show only flows with the given source port
hubble observe --port 8080 --last 3
    # Show only flows with given port in either source or destination
    hubble observe --from-port 8080 --last 3

hubble observe --to-pod hello-world-57fbf88c7-s8fwq

#**********************************************************Cilium CLI#############################################################################
#https://docs.cilium.io/en/stable/cheatsheet/

#Shell Tab-completion
echo "source <(cilium completion)" >> ~/.bashrc

cilium config view

cilium connectivity test

cilium kvstore get --recursive cilium/state/nodes/

#********************************************************Cilium Agent CLI*****************************************************************************
MASTER_CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o wide |  grep master | awk '{ print $1}' )
echo $MASTER_CILIUM_POD
kubectl exec -it $MASTER_CILIUM_POD -n kube-system -- sh

#Get list of loadbalancer services
cilium service list
#Or you can get the loadbalancer information using bpf list
cilium bpf lb list



cilium identity list
cilium endpoint list
cilium identity get -o json
clear
cilium bpf tunnel list
cilium bpf nat list
cilium service list
cilium status --all-controllers --all-health --all-redirects

#***********************************************Switch to Native Routing******************************
cilium config set auto-direct-node-routes 'true'
cilium config set tunnel 'false'
cilium config set native-routing-cidr 10.0.0.0/8


cilium config set auto-direct-node-routes 'false'
cilium config set tunnel 'vxlan'
#***********************************************variables*********************************************
declare UI_POD_NAME;
declare BUS_POD_NAME;
declare DB_POD_NAME;
declare ProductsUIClusterIP;
declare ProductsBusinessClusterIP;
declare ProductsDBClusterIP;
declare POD_BUSINESS_STAGE_NS;
declare POD_UI_STAGE_N;

function setup_env(){

    # cleanup

    kubectl create namespace products-prod 
    kubectl create namespace products-stage 

    #Deploy PODs to products-prod name space
    kubectl create deployment products-ui -n products-prod --image=gcr.io/google-samples/hello-app:1.0 
    kubectl create deployment products-business -n products-prod --image=gcr.io/google-samples/hello-app:1.0 
    kubectl create deployment products-db -n products-prod --image=gcr.io/google-samples/hello-app:1.0

    #Create services for our deployments
    kubectl expose deployment products-ui -n products-prod --port=8080 --target-port=8080 --type=NodePort 
    kubectl expose deployment products-business -n products-prod --port=8080 --target-port=8080 --type=NodePort 
    kubectl expose deployment products-db -n products-prod --port=8080 --target-port=8080 --type=NodePort 

    #Deploy PODs to products-stage name space
    kubectl create deployment products-ui --image=gcr.io/google-samples/hello-app:1.0 -n products-stage
    kubectl create deployment products-business --image=gcr.io/google-samples/hello-app:1.0 -n products-stage

    #Get the POD names for the UI, Business, and Databse tiers (products-prod name space)
    kubectl get pods -n products-prod
    UI_POD_NAME=$(kubectl get pods -n products-prod | awk '  NR>1 { print $1}' | grep products-ui)
    BUS_POD_NAME=$(kubectl get pods -n products-prod | awk '  NR>1 { print $1}' | grep products-business)
    DB_POD_NAME=$(kubectl get pods -n products-prod | awk '  NR>1 { print $1}' | grep products-db)

    #Get the POD names for the UI, and Business tiers (products-stage name space)
    BUS_POD_NAME_STAGE=$(kubectl get pods -n products-stage | awk '  NR>1 { print $1}' | grep products-business)
    UI_POD_NAME_STAGE=$(kubectl get pods -n products-stage | awk '  NR>1 { print $1}' | grep products-ui)

    #Get the Cluster IPs
    kubectl get services -o wide -n products-prod 
    #Get "products-ui" ClusterIP
    ProductsUIClusterIP=$(kubectl get service products-ui -n products-prod -o jsonpath='{ .spec.clusterIP }')
    #Get "products-business" ClusterIP
    ProductsBusinessClusterIP=$(kubectl get service products-business -n products-prod -o jsonpath='{ .spec.clusterIP }')
    #Get "products-db" ClusterIP
    ProductsDBClusterIP=$(kubectl get service products-db -n products-prod -o jsonpath='{ .spec.clusterIP }')

}

#************Network Policy Part One: Restrict access to DB POD, allow access from "Stage" NS, and restrict DB egress access*****  

setup_env

#Test from services on various tiers from node
curl --max-time 1.5  http://$ProductsUIClusterIP:8080
curl --max-time 1.5  http://$ProductsBusinessClusterIP:8080
curl --max-time 1.5  http://$ProductsDBClusterIP:8080

#Test from services on various tiers from inside PODs
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -  
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -  
kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 

kubectl exec -it $UI_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -
kubectl exec -it $UI_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 
kubectl exec -it $BUS_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O - 
kubectl exec -it $BUS_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 

#Apply network policies to restrict ingress access to Business and DB PODs   

    kubectl apply -f restrict-access-to-ui-tier-only.yaml -n products-prod

    kubectl apply -f restrict-access-to-business-tier-only.yaml -n products-prod

    #Test again 
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -  
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -  
    kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 
    
    kubectl exec -it $UI_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -
    kubectl exec -it $UI_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 
    kubectl exec -it $BUS_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O - 
    kubectl exec -it $BUS_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 

#Apply network policy to allow stage business POD access db POD in prod
    #Label stage name spacese
    kubectl label namespace products-stage porducts-prod-db-access=allow

    #Apply the policy
    kubectl apply -f allow-stage-business-tier-access-to-db.yaml
    
    #Retest 
    kubectl exec -it $UI_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -
    kubectl exec -it $BUS_POD_NAME_STAGE -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -
    

#Check if DB POD has egress access to outside cluster 
kubectl exec -it $DB_POD_NAME -n products-prod -- wget -q --timeout=2 http://10.0.0.24:8080/computer -O -

#Restrict egress "db" POD traffic to POD network  
    kubectl apply -f restrict-db-egress-traffic-to-cluster-only.yaml
    #Retest
    kubectl exec -it $DB_POD_NAME -n products-prod -- wget -q --timeout=2 http://10.0.0.24:8080/computer -O -
    kubectl exec -it $DB_POD_NAME -n products-prod -- nslookup google.com
    kubectl exec -it $DB_POD_NAME -n products-prod -- wget -q --timeout=2 http://google.com -O -
    kubectl exec -it $DB_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsUIClusterIP:8080 -O -

#Cleanup
cleanup
#**********************************************************************************************************















#************************************Advanced Policies*************************************************************
setup_env

curl --max-time 1.5  http://$ProductsUIClusterIP:8080

#Creat a default egress deny network policy
kubectl apply -f default-deny-ingress.yaml -n products-prod

#Check we can access the UI service from node
curl --max-time 1.5  http://$ProductsUIClusterIP:8080

#Allow ingress access from within the cluster to UI
    kubectl apply -f allow-ingres-traffic-from-cluster-to-ui.yaml

    #Check again if we can access the UI service from node
    curl --max-time 1.5  http://$ProductsUIClusterIP:8080

#Check if UI POD has access to Business POD
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -

#Give UI POD access to Business POD
    kubectl apply -f allow-ui-tier-access-to-business.yaml 

    #Check again
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -
    #Check we can access the business service from node
    curl --max-time 1.5  http://$ProductsBusinessClusterIP:8080


#Check if Business POD has access to DB POD
kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -

#Give Business POD access to Business POD
    kubectl apply -f allow-business-tier-access-to-db.yaml 
    #Check again
    kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -

#----------------------------------Egress--------------------------------------------

#Set to deny egress efault
kubectl apply -f default-deny-egress.yaml

#Try to call a service from one of the PODs
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -

#Check if DNS resolution is available (kube-proxy) 
kubectl exec -it $UI_POD_NAME -n products-prod -- nslookup google.com

#Enable DNS access
    #Label kube-system
    kubectl label namespace kube-system name=kube-system
    kubectl apply -f allow-dns-access.yaml
    #Check again
    kubectl exec -it $UI_POD_NAME -n products-prod -- nslookup google.com

#Enable egress acces to cluster
    kubectl apply -f allow-products-prod-egress-traffic-to-cluster.yaml
    #Try again
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -
    #Chek if it has intranet access
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://10.0.0.24:8080/computer -O -

#Cleanup
cleanup
#*********************************************************************************************************************











function setup_env_cal(){

    cleanup

    #Create prod and stage name spaces
    kubectl create namespace products-prod 
    kubectl create namespace products-stage 

    #Label the prod and stage name spaces 
    #kubectl label namespace products-prod porducts-prod-db-access=allow
    #kubectl label namespace products-stage porducts-prod-db-access=allow

    #Create a new service account for prod "hello-world-bus" PODs. 
    kubectl create serviceaccount svcpoducts-bus-prod -n products-prod
    #Create a role the service account
    kubectl create role svcpoducts-prod-bus-role --verb=get,list --resource=pods -n products-prod
    #Bind the service account to role
    kubectl create rolebinding svcpoducts-prod-rolebinding --role=svcpoducts-prod-bus-role --serviceaccount=products-prod:svcpoducts-bus-prod 
    
    #Label the service account
    kubectl label  serviceaccount svcpoducts-bus-prod  -n products-prod env=prod

    #Create a new service account for stage "hello-world-bus" PODs. 
    kubectl create serviceaccount svcpoducts-bus-pilot -n products-stage
    #Create a role the service account
    kubectl create role svcpoducts-pilot-bus-role --verb=get,list --resource=pods -n products-stage
    #Bind the service account to role
    kubectl create rolebinding svcpoducts-pilot-rolebinding --role=svcpoducts-pilot-bus-role --serviceaccount=products-prod:svcpoducts-bus-pilot 
    
    #Label the service account
    kubectl label  serviceaccount svcpoducts-bus-pilot  -n products-stage env=pilot

    #Deploy prod PODs
    kubectl create deployment products-ui -n products-prod --image=gcr.io/google-samples/hello-app:1.0 
    kubectl apply -f ./cal/deploy-hello-world-bus-prod.yaml -n products-prod  
    kubectl create deployment products-db -n products-prod --image=gcr.io/google-samples/hello-app:1.0

    #Deploy stage POD
    kubectl create deployment products-ui --image=gcr.io/google-samples/hello-app:1.0 -n products-stage
    kubectl apply -f ./cal/deploy-hello-world-bus-stage.yml -n products-stage  

    kubectl expose deployment products-ui -n products-prod --port=8080 --target-port=8080 --type=NodePort 
    kubectl expose deployment products-bus -n products-prod --port=8080 --target-port=8080 --type=NodePort 
    kubectl expose deployment products-db -n products-prod --port=8080 --target-port=8080 --type=NodePort 
   

    UI_POD_NAME=$(kubectl get pods -n products-prod | awk '  NR>1 { print $1}' | grep products-ui)
    BUS_POD_NAME=$(kubectl get pods -n products-prod | awk '  NR>1 { print $1}' | grep products-bus)
    DB_POD_NAME=$(kubectl get pods -n products-prod | awk '  NR>1 { print $1}' | grep products-db)

    POD_BUSINESS_STAGE_NS=$(kubectl get pods -n products-stage | awk '  NR>1 { print $1}' | grep products-bus)
    POD_UI_STAGE_NS=$(kubectl get pods -n products-stage | awk '  NR>1 { print $1}' | grep products-ui)

    #Get "products-ui" ClusterIP
    ProductsUIClusterIP=$(kubectl get service products-ui -n products-prod -o jsonpath='{ .spec.clusterIP }')

    #Get "products-business" ClusterIP
    ProductsBusinessClusterIP=$(kubectl get service products-bus -n products-prod -o jsonpath='{ .spec.clusterIP }')

    #Get "products-db" ClusterIP
    ProductsDBClusterIP=$(kubectl get service products-db -n products-prod -o jsonpath='{ .spec.clusterIP }')

}

function cleanup(){
    
    UI_POD_NAME="";
    BUS_POD_NAME="";
    DB_POD_NAME="";
    ProductsUIClusterIP="";
    ProductsBusinessClusterIP="";
    ProductsDBClusterIP="";
    UI_POD_NAME="";
    POD_BUSINESS_STAGE_NS="";
    POD_UI_STAGE_NS="";

    kubectl delete namespace products-stage;
    kubectl delete namespace products-prod
}




#*************************************Calico NetworkPolicy: Simple*****************************************************************
setup_env

#Verify no Calico policies have been setup
calicoctl get networkpolicy -n products-prod
#Also
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -  
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 

#Deny ui access to db
    calicoctl apply -f ./cal/cal-deny-ingress-from-ui.yaml
    #Test again
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -  
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 

#*************************************Calico NetWorkPolicy: Advanced*****************************************************************

setup_env_cal

kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -  
kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -
kubectl exec -it $POD_BUSINESS_STAGE_NS -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -


#Apply the policy
    calicoctl apply -f ./cal/cal-allow-ingress-from-svc.yaml
    #Test again
    kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -  
    kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -
    kubectl exec -it $POD_BUSINESS_STAGE_NS -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -


#**********************************************************************************************************************

#*************************************Calico Policies: Old*****************************************************************

setup_env
#Verify no Calico policies have been setup
calicoctl get networkpolicy -n products-prod
#Also
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsBusinessClusterIP:8080 -O -  
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 

#Allow only ingress traffic from business tier to DB tier
    #Apply new policy
    calicoctl apply -f cal-allow-ingress-only-from-bus.yaml 
    #Verify
    calicoctl get networkpolicy -n products-prod

#Test policy
kubectl exec -it $UI_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O - 
kubectl exec -it $BUS_POD_NAME -n products-prod -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -

#Allow ingress traffic from "products-stage" name space
    #Veiry business POD in "products-stage" does not have access to DB POD
    kubectl exec -it $POD_UI_STAGE_NS -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -
    #Label stage name spacese
    kubectl label namespace products-stage porducts-prod-db-access=allow
    #Apply new policy
    calicoctl apply -f cal-allow-stage-bus-ingress-access.yaml
    #Test again
    kubectl exec -it $POD_BUSINESS_STAGE_NS -n products-stage -- wget -q --timeout=2 http://$ProductsDBClusterIP:8080 -O -


#Deny access from UI POD and log denied traffic

#Creat a service account 
    

#**********************************************************************************************************************


####################################HR Service###################################
kubectl create deployment hr  --image=gcr.io/google-samples/hello-app:1.0 -n test
kubectl expose deployment hr  --port=8080 --target-port=8080 --type=NodePort -n test
kubectl get pods -o wide -n test 
kubectl get services -n test -o wide
curl http://10.0.0.152:30074

kubectl exec -it hr-c98f57d4b-r8bpb -n test -- sh
kubectl delete service hr -n test
kubectl delete deployment hr -n test


#Clean up
kubectl delete deployment hello-world
kubectl delete service hello-world
kubectl delete service hello-world-nodeport
kubectl delete service hello-world-no-selector
#####################################################################Check interfaces########################################################################

ip addr
#Show veth sets
ip link  show type veth
#Show IP-inIP
ip link show type ipip
#Get pods
kubectl get pods -o wide
#Get route to POD with IP: 172.16.94.5 (on Node1)
ip route get



######################################################Service Discovery#######################################################################################################
#Display CoreDNS PODs
kubectl get pods -n kube-system | grep coredns

#Show services in kube-system where CoreDNS resides
kubectl get services -n kube-system

#Check DNS record for our "hello-world-nodeport" service
nslookup hello-world-no-selector.default.svc.cluster.local  10.96.0.10

#Show services in the "test" name space
kubectl get services -n test

#Show DNS record for the "hr" service 
nslookup 10.105.76.144 10.96.0.10

kubectl exec -it mytest-app-695d74547b-8wcn6 -- sh
    
    #Execute the service through its DNS name:
    curl http://hello-world-nodeport.default.svc.cluster.local:8080
    

    #View DNS resolver on this POD
    cat /etc/resolv.conf


    curl http://hello-world-nodeport.default.svc:8080
    curl http://hello-world-nodeport.default:8080
    curl http://hello-world-nodeport:8080
    exit

kubectl exec hello-world-5457b44555-4qrbb -- cat /etc/resolv.conf

kubectl describe deployment coredns -n kube-system

kubectl get service -n kube-system -o wide
	kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   19h   k8s-app=kube-dns

kubectl get service kube-dns -n kube-system
	NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE   SELECTOR
        kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   19h   k8s-app=kube-dns

#10.100.58.104 is the ClusterIP 
nslookup 10.100.58.104 10.96.0.10
	 104.58.100.10.in-addr.arpa      name = hello-world.default.svc.cluster.local

nslookup hello-world.default.svc.cluster.local 10.96.0.10
    Server:         10.96.0.10
    Address:        10.96.0.10#53

    Name:   hello-world.default.svc.cluster.local
    Address: 10.100.58.104

#From inside POD:
curl http://hello-world.default.svc.cluster.local:8080
         Hello, world!
         Version: 1.0.0
         Hostname: hello-world-5457b44555-s5pl8

PODNAME=$(kubectl get pods -o jsonpath='{.items[].metadata.name}')
kubectl exec -it $PODNAME -- env | sort


#Clean up
kubectl delete deployment hello-world
kubectl delete service hello-world
kubectl delete service hello-world-nodeport
kubectl delete service hello-world-no-selector
#*******************************************************************************************************

#**************************************************ad-hoc commands and notes****************************

#Get POD logs
kubectl logs hello-minikube-64b64df8c9-ln67f

#Untaint maste
kubectl taint node kube-master node-role.kubernetes.io/master-

#Add curl to POD
apk --no-cache add curl

#From inside cluster we can do
curl http://hello-world:8080
    #rather than ClusterIP
        curl http://10.99.252.65:8080


kubeadm token create --print-join-command #This will get teh token for adding a new node.
sudo kubeadm reset  #this will un-configure the kubernetes cluster.
#Deleting a worker node:
    kubectl cordon kube-node2
    kubectl drain --ignore-daemonsets --force kube-node2
    kubectl delete node kube-node2


--type=NodePort
--type=ClusterIP

#How to install docker enterprise on Win 2019: https://computingforgeeks.com/how-to-run-docker-containers-on-windows-server-2019/

#Get OS and version
cat /etc/os-release
	#Notes:
	cat /proc/version is showing kernel version. As containers run on the same kernel as the host. It is the same kernel as the host.
	cat /etc/*-release is showing the distribution release. It is the OS version, minus the kernel.
	A container is not virtualisation, in is an isolation system that runs directly on the Linux kernel. 
        It uses the kernel name-spaces, and cgroups. Name-spaces allow separate networks, process ids, mount points, users, hostname, 
        Inter-process-communication. cgroups allows limiting resources.

#How to install ip utility on Ubuntu:
    # apt update
    # apt install iproute2 -y

    #Kube context switching
    kubectl config use-context kubernetes-admin@kubernetes

#Copy cluster certs to Windows machines
scp -r $HOME/.kube gary@192.168.0.10:/Users/grost

#**************************************Postgres**********************************************************************
docker run --name postgres -e POSTGRES_PASSWORD=ostad1 -d postgres
docker exec -it postgres psql -U postgres
    postgres=# create database test
    docker exec -it postgres createdb -h localhost -p 5432 -U postgres products

#****************************************scp from remote server*****************************************************
scp gary@192.168.0.23:~/tests/scripts/git/*.* C:\Users\grost\OneDrive\YouTube-Channel\Video-25-Cilium\scripts\Remote
#*******************************************************************************************************************