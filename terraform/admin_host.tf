# Tunnel host. No SSH, no key pair, no public IP, no inbound rules.
# People reach the private API with SSM port forwarding through it and run
# kubectl on their laptop with their own role, so the host itself has no
# cluster access at all (see ADR 0001).

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "admin_host_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "admin_host" {
  name               = "${local.name}-tunnel-host"
  assume_role_policy = data.aws_iam_policy_document.admin_host_trust.json
}

resource "aws_iam_role_policy_attachment" "admin_host_ssm" {
  role       = aws_iam_role.admin_host.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "admin_host" {
  name = "${local.name}-tunnel-host"
  role = aws_iam_role.admin_host.name
}

resource "aws_security_group" "admin_host" {
  name        = "${local.name}-tunnel-host"
  description = "SSM tunnel host, no inbound"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "admin_host_endpoints" {
  security_group_id = aws_security_group.admin_host.id
  description       = "SSM endpoints"
  cidr_ipv4         = local.subnet_cidrs.endpoints
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "admin_host_api" {
  for_each = toset(["control_plane_a", "control_plane_b"])

  security_group_id = aws_security_group.admin_host.id
  description       = "EKS private endpoint"
  cidr_ipv4         = local.subnet_cidrs[each.value]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_instance" "admin_host" {
  # checkov:skip=CKV_AWS_126: detailed monitoring not needed for a tunnel box
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.admin_host_instance_type
  subnet_id                   = aws_subnet.private["workload"].id
  vpc_security_group_ids      = [aws_security_group.admin_host.id]
  iam_instance_profile        = aws_iam_instance_profile.admin_host.name
  associate_public_ip_address = false
  ebs_optimized               = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.ebs.arn
  }

  tags = {
    Name    = "${local.name}-tunnel-host"
    Purpose = "eks-tunnel" # the human roles can only start sessions on this tag
  }

  # AMI resolves to latest at first apply; don't rebuild the box every time a
  # new one comes out
  lifecycle {
    ignore_changes = [ami]
  }
}
