output "psc_consumer_ip" {
  value       = google_compute_address.psc_consumer_ip.address
  description = "The IP address of the PSC endpoint in the consumer VPC."
}