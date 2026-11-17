# =============================================================================
# AWS Provider Configuration
# =============================================================================
provider "aws" {
  region = var.region
}

# =============================================================================
# Variables
# =============================================================================
variable "region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "instance_count" {
  description = "Number of EC2 instances to create"
  default     = 2
}

variable "eni_count_per_instance" {
  description = "Number of Elastic Network Interfaces per instance"
  default     = 10
}

variable "private_ip_count_per_eni" {
  description = "Number of secondary private IPs per ENI"
  default     = 100
}

# NOTE: t3.micro has 2 vCPUs but only supports 2 ENIs (including primary).
# To support 10 ENIs per instance, you need a larger instance type
# (e.g., m5.8xlarge supports 8 ENIs). Adjust as needed or request a
# quota increase from AWS.
variable "instance_type" {
  description = "EC2 instance type (t3.micro = 2 vCPU). See note above for ENI limits."
  default     = "t3.micro"
}

# =============================================================================
# Data Source: Latest Ubuntu 20.04 LTS AMI
# =============================================================================
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# VPC & Networking
# =============================================================================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "main-vpc"
    Environment = "Dev"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "main-igw"
    Environment = "Dev"
  }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name        = "main-subnet"
    Environment = "Dev"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "main-rt"
    Environment = "Dev"
  }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# =============================================================================
# Security Group — Allow SSH
# =============================================================================
resource "aws_security_group" "main" {
  name        = "allow-ssh"
  description = "Allow SSH inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "allow-ssh"
    Environment = "Dev"
  }
}

# =============================================================================
# EC2 Instances — Ubuntu, 2 vCPU, 50GB EBS
# =============================================================================
resource "aws_instance" "ubuntu" {
  count         = var.instance_count
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id     = aws_subnet.main.id

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = {
    Name        = "ubuntu-instance-${count.index + 1}"
    Environment = "Dev"
  }
}

# =============================================================================
# Elastic Network Interfaces — 10 ENIs per instance, 100 private IPs each
# =============================================================================
resource "aws_network_interface" "eni" {
  count            = var.instance_count * var.eni_count_per_instance
  subnet_id        = aws_subnet.main.id
  private_ip_count = var.private_ip_count_per_eni
  security_groups  = [aws_security_group.main.id]

  # Attach each ENI to the appropriate instance.
  # device_index 0 is the primary ENI (auto-created at launch),
  # so attached ENIs use indices 1–9 (or up to the instance type limit).
  attachment {
    instance     = aws_instance.ubuntu[floor(count.index / var.eni_count_per_instance)].id
    device_index = (count.index % var.eni_count_per_instance) + 1
  }

  tags = {
    Name        = "eni-instance-${floor(count.index / var.eni_count_per_instance) + 1}-slot-${(count.index % var.eni_count_per_instance) + 1}"
    Environment = "Dev"
  }
}