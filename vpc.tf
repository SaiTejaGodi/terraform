variable "project_id" {
  description = "Your GCP project ID"
  default = "nodal-formula-455211-b1"
}

variable "region" {
  description = "GCP region"
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  default     = "us-central1-a"
}


provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# 1. VPC
resource "google_compute_network" "vpc" {
  name                    = "terraformvpc"
  auto_create_subnetworks = false
}

# 2. Subnets
resource "google_compute_subnetwork" "public_subnet" {
  name          = "public-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_subnetwork" "private_subnet" {
  name          = "private-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
  private_ip_google_access = true
}

# 3. Firewall (like AWS SG)
resource "google_compute_firewall" "allow_http_ssh" {
  name    = "allow-http-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web"]
}

# 4. Cloud Router & NAT (for private subnet internet)
resource "google_compute_router" "router" {
  name    = "nat-router"
  region  = var.region
  network = google_compute_network.vpc.name
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-config"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# 5. Instance Template
resource "google_compute_instance_template" "web_template" {
  name           = "web-template"
  machine_type   = "e2-micro"

  tags = ["web"]

  disk {
    auto_delete  = true
    boot         = true
    source_image = "debian-cloud/debian-11"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public_subnet.id

    access_config {
      # Ephemeral external IP
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y apache2
    echo "Hello from $(hostname)" > /var/www/html/index.html
    systemctl enable apache2
    systemctl start apache2
  EOF
}

# 6. Managed Instance Group
resource "google_compute_region_instance_group_manager" "web_mig" {
  name               = "web-mig"
  region             = var.region
  base_instance_name = "web"
  version {
    instance_template = google_compute_instance_template.web_template.id
  }
  target_size = 2
}

# 7. Load Balancer Components
resource "google_compute_health_check" "http" {
  name               = "http-health-check"
  check_interval_sec = 5
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 2

  http_health_check {
    port = 80
  }
}

resource "google_compute_backend_service" "web_backend" {
  name                            = "web-backend"
  protocol                        = "HTTP"
  port_name                       = "http"
  timeout_sec                     = 10
  health_checks                   = [google_compute_health_check.http.id]
  load_balancing_scheme           = "EXTERNAL"

  backend {
    group = google_compute_region_instance_group_manager.web_mig.instance_group
  }
}

resource "google_compute_url_map" "web_map" {
  name            = "web-map"
  default_service = google_compute_backend_service.web_backend.id
}

resource "google_compute_target_http_proxy" "web_proxy" {
  name   = "web-proxy"
  url_map = google_compute_url_map.web_map.id
}

resource "google_compute_global_forwarding_rule" "http_forwarding" {
  name        = "http-forwarding-rule"
  target      = google_compute_target_http_proxy.web_proxy.id
  port_range  = "80"
  load_balancing_scheme = "EXTERNAL"
  ip_protocol = "TCP"
}
