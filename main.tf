terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.16.0"
    }
  }
}

provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = file(var.credentials_file)
}

resource "google_compute_network" "vpc_network" {
  name                    = var.network_name
  routing_mode            = "REGIONAL"  
  auto_create_subnetworks = false
  delete_default_routes_on_create = true
}

# Creating subnets
resource "google_compute_subnetwork" "webapp_subnet" {
  name          = var.web_subnet_name
  ip_cidr_range = var.web_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_subnetwork" "db_subnet" {
  name          = var.db_subnet_name
  ip_cidr_range = var.db_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

# Add route for webapp subnet
resource "google_compute_route" "webapp_route" {
  name                  = "webapp-route"
  network               = google_compute_network.vpc_network.self_link
  dest_range            = var.route_dest_range
  next_hop_gateway      = var.route_next_hop
}
