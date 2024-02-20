variable "project_id" {
  description = "The ID of the Google Cloud project"
  type        = string
}

variable "region" {
  description = "The region for the resources"
  type        = string
}

variable "zone" {
  description = "The zone for the resources"
  type        = string
}

variable "credentials_file" {
  description = "Path to the service account JSON key file"
  type        = string
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
}

variable "web_subnet_name" {
  description = "Name of the web subnet"
  type        = string
}

variable "web_subnet_cidr" {
  description = "CIDR block for the web subnet"
  type        = string
}

variable "db_subnet_name" {
  description = "Name of the database subnet"
  type        = string
}

variable "db_subnet_cidr" {
  description = "CIDR block for the database subnet"
  type        = string
}

variable "route_dest_range" {
  description = "Destination CIDR range for the route"
  type        = string
}

variable "route_next_hop" {
  description = "Next hop gateway for the route"
  type        = string
}

variable "application_port" {
  description = "Port number on which the application listens"
  type        = number
}