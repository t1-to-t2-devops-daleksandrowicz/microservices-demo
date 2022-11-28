resource "aws_vpc" "this" {
  cidr_block = "10.1.0.0/16"

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge({
    "Name"                                      = format("%s-vpc", var.name)
    "kubernetes.io/cluster/${var.name}-cluster" = "shared"
  }, var.tags)
}

resource "aws_subnet" "public" {
  count = var.availability_zones_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge({
    "Name"                                      = format("%s-public-subnet", var.name)
    "kubernetes.io/cluster/${var.name}-cluster" = "shared"
    "kubernetes.io/role/elb"                    = 1
  }, var.tags)

  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count = var.availability_zones_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, count.index + var.availability_zones_count)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge({
    "Name"                                      = format("%s-private-subnet", var.name)
    "kubernetes.io/cluster/${var.name}-cluster" = "shared"
    "kubernetes.io/role/internal-elb"           = 1
  }, var.tags)
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge({
    "Name" = format("%s-igw", var.name)
  }, var.tags)

  depends_on = [aws_vpc.this]
}

# Route the public subnet traffic through the IGW
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge({
    "Name" = format("%s-default-route", var.name)
  }, var.tags)
}

resource "aws_route_table_association" "internet_access" {
  count = var.availability_zones_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.main.id
}

resource "aws_eip" "main" {
  vpc = true

  tags = merge({
    "Name" = format("%s-ngw-ip", var.name)
  }, var.tags)
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.main.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge({
    "Name" = format("%s-ngw", var.name)
  }, var.tags)
}

# Add route to route table
resource "aws_route" "main" {
  route_table_id         = aws_vpc.this.default_route_table_id
  nat_gateway_id         = aws_nat_gateway.main.id
  destination_cidr_block = "0.0.0.0/0"
}

# Security group for public subnet
resource "aws_security_group" "public" {
  name   = format("%s-public-sg", var.name)
  vpc_id = aws_vpc.this.id

  tags = merge({
    "Name" = format("%s-public-sg", var.name)
  }, var.tags)
}

resource "aws_security_group_rule" "ingress_public_443" {
  security_group_id = aws_security_group.public.id
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "ingress_public_80" {
  security_group_id = aws_security_group.public.id
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "egress_public" {
  security_group_id = aws_security_group.public.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Security group for data plane
resource "aws_security_group" "data_plane" {
  name   = format("%s-data-plane-sg", var.name)
  vpc_id = aws_vpc.this.id

  tags = merge({
    "Name" = format("%s-data-plane-sg", var.name)
  }, var.tags)
}

# Security group traffic rules
resource "aws_security_group_rule" "nodes" {
  description       = "Allow nodes to communicate with each other"
  security_group_id = aws_security_group.data_plane.id
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  cidr_blocks       = flatten([cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 0), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 1), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 2), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 3)])
}

resource "aws_security_group_rule" "nodes_inbound" {
  description       = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  security_group_id = aws_security_group.data_plane.id
  type              = "ingress"
  from_port         = 1025
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = flatten([cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 2), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 3)])
}

resource "aws_security_group_rule" "node_outbound" {
  security_group_id = aws_security_group.data_plane.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Security group for control plane
resource "aws_security_group" "control_plane_sg" {
  name   = format("%s-control-plane-sg", var.name)
  vpc_id = aws_vpc.this.id

  tags = merge({
    "Name" = format("%s-control-plane-sg", var.name)
  }, var.tags)
}

resource "aws_security_group_rule" "control_plane_inbound" {
  security_group_id = aws_security_group.control_plane_sg.id
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = flatten([cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 0), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 1), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 2), cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, 3)])
}

resource "aws_security_group_rule" "control_plane_outbound" {
  security_group_id = aws_security_group.control_plane_sg.id
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}