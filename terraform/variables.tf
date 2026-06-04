variable "project" {
  description = "Project identifier used in resource names and tags"
  type        = string
  default     = "pe-platform"
}

variable "env" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "prefix" {
  description = "Short prefix for globally unique resource names (e.g. 'scp3' for Summit Capital Partners III)"
  type        = string
  default     = "scp3"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "pe-platform"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "data-engineering"
  }
}
