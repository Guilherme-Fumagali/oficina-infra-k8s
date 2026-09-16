resource "aws_vpc" "oficina" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name                                  = "${local.nome}-vpc"
    "kubernetes.io/cluster/${local.nome}" = "shared"
  }
}

resource "aws_default_security_group" "padrao" {
  vpc_id = aws_vpc.oficina.id

  tags = { Name = "${local.nome}-default-sg" }
}

resource "aws_internet_gateway" "oficina" {
  vpc_id = aws_vpc.oficina.id
  tags   = { Name = "${local.nome}-igw" }
}

resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs

  vpc_id                  = aws_vpc.oficina.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name                                  = "${local.nome}-public-${each.key}"
    "kubernetes.io/cluster/${local.nome}" = "shared"
    "kubernetes.io/role/elb"              = "1"
  }
}

resource "aws_subnet" "private" {
  for_each = var.private_subnet_cidrs

  vpc_id                  = aws_vpc.oficina.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name                                  = "${local.nome}-private-${each.key}"
    "kubernetes.io/cluster/${local.nome}" = "shared"
    "kubernetes.io/role/internal-elb"     = "1"
  }
}

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

resource "aws_security_group" "nat" {
  name        = "${local.nome}-nat-sg"
  description = "NAT instance: aceita trafego das subnets privadas e sai para a internet"
  vpc_id      = aws_vpc.oficina.id

  tags = { Name = "${local.nome}-nat-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "nat_das_privadas" {
  for_each = var.private_subnet_cidrs

  security_group_id = aws_security_group.nat.id
  description       = "Trafego das subnets privadas (${each.key})"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_para_internet" {
  security_group_id = aws_security_group.nat.id
  description       = "Saida para a internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "nat" {
  ami           = data.aws_ami.al2023_arm.id
  instance_type = var.nat_instance_type
  subnet_id     = values(aws_subnet.public)[0].id

  vpc_security_group_ids = [aws_security_group.nat.id]

  source_dest_check = false
  ebs_optimized     = true

  root_block_device {
    encrypted = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euo pipefail
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-nat.conf

    dnf install -y --setopt=install_weak_deps=False iptables-services
    IFACE=$(ip -o -4 route show to default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    iptables -F FORWARD
    service iptables save
    systemctl enable --now iptables
  EOT

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = { Name = "${local.nome}-nat" }
}

resource "aws_eip" "nat" {
  instance = aws_instance.nat.id
  domain   = "vpc"

  tags = { Name = "${local.nome}-nat-eip" }

  depends_on = [aws_internet_gateway.oficina]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.oficina.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.oficina.id
  }

  tags = { Name = "${local.nome}-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.oficina.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  tags = { Name = "${local.nome}-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.oficina.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.nome}-s3-endpoint" }
}

resource "aws_security_group" "lambda" {
  name        = "${local.nome}-lambda-sg"
  description = "Lambda de autenticacao por CPF dentro da VPC"
  vpc_id      = aws_vpc.oficina.id

  tags = { Name = "${local.nome}-lambda-sg" }
}

resource "aws_vpc_security_group_egress_rule" "lambda_saida" {
  security_group_id = aws_security_group.lambda.id
  description       = "Saida para o RDS e servicos AWS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
