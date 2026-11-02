variable "name" {
  type = string
}

variable "env" {
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

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name   = "${var.name}-db"
  vpc_id = var.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "pg" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.allowed_sg
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "random_password" "admin" {
  length  = 32
  special = false
}

# {username, password}, the same shape as Cloud SQL's secret, so one ExternalSecret reads both.
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}-db-admin"
  recovery_window_in_days = var.env == "prod" ? 7 : 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "cell_admin", password = random_password.admin.result })
}

resource "aws_db_instance" "this" {
  identifier                 = var.name
  engine                     = "postgres"
  engine_version             = var.engine_version
  instance_class             = "db.t4g.micro"
  allocated_storage          = 20
  storage_type               = "gp3"
  storage_encrypted          = true
  db_name                    = "cell"
  username                   = "cell_admin"
  password                   = random_password.admin.result
  multi_az                   = var.env == "prod"
  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [aws_security_group.db.id]
  backup_retention_period    = 7
  deletion_protection        = var.env == "prod"
  skip_final_snapshot        = var.env != "prod"
  final_snapshot_identifier  = "${var.name}-final"
  auto_minor_version_upgrade = true
  tags                       = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

output "database" {
  value = {
    host       = aws_db_instance.this.address
    port       = aws_db_instance.this.port
    secret_ref = aws_secretsmanager_secret.db.arn
  }
}
