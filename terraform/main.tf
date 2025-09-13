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
  subnets                  = var.public_subnets
  vpc_id                   = module.consumer_vpc.vpc_id
  private_ip_google_access = false
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
  subnets                  = var.private_subnets
  vpc_id                   = module.producer_vpc.vpc_id
  private_ip_google_access = true
  location                 = var.location
}

# Artifact Registry
module "artifact_registry" {
  source        = "../modules/artifact-registry"
  location      = var.location
  description   = "CarHub frontend repository"
  repository_id = "carshub-frontend"
  shell_command = "bash ${path.cwd}/../../../../src/frontend/artifact_push.sh http://${module.carshub_backend_service_lb.ip_address} ${module.carshub_cdn.cdn_ip_address} ${data.google_project.project.project_id}"
  depends_on    = [module.carshub_backend_service, module.carshub_apis]
}

# Load Balancer
module "lb" {
  source                   = "../modules/load-balancer"
  forwarding_port_range    = "80"
  forwarding_rule_name     = "carshub-frontend-service-global-forwarding-rule"
  forwarding_scheme        = "EXTERNAL"
  global_address_type      = "EXTERNAL"
  url_map_name             = "carshub-frontend-service-compute-url-map"
  global_address_name      = "carshub-frontend-service-lb-global-address"
  target_proxy_name        = "carshub-frontend-service-target-proxy"
  backend_service_name     = "carshub-frontend-compute"
  backend_service_protocol = "HTTP"
  backend_service_timeout  = 30
  backends = [
    {
      backend = module.carshub_frontend_service_neg.id
    }
  ]
  depends_on = [module.carshub_frontend_service]
}

# Cloud Run Service
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