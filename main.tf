terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.16.0"
    }
  }
}

data "google_project" "project" {
  project_id = var.project_id
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
    export MAILGUN_API_KEY=${var.mailgun_api_key}
    export MAILGUN_DOMAIN=${var.mailgun_domain}
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

resource "google_dns_record_set" "spf_record" {
  name         = "cloudweba.me."
  type         = "TXT"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.cloudweba.name
  
  rrdatas = [
    "v=spf1 include:mailgun.org ~all"
  ]
}

resource "google_dns_record_set" "dkim_record" {
  name         = "mailo._domainkey.cloudweba.me."
  type         = "TXT"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.cloudweba.name

  rrdatas = [
    "k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIPvwSO8CEH69agLvhF/2IQNTNrtoo33gqXpA69KztILjx3tN914BiAOYO15pqXWsUWf7cqkPcRnIKdB/Zkp3OHaTgT2Oklf6zz2N24fuz3UNp2Z6wyXJq8+ILUhPvLpe2aziG5wa9jDGo4qSQnEnovVv0ZxoC3eZ6PtKsf5oSEwIDAQAB"
  ]
}

resource "google_dns_record_set" "mx_records" {
  name         = "cloudweba.me."
  type         = "MX"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.cloudweba.name

  rrdatas = [
    "10 mxa.mailgun.org.",
    "10 mxb.mailgun.org."
  ]
}

resource "google_dns_record_set" "cname_record" {
  name         = "email.cloudweba.me."
  type         = "CNAME"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.cloudweba.name

  rrdatas = [
    "mailgun.org."
  ]
}

resource "google_project_iam_binding" "service_account_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  members = ["serviceAccount:${google_service_account.service_account_vm.email}"]
}
resource "google_pubsub_topic" "verify_email" {
  name = "verify_email"
}

resource "google_pubsub_subscription" "pubsub_user_subscription" {
  name  = "pubsub_user_subscription"
  topic = "projects/${var.project_id}/topics/${google_pubsub_topic.verify_email.name}"

  ack_deadline_seconds = 10
}

data "google_dns_managed_zone" "cloudweba" {
  name = "cloudweba"
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

resource "google_service_account" "cdn_service_account" {
  account_id   = "my-cdn-service-account"
  display_name = "Service Account for CDN"
}


resource "google_pubsub_topic_iam_binding" "pubsub_publisher_binding" {
  topic = google_pubsub_topic.verify_email.id
  role  = "roles/pubsub.publisher"

  members = [
    "serviceAccount:${google_service_account.cdn_service_account.email}",
  ]
}

resource "google_storage_bucket" "bucket" {
  name     = "${var.project_id}-gcf-source"  # Every bucket name must be globally unique
  location = "US"
  uniform_bucket_level_access = true
}
 
resource "google_storage_bucket_object" "object" {
  name   = "function-source.zip"
  bucket = google_storage_bucket.bucket.name
  source = "cloud_function.zip"  # Add path to the zipped function source code
}
 
 resource "google_project_service" "serverless_vpc_access_api" {
  service            = "vpcaccess.googleapis.com"
  disable_on_destroy = false
}

resource "google_vpc_access_connector" "serverless_connector" {
  depends_on = [
    google_project_service.serverless_vpc_access_api,
    google_compute_network.vpc_network
  ]

  name          = "serverless-vpc-connector"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc_network.id
  ip_cidr_range = "10.0.5.0/28" # Choose a range that does not overlap with existing subnets.
}



resource "google_project_iam_member" "cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.cdn_service_account.member
}



