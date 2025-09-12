# VPC Module
module "consumer_vpc" {
  source                  = "./modules/vpc"
  vpc_name                = "consumer-vpc"
  auto_create_subnetworks = false
  vpc_connectors = []
  subnets = [
    {
      name          = "consumer-vpc-subnet"
      region        = var.location
      ip_cidr_range = "10.0.1.0/24"
    }
  ]
}

# VPC Module
module "producer_vpc" {
  source                  = "./modules/vpc"
  vpc_name                = "producer-vpc"
  auto_create_subnetworks = false
  vpc_connectors = []
  subnets = [
    {
      name          = "producer-vpc-subnet"
      region        = var.location
      ip_cidr_range = "10.0.1.0/24"
    }
  ]
}