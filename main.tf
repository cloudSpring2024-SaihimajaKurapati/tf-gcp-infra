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

# Create a firewall rule to block traffic to the SSH port
resource "google_compute_firewall" "block_ssh_port" {
  name    = "block-ssh-port"
  network = google_compute_network.vpc_network.name

  deny {
    protocol = "tcp"
    ports    = ["22"]  # SSH port
  }

  source_ranges = ["0.0.0.0/0"]  # Allow traffic from any source
}

# Create a Compute Engine instance
resource "google_compute_instance" "web_instance" {
  name         = "web-instance"
  machine_type = "e2-small"  
  zone         = var.zone
  tags         = ["ssh-restricted"]

  boot_disk {
    initialize_params {
      image = "projects/cloudgcp-414104/global/images/custom-image-1708459507"  
      type  = "pd-balanced"   
      size  = 100              
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.webapp_subnet.self_link
    access_config {}
  }
}