# // Adjust the following Cloud Function resource to use the newly created bucket
resource "google_cloudfunctions2_function" "email_verification" {
  name        = "emailVerificationFunction"
  location    = var.region
  description = "Function to send verification email upon user creation"

  build_config {
    entry_point = "handleNewUser"
   
    runtime     = "nodejs14" // Ensure you use the correct runtime for your function

    source {
      storage_source {
        bucket = google_storage_bucket.bucket.name
        object = google_storage_bucket_object.object.name
      }
    }

    environment_variables = {
      // Define your environment variables here
      DB_NAME         = google_sql_database.webapp.name
      DB_USER         = google_sql_user.webapp.name
      DB_PASSWORD     = google_sql_user.webapp.password
      DB_HOST         = google_sql_database_instance.instance.private_ip_address
      MAILGUN_API_KEY = var.mailgun_api_key
      MAILGUN_DOMAIN  = var.mailgun_domain
      // Any other env vars your function needs
    }
  }

  service_config {
    available_memory   = "256M" // Match this to the expected memory need of your function
    timeout_seconds    = 120
    min_instance_count = 0
    max_instance_count = 1 // Adjust max instances as needed for your use case
    ingress_settings   = "ALLOW_INTERNAL_ONLY" // Change to ""ALLOW_ALL"" or "ALLOW_INTERNAL_AND_GCLB" as per your needs
    all_traffic_on_latest_revision = true
    // Uncomment the next line if you have a dedicated service account
    service_account_email = google_service_account.cdn_service_account.email

  }

  event_trigger {
    event_type   = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic = google_pubsub_topic.verify_email.id
    retry_policy = "RETRY_POLICY_RETRY"

  }
}

resource "google_project_iam_member" "cloud_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.cdn_service_account.email}"
}


// IAM role for Cloud Storage view access

resource "google_storage_bucket_iam_member" "cloud_function_bucket_object_viewer" {
  bucket = google_storage_bucket.bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cdn_service_account.email}"
}


//cf subscriber to the pub/sub topic
resource "google_pubsub_subscription_iam_binding" "cloud_function_subscriber" {
  subscription = google_pubsub_subscription.pubsub_user_subscription.name
  role         = "roles/pubsub.subscriber"

  members = [
    "serviceAccount:${google_service_account.cdn_service_account.email}",
  ]
}

resource "google_pubsub_topic_iam_member" "subscriber_member" {
  topic  = google_pubsub_topic.verify_email.id
  role   = "roles/pubsub.subscriber"
  member = "serviceAccount:${google_service_account.cdn_service_account.email}"
}

// IAM Binding for the Cloud Functions Service Account:
resource "google_project_iam_member" "cloudfunctions_developer" {
  project = var.project_id
  role    = "roles/cloudfunctions.developer"
  member  = "serviceAccount:${google_service_account.cdn_service_account.email}"
}




// IAM Binding for the Service Agent Role
resource "google_project_iam_member" "service_agent" {
  project = var.project_id
  role    = "roles/cloudfunctions.serviceAgent"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcf-admin-robot.iam.gserviceaccount.com"
}




output "cloud_function_name" {
  value = google_cloudfunctions2_function.email_verification.name
}

output "cloud_function_pubsub_topic" {
  value = google_pubsub_topic.verify_email.name
}




# # IAM policy for Cloud Functions CloudFunction
# data "google_iam_policy" "cf" {
#   binding {
#     role = "roles/viewer"

#     members = [
#       "serviceAccount:${google_service_account.cdn_service_account.email}",
#     ]
#   }
# }

# resource "google_cloudfunctions_function_iam_policy" "function_iam_policy" {
#   project        = var.project
#   region         = var.region
#   cloud_function = google_cloudfunctions2_function.email_verification.name

#   policy_data = data.google_iam_policy.cf.policy_data
#   depends_on = [google_cloudfunctions2_function.email_verification]
# }



# # IAM policy for Pub/Sub Subscription

data "google_iam_policy" "subscriber" {
  binding {
    role = "roles/editor"

    members = [
      "serviceAccount:${google_service_account.cdn_service_account.email}",
    ]
  }
}
resource "google_pubsub_subscription_iam_policy" "subscription_iam_policy" {
  subscription = google_pubsub_subscription.pubsub_user_subscription.name
  project      = var.project_id

  policy_data = data.google_iam_policy.subscriber.policy_data
}



////////

# # IAM policy for Cloud Pub/Sub Topic

data "google_iam_policy" "admin" {
  binding {
    role = "roles/viewer"

    members = [
      "serviceAccount:${google_service_account.cdn_service_account.email}",
    ]
  }
}
resource "google_pubsub_topic_iam_policy" "topic_iam_policy" {
  topic   = google_pubsub_topic.verify_email.name
  project = var.project_id

  policy_data = data.google_iam_policy.admin.policy_data
}



# Outputs
output "instance_name" {
  value = google_compute_instance.web_instance.name
}

output "sql_instance_private_ip" {
  value = google_sql_database_instance.instance.private_ip_address
}