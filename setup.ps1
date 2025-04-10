$SUFFIX = "0634" # test suffix to use for resource names
$GROUP = "rg-aks-ob-poc-$SUFFIX" # resource group name
$CLUSTER = "obpoc1-$SUFFIX"
$LOCATION = "eastus2"
$VNET = "vnet"
$AKS_SUBNET = "aks"
$ALB_SUBNET = "alb"
$KEY_VAULT = "secretsvaultrjp-$SUFFIX"
$ACR = "secretsdemoacr$SUFFIX"
$NAMESPACE = "nginx" # kubernetes app namespace of the service account
$SERVICE_ACCOUNT = "cluster-workload-user" # kubernetes service account name
$FEDERATED_NAME = "federated-workload-user" # id used for federated credential
$APP_UAMI = "ryan-workload" # workload managed identity in Azure for app
$ALB_UAMI = "ryan-agc" # workload managed identity in Azure for ALB

# get the current user id
$USER_ID = az ad signed-in-user show -o tsv --query id

# get the subscription id
$SUBSCRIPTION = az account show -o tsv --query id

# create resource group
az group create -n $GROUP -l $LOCATION

# create the vnet and subnets for AKS
az network vnet create -n $VNET -g $GROUP --address-prefixes 192.168.0.0/16

# create AKS subnet
$AKS_SUBNET_ID = az network vnet subnet create `
    -n $AKS_SUBNET -g $GROUP `
    --vnet-name $VNET `
    --address-prefixes 192.168.0.0/24 `
    -o tsv --query id

# create ALB subnet
$ALB_SUBNET_ID = az network vnet subnet create `
    -n $ALB_SUBNET -g $GROUP `
    --vnet-name $VNET `
    --address-prefixes 192.168.1.0/24 `
    --delegations 'Microsoft.ServiceNetworking/trafficControllers' `
    -o tsv --query id

# create a container registry
az acr create -n $ACR -g $GROUP --sku Standard

# log into the ACR (requires docker to be installed and running)
#az acr login -n $ACR

# create a cluster
$AKS_ID = az aks create -n $CLUSTER -g $GROUP `
    -c 3 `
    -k 1.31.7 `
    --vnet-subnet-id $AKS_SUBNET_ID `
    --service-cidr 172.16.1.0/24 `
    --pod-cidr 10.0.0.0/8 `
    --network-plugin azure `
    --network-plugin-mode overlay `
    --network-dataplane cilium `
    --dns-service-ip 172.16.1.3 `
    --node-osdisk-type Ephemeral `
    --node-osdisk-size 48 `
    --os-sku AzureLinux `
    --ssh-access disabled `
    --attach-acr $ACR `
    --enable-azure-monitor-metrics `
    --enable-aad `
    --enable-azure-rbac `
    --enable-oidc-issuer `
    --enable-workload-identity `
    --enable-addons azure-keyvault-secrets-provider `
    -o tsv --query id

# loop until the cluster is provisioned
do {
    $state = az aks show -g $GROUP -n $CLUSTER  -o tsv --query "provisioningState"

    Write-Host "ProvisioningState: $state"

    if ($state -ne 'Succeeded') {
        Write-Host "Cluster still updating... waiting 10s"
        Start-Sleep -Seconds 10
    }
} while ($state -ne 'Succeeded')

