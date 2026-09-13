data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "oficina-api-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "oficina-api-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr_readonly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_node_ssm" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_eks_cluster" "oficina" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids = concat(
      [for s in aws_subnet.private : s.id],
      [for s in aws_subnet.public : s.id],
    )

    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

resource "aws_eks_access_entry" "admin" {
  count         = var.cluster_admin_principal_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.oficina.name
  principal_arn = var.cluster_admin_principal_arn
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.cluster_admin_principal_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.oficina.name
  principal_arn = var.cluster_admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

resource "aws_eks_access_entry" "ci" {
  count         = var.ci_role_principal_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.oficina.name
  principal_arn = var.ci_role_principal_arn
}

resource "aws_eks_access_policy_association" "ci" {
  count         = var.ci_role_principal_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.oficina.name
  principal_arn = var.ci_role_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["oficina"]
  }

  depends_on = [aws_eks_access_entry.ci]
}

resource "aws_eks_node_group" "oficina" {
  cluster_name    = aws_eks_cluster.oficina.name
  node_group_name = "oficina-api-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn

  subnet_ids     = [for s in aws_subnet.private : s.id]
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr_readonly,
    aws_route_table_association.private,
  ]
}
