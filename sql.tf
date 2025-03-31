variable "project_id" {
  description = "Your GCP Project ID"
}

variable "region" {
  description = "Region to deploy resources"
  default     = "us-central1"
}

variable "db_version" {
  description = "Database version (e.g. MYSQL_8_0, POSTGRES_15)"
  default     = "MYSQL_8_0"
}

variable "db_password" {
  description = "Database user password"
  sensitive   = true
}

variable "devops_engineer_email" {
  description = "DevOps engineer or app email to grant IAM access"
}


output "db_instance_name" {
  value = google_sql_database_instance.db_instance.name
}

output "private_ip" {
  value = google_sql_database_instance.db_instance.private_ip_address
}

output "db_user" {
  value = google_sql_user.default_user.name
}

output "db_name" {
  value = google_sql_database.default_db.name
}


provider "google" {
  project = var.project_id
  region  = var.region
}

# VPC Network for private access
resource "google_compute_network" "private_vpc" {
  name                    = "sql-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "sql-private-subnet"
  ip_cidr_range            = "10.10.0.0/24"
  region                   = var.region
  network                  = google_compute_network.private_vpc.id
  private_ip_google_access = true
}

# VPC peering for private IP access
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.private_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "sql-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private_vpc.id
}

# Cloud SQL Instance
resource "google_sql_database_instance" "db_instance" {
  name             = "devops-db"
  region           = var.region
  database_version = var.db_version
  deletion_protection = false

  settings {
    tier = "db-f1-micro" # for demo/testing; change to "db-custom-1-3840" for prod

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.private_vpc.id
    }

    backup_configuration {
      enabled            = true
      start_time         = "01:00"
      binary_log_enabled = true
    }

    maintenance_window {
      day          = 7    # Sunday
      hour         = 3    # 3 AM
      update_track = "stable"
    }

    availability_type = "REGIONAL" # or ZONAL
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# SQL User
resource "google_sql_user" "default_user" {
  name     = "devops_user"
  instance = google_sql_database_instance.db_instance.name
  password = var.db_password
}

# SQL Database
resource "google_sql_database" "default_db" {
  name     = "devopsdb"
  instance = google_sql_database_instance.db_instance.name
}

# IAM binding (optional: for GCP-managed service accounts or apps)
resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "user:${var.devops_engineer_email}"
}
