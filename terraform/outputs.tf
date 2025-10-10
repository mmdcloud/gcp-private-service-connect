output "psc_consumer_ip" {
  value       = google_compute_address.psc_consumer_ip.address
  description = "The IP address of the PSC endpoint in the consumer VPC."
}

output "consumer_vpc_self_link" {
  value = module.consumer_vpc.self_link
}

output "producer_vpc_self_link" {
  value = module.producer_vpc.self_link
}
