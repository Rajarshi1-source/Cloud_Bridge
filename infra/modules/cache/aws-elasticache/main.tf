variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_sg" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "tags" {
  type = map(string)
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "cache" {
  name   = "${var.name}-cache"
  vpc_id = var.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "valkey" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = var.allowed_sg
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = var.name
  description                = "CloudBridge cell cache"
  engine                     = "valkey"
  engine_version             = var.engine_version
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.cache.id]
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  tags                       = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

output "cache" {
  value = {
    host = aws_elasticache_replication_group.this.primary_endpoint_address
    port = 6379
    tls  = true
  }
}
