output "cluster" {
  value = {
    name                = aws_eks_cluster.this.name
    endpoint            = aws_eks_cluster.this.endpoint
    ca_certificate      = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    k8s_version         = aws_eks_cluster.this.version
    origin              = null # ALB hostname appears after the controller runs → 20-bootstrap output
    node_security_group = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
    auth                = { kind = "aws-eks", cluster_name = aws_eks_cluster.this.name }
  }
}
