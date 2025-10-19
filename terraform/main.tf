#---------------------------------------------------------------
# Getting the public IP of the user
#---------------------------------------------------------------
data "http" "local_ip" {
  url = "https://ifconfig.me"
}

locals {
  local_ip = data.http.local_ip.response_body
}

#---------------------------------------------------------------
# Getting project information
#---------------------------------------------------------------
data "google_project" "project" {}

#---------------------------------------------------------------
# VPC Configuration
#---------------------------------------------------------------
module "consumer_vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "consumer-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets = [
    {
      name                     = "consumer-subnet"
      region                   = var.location
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.1.0.0/24"
    }
  ]
  firewall_data = [
    {
      name          = "consumer-vpc-firewall-ssh"
      target_tags   = ["consumer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["22"]
        }
      ]
    },
    {
      name          = "consumer-vpc-firewall-http"
      target_tags   = ["consumer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["80"]
        }
      ]
    },
  ]
}

module "producer_vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "producer-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets = [
    {
      name                     = "producer-subnet"
      region                   = "${var.location}"
      purpose                  = "PRIVATE"
      private_ip_google_access = true
      role                     = "ACTIVE"
      ip_cidr_range            = "10.2.0.0/24"
    },
    {
      name                     = "psc-subnet"
      region                   = "${var.location}"
      purpose                  = "PRIVATE_SERVICE_CONNECT"
      private_ip_google_access = true
      role                     = "ACTIVE"
      ip_cidr_range            = "10.20.0.0/24"
    },
    {
      name                     = "proxy-only-subnet"
      region                   = "${var.location}"
      purpose                  = "REGIONAL_MANAGED_PROXY"
      private_ip_google_access = false
      role                     = "ACTIVE"
      ip_cidr_range            = "10.129.0.0/23"
    }
  ]
  firewall_data = []
}

#---------------------------------------------------------------
# Artifact Registry
#---------------------------------------------------------------
module "artifact_registry" {
  source        = "./modules/artifact-registry"
  location      = var.location
  description   = "nodeapp code repository"
  repository_id = "nodeapp"
  shell_command = "bash ${path.cwd}/../src/artifact_push.sh ${data.google_project.project.project_id}"
}

#---------------------------------------------------------------
# Cloud Run Service
#---------------------------------------------------------------
module "cloud_run_service_account" {
  source        = "./modules/service-account"
  account_id    = "cloud-run-sa"
  display_name  = "Cloud Run Service Account"
  project_id    = data.google_project.project.project_id
  member_prefix = "serviceAccount"
  permissions = [
    "roles/artifactregistry.reader"
  ]
}

module "cloud_run_service" {
  source                           = "./modules/cloud-run"
  deletion_protection              = false
  ingress                          = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  service_account                  = module.cloud_run_service_account.sa_email
  location                         = var.location
  min_instance_count               = 2
  max_instance_count               = 5
  max_instance_request_concurrency = 80
  name                             = "nodeapp"
  volumes                          = []
  traffic = [
    {
      traffic_type         = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
      traffic_type_percent = 100
    }
  ]
  containers = [
    {
      port              = 8080
      env               = []
      volume_mounts     = []
      cpu_idle          = true
      startup_cpu_boost = true
      image             = "${var.location}-docker.pkg.dev/${data.google_project.project.project_id}/nodeapp/nodeapp:latest"
    }
  ]
  depends_on = [module.artifact_registry]
}

resource "google_cloud_run_service_iam_member" "cloud_run_access" {
  location = var.location
  project  = var.project_id
  service  = module.cloud_run_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
#---------------------------------------------------------------
# Load Balancer Configuration
#---------------------------------------------------------------
module "service_neg" {
  source       = "./modules/network_endpoint_groups"
  neg_name     = "service-neg"
  neg_type     = "SERVERLESS"
  location     = var.location
  service_name = module.cloud_run_service.name
}

resource "google_compute_region_backend_service" "default" {
  name                  = "cloudrun-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  locality_lb_policy    = "ROUND_ROBIN"
  region                = var.location
  backend {
    group = module.service_neg.id
  }
}

resource "google_compute_region_url_map" "default" {
  name            = "url-map"
  region          = var.location
  default_service = google_compute_region_backend_service.default.id
}

resource "google_compute_region_target_http_proxy" "default" {
  name    = "internal-http-proxy"
  region  = var.location
  url_map = google_compute_region_url_map.default.id
}

resource "google_compute_forwarding_rule" "default" {
  name                  = "ilb-forwarding-rule"
  region                = var.location
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  network               = module.producer_vpc.vpc_id
  subnetwork            = module.producer_vpc.subnets[0].id
  ip_protocol           = "TCP"
}

#---------------------------------------------------------------
# Private Service Connect Configuration
#---------------------------------------------------------------
resource "google_compute_service_attachment" "psc_attachment" {
  name                  = "psc-attachment"
  region                = var.location
  description           = "Private Service Connect attachment for Cloud Run"
  project               = var.project_id
  enable_proxy_protocol = false
  connection_preference = "ACCEPT_AUTOMATIC"
  nat_subnets           = [module.producer_vpc.subnets[1].id]
  target_service        = google_compute_forwarding_rule.default.id
}

#---------------------------------------------------------------
# Consumer Instance Configuration
#---------------------------------------------------------------
resource "google_compute_address" "psc_consumer_ip" {
  project      = var.project_id
  name         = "psc-consumer-ip"
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
  region       = var.location
  subnetwork   = module.consumer_vpc.subnets[0].id
}

resource "google_compute_forwarding_rule" "psc_consumer_forwarding_rule" {
  name                  = "psc-consumer-forwarding-rule"
  project               = var.project_id
  region                = var.location
  load_balancing_scheme = ""
  target                = "projects/${var.project_id}/regions/${var.location}/serviceAttachments/${google_compute_service_attachment.psc_attachment.name}"
  ip_address            = google_compute_address.psc_consumer_ip.self_link
  network               = module.consumer_vpc.vpc_id
}

resource "google_compute_address" "consumer_instance_address" {
  name = "consumer-instance-address"
}

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
      network    = "${module.consumer_vpc.vpc_id}"
      subnetwork = "${module.consumer_vpc.subnets[0].id}"
      access_configs = [
        {
          nat_ip = "${google_compute_address.consumer_instance_address.address}"
        }
      ]
    }
  ]
  tags = ["consumer-instance"]
}