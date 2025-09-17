# Getting project information
data "google_project" "project" {}

#---------------------------------------------------------------
# VPC Configuration
#---------------------------------------------------------------

# Consumer VPC
module "consumer_vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "consumer-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  region                          = var.location
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

# Producer VPC
module "producer_vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "producer-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  region                          = var.location
  subnets = [
    {
      name                     = "producer-subnet"
      region                   = var.location
      purpose                  = "PRIVATE"
      private_ip_google_access = true
      role                     = "ACTIVE"
      ip_cidr_range            = "10.2.0.0/24"
    }
  ]
  firewall_data = [
    {
      name          = "producer-vpc-firewall-http"
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["80"]
        }
      ]
    }
  ]
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

#---------------------------------------------------------------
# Private Service Connect Configuration
#---------------------------------------------------------------

## IP address ##
# resource "google_compute_address" "consumer_lb_address" {
#   name         = "consumer-lb-address"
#   region       = var.location
#   subnetwork   = module.consumer_vpc.vpc_id
#   address_type = "INTERNAL"
# }

# resource "google_compute_forwarding_rule" "consumer_lb_forwarding_rule" {
#   name                  = "consumer-lb-forwarding-rule"
#   region                = var.location
#   subnetwork            = module.consumer_vpc.vpc_id
#   ip_protocol           = "TCP"
#   load_balancing_scheme = "INTERNAL_MANAGED"
#   port_range            = "80"
#   target                = google_compute_region_target_tcp_proxy.consumer_lb_region_target_tcp_proxy.id

#   depends_on = [
#     google_compute_subnetwork.consumer_proxy_only
#   ]
# }

# resource "google_compute_region_target_tcp_proxy" "consumer_lb_region_target_tcp_proxy" {
#   backend_service = google_compute_region_backend_service.consumer_lb_backend_service.id
#   name            = "consumer-lb-region-target-tcp-proxy"
#   region          = var.location
# }

# # Backend service targeting the PSC NEG #
# resource "google_compute_region_backend_service" "consumer_lb_backend_service" {
#   name                  = "consumer-lb-backend-service"
#   region                = var.location
#   load_balancing_scheme = "INTERNAL_MANAGED"
#   protocol              = "TCP"
#   # No health checks due PSC

#   backend {
#     group          = google_compute_region_network_endpoint_group.consumer_neg.id
#     balancing_mode = ""
#   }
# }

# # PSC Neg targeting the producer service
# resource "google_compute_region_network_endpoint_group" "consumer_neg" {
#   name                  = "consumer-neg"
#   region                = var.location
#   network_endpoint_type = "PRIVATE_SERVICE_CONNECT"
#   psc_target_service    = var.service_attachment_id
#   network               = module.consumer_vpc.vpc_id
#   subnetwork            = google_compute_subnetwork.consumer_proxy_only.id
# }

# #---------------------------------------------------------------
# # Consumer Instance Configuration
# #---------------------------------------------------------------

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
      network    = "${module.consumer_vpc.vpc_id}"
      subnetwork = "${module.consumer_vpc.subnets[0].id}"
      access_configs = [
        {
          nat_ip = "${google_compute_address.consumer_instance_address.address}"
        }
      ]
    }
  ]
}

# #---------------------------------------------------------------
# # Private Service Connect Configuration
# #---------------------------------------------------------------

# # IP Address
# resource "google_compute_address" "consumer_endpoint_address" {
#   name         = "consumer-apache-web-server-endpoint"
#   region       = var.location
#   subnetwork   = module.consumer_subnet.subnets[0].id
#   address_type = "INTERNAL"
# }

# # PSC endpoint
# resource "google_compute_forwarding_rule" "consumer_endpoint" {
#   name                  = "consumer-endpoint"
#   region                = var.location
#   network               = module.consumer_vpc.vpc_id
#   ip_address            = google_compute_address.consumer_endpoint_address.id
#   target                = var.service_attachment_id
#   load_balancing_scheme = "" # Explicit empty string required for PSC
# }

# resource "google_compute_service_attachment" "apache_web_server" {
#   name                  = "apache-web-server"
#   region                = var.location
#   connection_preference = "ACCEPT_MANUAL"
#   reconcile_connections = true
#   enable_proxy_protocol = false
#   target_service        = google_compute_forwarding_rule.apache_web_server_ilb.id
#   nat_subnets           = [
#     google_compute_subnetwork.web_app_nat.id
#   ]

#   dynamic "consumer_accept_lists" {
#     for_each = var.accepted_consumers
#     content {
#       connection_limit  = consumer_accept_lists.value.connection_limit
#       project_id_or_num = consumer_accept_lists.value.project_number
#     }
#   }
# }