#---------------------------------------------------------------
# VPC Configuration
#---------------------------------------------------------------

# Consumer VPC
module "consumer_vpc" {
  source                  = "../modules/network/vpc"
  auto_create_subnetworks = false
  vpc_name                = "consumer-vpc"
}

# Consumer Subnet
module "consumer_subnet" {
  source                   = "../modules/network/subnet"
  name                     = "consumer-vpc-subnet"
  subnets                  = ["10.1.0.0/24"]
  vpc_id                   = module.consumer_vpc.vpc_id
  private_ip_google_access = true
  location                 = var.location
}

# Producer VPC
module "producer_vpc" {
  source                  = "../modules/network/vpc"
  auto_create_subnetworks = false
  vpc_name                = "producer-vpc"
}

# Producer Subnet
module "producer_subnet" {
  source                   = "../modules/network/subnet"
  name                     = "producer-vpc-subnet"
  subnets                  = ["10.2.0.0/24"]
  vpc_id                   = module.producer_vpc.vpc_id
  private_ip_google_access = true
  location                 = var.location
}

#---------------------------------------------------------------
# Artifact Registry
#---------------------------------------------------------------
module "artifact_registry" {
  source        = "../modules/artifact-registry"
  location      = var.location
  description   = "cloud run code repository"
  repository_id = "cloud-run-repo"
  shell_command = "bash ${path.cwd}/../../src/artifact_push.sh"
}

#---------------------------------------------------------------
# Load Balancer
#---------------------------------------------------------------

## IP address ##
resource "google_compute_address" "consumer_apache_web_server_ilb" {
  name         = "consumer-apache-web-server-ilb"
  region       = var.location
  subnetwork   = google_compute_subnetwork.consumer_load_balancer.id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "consumer_apache_web_server_ilb" {
  name                  = "consumer-apache-web-server-ilb"
  region                = var.location
  subnetwork            = google_compute_subnetwork.consumer_load_balancer.id
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_tcp_proxy.consumer_apache_web_server.id

  depends_on = [
    google_compute_subnetwork.proxy_only
  ]
}

resource "google_compute_region_target_tcp_proxy" "consumer_apache_web_server" {
  backend_service = google_compute_region_backend_service.consumer_apache_web_server.id
  name            = "consumer-apache-web-server"
  region          = var.location
}

# Backend service targeting the PSC NEG #
resource "google_compute_region_backend_service" "consumer_apache_web_server" {
  name                  = "consumer-apache-web-server"
  region                = var.location
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "TCP"
  # No health checks due PSC

  backend {
    group          = google_compute_region_network_endpoint_group.apache_web_server.id
    balancing_mode = ""
  }
}

# PSC Neg targeting the producer service
resource "google_compute_region_network_endpoint_group" "apache_web_server" {
  name                  = "apache-web-server"
  region                = var.region
  network_endpoint_type = "PRIVATE_SERVICE_CONNECT"
  psc_target_service    = var.service_attachment_id
  network               = google_compute_network.consumer_load_balancer.id
  subnetwork            = google_compute_subnetwork.consumer_load_balancer.id
}


#---------------------------------------------------------------
# Cloud Run Service
#---------------------------------------------------------------
module "cloud_run_service" {
  source                           = "../modules/cloud-run"
  deletion_protection              = false
  ingress                          = "INGRESS_TRAFFIC_ALL"
  vpc_connector_name               = module.carshub_vpc_connectors.vpc_connectors[0].id
  service_account                  = module.carshub_cloud_run_service_account.sa_email
  location                         = var.location
  min_instance_count               = 2
  max_instance_count               = 5
  max_instance_request_concurrency = 80
  name                             = "carshub-frontend-service"
  volumes                          = []
  traffic = [
    {
      traffic_type         = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
      traffic_type_percent = 100
    }
  ]
  containers = [
    {
      env               = []
      volume_mounts     = []
      cpu_idle          = true
      startup_cpu_boost = true
      image             = "${var.location}-docker.pkg.dev/${data.google_project.project.project_id}/carshub-frontend/carshub-frontend:latest"
    }
  ]
  depends_on = [module.carshub_frontend_artifact_registry, module.carshub_apis, module.carshub_cloud_run_service_account]
}

#---------------------------------------------------------------
# Consumer Instance Configuration
#---------------------------------------------------------------

resource "google_compute_address" "consumer_instance_address" {
  name = "consumer-instance-address"
}

# Consumer Instance
module "consumer_instance" {
  source                    = "./modules/compute"
  name                      = "consumer-instance"
  machine_type              = "e2-micro"
  zone                      = "us-central1-a"
  metadata_startup_script   = "sudo apt-get update; sudo apt-get install nginx -y"
  deletion_protection       = false
  allow_stopping_for_update = true
  image                     = "ubuntu-os-cloud/ubuntu-2004-focal-v20220712"
  network_interfaces = [
    {
      network    = module.consumer_vpc.vpc_id
      subnetwork = module.consumer_vpc.subnets[0].id
      access_configs = [
        {
          nat_ip = google_compute_address.consumer_instance_address.address
        }
      ]
    }
  ]
}

#---------------------------------------------------------------
# Private Service Connect Configuration
#---------------------------------------------------------------
# IP Address
resource "google_compute_address" "consumer_apache_web_server_endpoint" {
  name         = "consumer-apache-web-server-endpoint"
  region       = var.location
  subnetwork   = google_compute_subnetwork.consumer_endpoint.id
  address_type = "INTERNAL"
}

# PSC endpoint
resource "google_compute_forwarding_rule" "consumer_endpoint" {
  name                    = "consumer-endpoint"
  region                  = var.location
  network                 = google_compute_network.consumer_endpoint.id
  ip_address              = google_compute_address.consumer_apache_web_server_endpoint.id
  target                  = var.service_attachment_id
  load_balancing_scheme   = "" # Explicit empty string required for PSC
}