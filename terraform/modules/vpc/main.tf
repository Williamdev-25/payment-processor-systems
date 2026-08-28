# =============================================================================
# VPC — 2-AZ network for the EKS cluster
# =============================================================================
# Public subnets: NAT gateways + any public-facing load balancers.
# Private subnets: EKS nodes and everything else that shouldn't be directly
# internet-reachable. This 2-tier split (rather than adding a third private
# "data" tier like a DB-only subnet) is intentionally minimal — this
# platform's only stateful dependency, if any, would sit behind its own
# managed service, not a self-hosted DB in this network.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name}-public-${count.index}"
    "kubernetes.io/role/elb" = "1" # lets EKS auto-discover this subnet for public load balancers
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                              = "${var.name}-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1" # for internal load balancers
    "kubernetes.io/cluster/${var.name}-eks" = "shared" # required for EKS subnet auto-discovery
  }
}

# One NAT gateway per AZ, not a single shared one — a single NAT gateway
# is a cost-saver but becomes a single point of failure for all outbound
# traffic from every private subnet. For a fintech-style "high
# availability" requirement, per-AZ NAT is the correct default, not an
# afterthought.
resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet, each pointing at its own AZ's NAT
# gateway — keeps traffic within the same AZ rather than crossing AZs
# through a neighbor's NAT, which avoids unnecessary cross-AZ data transfer
# cost and avoids a shared failure point.
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = { Name = "${var.name}-private-rt-${count.index}" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
