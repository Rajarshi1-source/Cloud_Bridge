variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "origin_cidrs" {
  type = list(string)
}

variable "tags" {
  type = map(string)
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vm" {
  name               = "${var.name}-vm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Ansible connects via SSM, no SSH
}

# Ansible's aws_ssm connection plugin moves files through S3, so the VM (and the CI role that runs
# Ansible) need a transfer bucket. Short-lived objects only; never a place for state or secrets.
resource "aws_s3_bucket" "ssm_transfer" {
  bucket_prefix = "${var.name}-ssm-"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  rule {
    id     = "expire-transfers"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

data "aws_iam_policy_document" "ssm_transfer" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
  statement {
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.ssm_transfer.arn]
  }
}

resource "aws_iam_role_policy" "ssm_transfer" {
  name   = "ssm-transfer"
  role   = aws_iam_role.vm.id
  policy = data.aws_iam_policy_document.ssm_transfer.json
}

resource "aws_iam_instance_profile" "vm" {
  name = "${var.name}-vm"
  role = aws_iam_role.vm.name
}

resource "aws_security_group" "vm" {
  name   = "${var.name}-vm"
  vpc_id = var.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "https_from_cloudflare" {
  for_each          = toset(var.origin_cidrs)
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "vm" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.vm.id]
  iam_instance_profile   = aws_iam_instance_profile.vm.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = var.name, "cb-ansible-role" = "k3s_server", "cb-k8s-minor" = var.k8s_version })

  lifecycle {
    ignore_changes = [ami] # OS upgrades = planned rebuild, not drift
  }
}

resource "aws_eip" "vm" {
  domain   = "vpc"
  instance = aws_instance.vm.id
  tags     = var.tags
}

output "cluster" {
  value = {
    name                = var.name
    endpoint            = "https://127.0.0.1:6443" # API never exposed; reached via SSM port-forward
    ca_certificate      = ""
    k8s_version         = var.k8s_version
    origin              = aws_eip.vm.public_ip
    node_security_group = aws_security_group.vm.id
    auth                = { kind = "k3s-ssm", instance_id = aws_instance.vm.id, transfer_bucket = aws_s3_bucket.ssm_transfer.bucket }
  }
}
