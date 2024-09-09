param (
    [Parameter(Mandatory=$true)]
    [string]$CredsFile,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$false)]
    [string]$Prefix = "ailurus",

    [Parameter(Mandatory=$false)]
    [string]$Zone = "us-central1"
)

# Define variables
$KEY_FILE = $CredsFile
$PROJECT_ID = $ProjectId
$INSTANCE_PREFIX = $Prefix
$ZONE = $Zone

# Authenticate the service account
gcloud auth activate-service-account --key-file=$KEY_FILE

# Define CIDR ranges
$PLATFORM_CIDR = "10.0.38.0/24"
$PUBLIC_CIDR = "10.0.47.0/24"
$GKE_NODE_CIDR = "10.0.32.0/22"
$GKE_TEAMLB_CIDR = "10.0.16.0/20"

# Create GCP network
gcloud beta compute networks create "$INSTANCE_PREFIX-network" --project=$PROJECT_ID `
    --subnet-mode=custom --mtu=1460 --bgp-routing-mode=regional --bgp-best-path-selection-mode=legacy

# Create subnets
gcloud compute networks subnets create "$INSTANCE_PREFIX-platform-subnet" --project=$PROJECT_ID `
    --description="Subnet for Ailurus webapp, worker, and checker." --range=$PLATFORM_CIDR `
    --stack-type=IPV4_ONLY --network="$INSTANCE_PREFIX-network" --region=$ZONE --enable-private-ip-google-access

gcloud compute networks subnets create "$INSTANCE_PREFIX-public-subnet" --project=$PROJECT_ID `
    --description="For VPN server and other public instances." --range=$PUBLIC_CIDR `
    --stack-type=IPV4_ONLY --network="$INSTANCE_PREFIX-network" --region=$ZONE

gcloud compute networks subnets create "$INSTANCE_PREFIX-gke-node-subnet" --project=$PROJECT_ID `
    --description="Subnet for all the GKE node" --range=$GKE_NODE_CIDR `
    --stack-type=IPV4_ONLY --network="$INSTANCE_PREFIX-network" --region=$ZONE --enable-private-ip-google-access

gcloud compute networks subnets create "$INSTANCE_PREFIX-gke-teamlb-subnet" --project=$PROJECT_ID `
    --description="Subnet for GKE team load balancer" --range=$GKE_TEAMLB_CIDR `
    --stack-type=IPV4_ONLY --network="$INSTANCE_PREFIX-network" --region=$ZONE --enable-private-ip-google-access

# Add firewall
gcloud compute firewall-rules create "$INSTANCE_PREFIX-allow-node-to-platform-http" --project=$PROJECT_ID `
    --network="projects/$PROJECT_ID/global/networks/$INSTANCE_PREFIX-network" `
    --description="Allow all HTTP/s connection from GKE instances to platform subnet." `
    --direction=EGRESS --priority=65000 --destination-ranges="$PLATFORM_CIDR" `
    --target-tags="$INSTANCE_PREFIX-gke-instance" --action=ALLOW --rules=tcp:443,tcp:80
gcloud compute firewall-rules create "$INSTANCE_PREFIX-deny-node-to-platform" --project=$PROJECT_ID `
    --network="projects/$PROJECT_ID/global/networks/$INSTANCE_PREFIX-network" `
    --description="Deny all outgoing connection to platform subnet." `
    --direction=EGRESS --priority=65500 --destination-ranges="$PLATFORM_CIDR" `
    --target-tags="$INSTANCE_PREFIX-gke-instance" --action=DENY --rules=all
gcloud compute firewall-rules create "$INSTANCE_PREFIX-allow-custom" --project=$PROJECT_ID `
    --network="projects/$PROJECT_ID/global/networks/$INSTANCE_PREFIX-network" `
    --description="Allows connection from any source to any instance on the network using custom protocols." `
    --direction=INGRESS --priority=65534 --source-ranges="$PLATFORM_CIDR,$PUBLIC_CIDR,$GKE_NODE_CIDR,$GKE_TEAMLB_CIDR" `
    --action=ALLOW --rules=all
gcloud compute firewall-rules create "$INSTANCE_PREFIX-allow-icmp" --project=$PROJECT_ID `
    --network="projects/$PROJECT_ID/global/networks/$INSTANCE_PREFIX-network" `
    --description="Allows ICMP connections from any source to any instance on the network." `
    --direction=INGRESS --priority=65534 --source-ranges=0.0.0.0/0 --action=ALLOW --rules=icmp
gcloud compute firewall-rules create "$INSTANCE_PREFIX-allow-ssh" --project=$PROJECT_ID `
    --network="projects/$PROJECT_ID/global/networks/$INSTANCE_PREFIX-network" `
    --description="Allows TCP connections from any source to any instance on the network using port 22." `
    --direction=INGRESS --priority=65534 --source-ranges=0.0.0.0/0 --action=ALLOW --rules=tcp:22

# Add NAT gateway
gcloud compute routers create "$INSTANCE_PREFIX-router" --region $ZONE --network "$INSTANCE_PREFIX-network" --project=$PROJECT_ID
gcloud beta compute routers nats create "$INSTANCE_PREFIX-nat" --router="$INSTANCE_PREFIX-router" --region=$ZONE --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --project=$PROJECT_ID

# Create image repository
gcloud artifacts repositories create "$INSTANCE_PREFIX-image-artifact" --repository-format=docker --location=$ZONE --project=$PROJECT_ID `
    --labels=managed-by=ailurus

# Create storage bucket
gcloud storage buckets create "gs://$INSTANCE_PREFIX-image-assets" --location=$ZONE --public-access-prevention

# Create Kubernetes engine cluster
gcloud beta container --project $PROJECT_ID clusters create-auto "$INSTANCE_PREFIX-gke-cluster" --region "$ZONE" `
    --release-channel "stable" --enable-private-nodes `
    --private-endpoint-subnetwork="projects/$PROJECT_ID/regions/$ZONE/subnetworks/$INSTANCE_PREFIX-public-subnet" `
    --network "projects/$PROJECT_ID/global/networks/$INSTANCE_PREFIX-network" `
    --subnetwork "projects/$PROJECT_ID/regions/$ZONE/subnetworks/$INSTANCE_PREFIX-gke-node-subnet" `
    --cluster-ipv4-cidr "/17" --binauthz-evaluation-mode=DISABLED --async `
    --autoprovisioning-network-tags="$INSTANCE_PREFIX-gke-instance"

# Display the configuration details for further use
$credentials = Get-Content $KEY_FILE | ConvertFrom-Json
$details = @{
    "credentials" = $credentials
    "zone" = $ZONE
    "artifact_registry" = "$INSTANCE_PREFIX-image-artifact"
    "storage_bucket" = "$INSTANCE_PREFIX-image-assets"
    "gke_cluster" = "$INSTANCE_PREFIX-gke-cluster"
    "build_in_cloudbuild" = "true"
    "loadbalancer_cidr" = $GKE_TEAMLB_CIDR
    "network" = "$INSTANCE_PREFIX-network"
}

Write-Host "Update 'gcp-k8s' entry in provision machine section with this detail:"
$details | ConvertTo-Json | Write-Host