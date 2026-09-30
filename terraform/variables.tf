variable "expected_account_id" {
  description = "Account ID to deploy into. Provider refuses any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Must be a 12-digit account ID."
  }
}

variable "region" {
  type    = string
  default = "ca-central-1"
}

variable "availability_zones" {
  description = "Two AZs. Everything runs in the first; the second only holds the extra control plane subnet EKS requires."
  type        = list(string)
  default     = ["ca-central-1a", "ca-central-1b"]

  validation {
    condition     = length(var.availability_zones) == 2 && alltrue([for az in var.availability_zones : startswith(az, var.region)])
    error_message = "Need exactly two AZs in var.region."
  }
}

variable "name_prefix" {
  type    = string
  default = "demo"
}

variable "admin_principal_arn" {
  description = "IAM role that runs terraform. Becomes KMS key admin and the lockout exception on the secret policy."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.admin_principal_arn))
    error_message = "Must be an IAM role ARN."
  }
}

variable "human_principal_arns" {
  description = "Who can assume the break-glass / operator / developer roles. Empty = admin only."
  type        = list(string)
  default     = []
}

variable "alert_email" {
  type = string
}

variable "vpc_cidr" {
  description = "If you change this, update the CIDRs in the kubernetes network policies too."
  type        = string
  default     = "10.20.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "node_instance_type" {
  type    = string
  default = "t3.large"
}

variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "admin_host_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "rotation_days" {
  type    = number
  default = 30
}

variable "public_endpoint_cidrs" {
  description = "Temporary exception only (see ADR 0001). Opens the API endpoint to these CIDRs."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.public_endpoint_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0" && tonumber(split("/", c)[1]) >= 24])
    error_message = "Valid CIDRs, /24 or narrower, never 0.0.0.0/0."
  }
}

# optional paid stuff, all off by default (cost in README)

variable "enable_nat" {
  description = "NAT gateway, ~35 USD/month. Off = no internet egress at all."
  type        = bool
  default     = false
}

variable "enable_guardduty" {
  type    = bool
  default = false
}

variable "enable_guardduty_runtime_monitoring" {
  type    = bool
  default = false
}

variable "enable_config" {
  type    = bool
  default = false
}