# taint the system node pool
az aks nodepool update -n nodepool1 `
    --cluster-name $CLUSTER `
    -g $GROUP `
    --node-taints CriticalAddonsOnly=true:NoSchedule

# add user node pool
az aks nodepool add -g $GROUP --cluster-name $CLUSTER `
    --name appspool `
    --node-count 2 `
    --os-sku AzureLinux `
    --mode User

# authenticate to the cluster
az aks get-credentials -n $CLUSTER -g $GROUP --overwrite-existing

# create the managed workload identity for a sample application
$APP_UAMI_CLIENT_ID  = az identity create -n $APP_UAMI -g $GROUP -o tsv --query clientId

# create a managed workload identity for ALB pods
$ALB_UAMI_CLIENT_ID = az identity create -g $GROUP -n $ALB_UAMI -o tsv --query principalId

# get the node resource group and ID
$NODE_RESOURCE_GROUP = az aks show -n $CLUSTER -g $GROUP --query nodeResourceGroup -o tsv
$NODE_RESOURCE_GROUP_ID = az group show -n $NODE_RESOURCE_GROUP --query id -o tsv

# apply Reader role to the AKS managed cluster resource group for the newly provisioned identity
az role assignment create `
    --assignee-object-id $ALB_UAMI_CLIENT_ID `
    --assignee-principal-type ServicePrincipal `
    --scope $NODE_RESOURCE_GROUP_ID `
    --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

# Delegate AppGw for Containers Configuration Manager role to AKS Managed Cluster RG
az role assignment create `
    --assignee-object-id $ALB_UAMI_CLIENT_ID `
    --assignee-principal-type ServicePrincipal `
    --scope $NODE_RESOURCE_GROUP_ID `
    --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" # AppGw for Containers Configuration Manager

# Delegate Network Contributor permission for join to association subnet
az role assignment create `
    --assignee-object-id $ALB_UAMI_CLIENT_ID `
    --assignee-principal-type ServicePrincipal `
    --scope $ALB_SUBNET_ID `
    --role "4d97b98b-1d4f-4787-a291-c67834d212e7" # Network Contributor

# assign current user admin RBAC access to cluster (for portal access and ALB helm chart install)
az role assignment create `
    --assignee $USER_ID `
    --role "Azure Kubernetes Service RBAC Cluster Admin" `
    --scope $AKS_ID

# assign current user admin RBAC access to cluster
az role assignment create `
    --assignee $USER_ID `
    --role "Azure Kubernetes Service RBAC Cluster Admin" `
    --scope $AKS_ID

Start-Sleep -Seconds 10

# get OIDC issuer
$OIDC_ISSUER = az aks show -n $CLUSTER -g $GROUP -o tsv --query oidcIssuerProfile.issuerUrl

# create the federated identity for the app workload
az identity federated-credential create -g $GROUP `
    --name $FEDERATED_NAME `
    --identity-name $APP_UAMI `
    --issuer $OIDC_ISSUER `
    --subject system:serviceaccount:$($NAMESPACE):$($SERVICE_ACCOUNT) `
    --audience api://AzureADTokenExchange

az identity federated-credential create -g $GROUP `
    --name "azure-alb-identity" `
    --identity-name $ALB_UAMI `
    --issuer $OIDC_ISSUER `
    --subject system:serviceaccount:alb:alb-controller-sa

# create the key vault
az keyvault create -n $KEY_VAULT -g $GROUP

# assign the correct role to the UAMI to allow KV access (4633458b-17de-408a-b874-0445c86b69e6 = Key Vault Secrets User)
az role assignment create `
    --role 4633458b-17de-408a-b874-0445c86b69e6 `
    --assignee $APP_UAMI_CLIENT_ID `
    --scope /subscriptions/$SUBSCRIPTION/resourceGroups/$GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT

# sleep to allow propagate
Start-Sleep -Seconds 10

# log into cluster using azure cli for entra
kubelogin convert-kubeconfig -l azurecli

# deploy ALB via Helm
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
    --namespace "alb" `
    --create-namespace `
    --version 1.5.2 `
    --set albController.namespace="alb" `
    --set albController.podIdentity.clientID=$(az identity show -g $GROUP -n $ALB_UAMI --query clientId -o tsv)

"Update spec.associations in ApplicationLoadBalancer manifest: $ALB_SUBNET_ID"
"Set this client ID as the azure.workload.identity/client-id annotation for the service account: $APP_UAMI_CLIENT_ID"