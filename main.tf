terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.16.0"
    }
  }
}

provider "google" {
  project     = var.project_id  # Ensure var.project_id is correctly set
  region      = var.region
  credentials = file(var.credentials_file)
}

resource "google_compute_network" "vpc_network" {
  name                    = var.network_name
  routing_mode            = var.routing_mode  
  auto_create_subnetworks = false
  delete_default_routes_on_create = true
}

resource "google_compute_global_address" "private_service_address" {
  project               = var.project_id
  name         = "private-service-address"
  address_type = "INTERNAL"
  purpose      = "VPC_PEERING"
  prefix_length = 24
  network      = google_compute_network.vpc_network.id

    # Change this to an IP in the DB subnet range
}

resource "google_service_networking_connection" "private_service_forwarding_rule" {
  # provider              = google-beta
  # project               = var.project_id
  # name                  = "private-service-forwarding-rule"
  # target                = "all-apis"
  network               = google_compute_network.vpc_network.name
  service               = "servicenetworking.googleapis.com"    
  reserved_peering_ranges = [google_compute_global_address.private_service_address.name]
  # load_balancing_scheme = ""
}

# Creating subnets
resource "google_compute_subnetwork" "webapp_subnet" {
  name          = var.web_subnet_name
  ip_cidr_range = var.web_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc_network.id
  private_ip_google_access = true
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



resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "instance" {
  project            = var.project_id
  name               = "cloud-database-instance"
  region             = var.region
  database_version   = "MYSQL_5_7"
  deletion_protection = false

  settings {
    tier              = "db-f1-micro"
    availability_type = "REGIONAL"
    disk_type         = "pd-ssd"
    disk_size         = 100

    ip_configuration {
      ipv4_enabled      = false
      private_network   = google_compute_network.vpc_network.self_link
    }

    backup_configuration {
      binary_log_enabled = true  # Enable binary logging
      enabled            = true  # Enable automatic backups
    }
  }

  depends_on = [
    google_service_networking_connection.private_service_forwarding_rule
  ]
}


resource "google_sql_database" "webapp" {
  name     = "webapp"
  instance = google_sql_database_instance.instance.name
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_user" "webapp" {
  name     = "webapp"
  instance = google_sql_database_instance.instance.name
  
  password = random_password.password.result
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
  tags         = ["application-instance"]

  boot_disk {
    initialize_params {
      image = var.boot_disk_image
      type  = "pd-balanced"   
      size  = 100              
    }
  }
   service_account {
    email  = google_service_account.service_account_vm.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  network_interface {
    subnetwork = google_compute_subnetwork.webapp_subnet.self_link
    access_config {}
  }

   metadata_startup_script = <<-EOF
    #!/bin/bash
    echo "DB_DIALECT=mysql" >> /opt/csye6225/.env
    echo "DB_HOST=${google_sql_database_instance.instance.private_ip_address}" >> /opt/csye6225/.env
    echo "DB_USERNAME=${google_sql_user.webapp.name}" >> /opt/csye6225/.env
    echo "DB_PASSWORD=${google_sql_user.webapp.password}" >> /opt/csye6225/.env
    echo "DB_NAME=${google_sql_database.webapp.name}" >> /opt/csye6225/.env
    chmod 600 /opt/csye6225/.env
  EOF
  depends_on = [google_sql_database_instance.instance, google_sql_user.webapp]
}
 
 

resource "google_dns_record_set" "cloudweba_a" {
  name         = "cloudweba.me."
  type         = "A"
  ttl          = 300 # Time to Live (TTL) in seconds
  managed_zone = "cloudweba"
  
  rrdatas = [
    google_compute_instance.web_instance.network_interface[0].access_config[0].nat_ip,
  ]
}

resource "google_service_account" "service_account_vm" {
  account_id   = "my-service-account-vm"
  display_name = "My Service Account for vm"
}

# Bind IAM roles to the service account
resource "google_project_iam_binding" "service_account_logging_admin" {
  project = var.project_id
  role    = "roles/logging.admin"
  members = [
    "serviceAccount:${google_service_account.service_account_vm.email}"
  ]
}

resource "google_project_iam_binding" "service_account_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  members = [
    "serviceAccount:${google_service_account.service_account_vm.email}"
  ]
}



resource "google_compute_firewall" "allow_application_port" {
  name    = "allow-application-port"
  network = google_compute_network.vpc_network.name
  
  allow {
    protocol = "tcp"
    ports    = [var.application_port]  
  }

  source_ranges = ["0.0.0.0/0"]  # Allow traffic from any source
  target_tags         = ["application-instance"]
}

