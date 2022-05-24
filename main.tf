provider "aws" {
  default_tags {
    tags = var.tags
  }
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca_certificate
  token                  = local.cluster_auth_token
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca_certificate
    token                  = local.cluster_auth_token
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

data "aws_eks_cluster_auth" "auth" {
  name = module.eks.cluster_id
}

data "aws_region" "current" {}

data "aws_route53_zone" "domain" {
  name = var.domain_name
}

locals {
  availability_zones     = slice(data.aws_availability_zones.available.names, 0, var.zone_count)
  aws_account_id         = data.aws_caller_identity.current.account_id
  aws_region             = data.aws_region.current.name
  cluster_auth_token     = data.aws_eks_cluster_auth.auth.token
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  default_storage_class  = "gp2"
  kubeconfig_file        = "${path.cwd}/${var.kubeconfig_file}"
  oidc_issuer            = trimprefix(module.eks.cluster_oidc_issuer_url, "https://")
  this                   = toset(["this"])
}


################################################################################
# Amazon EKS cluster
################################################################################

module "iam" {
  source = "./modules/eks-iam-roles"

  cluster_name = var.cluster_name
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.17.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version
  create_iam_role = false
  enable_irsa     = true
  iam_role_arn    = module.iam.cluster_role_arn
  subnet_ids      = var.subnet_ids
  vpc_id          = var.vpc_id

  eks_managed_node_group_defaults = {
    min_size     = var.node_group_min_size
    max_size     = var.node_group_max_size
    desired_size = var.node_group_desired_size

    create_iam_role       = false
    create_security_group = false
    iam_role_arn          = module.iam.node_role_arn
    instance_types        = var.instance_types
    key_name              = var.key_name
    labels                = {}
    launch_template_tags  = var.tags
  }

  eks_managed_node_groups = { for index, zone in local.availability_zones :
    "${var.cluster_name}-${zone}" => {
      subnet_ids = [var.subnet_ids[index]]
    }
  }

  node_security_group_additional_rules = {
    egress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      self        = true
    }

    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
}


################################################################################
# Amazon Certificate Manager certificate(s)
################################################################################

module "acm_certificate" {
  source   = "./modules/acm-certificate"

  domain_name = var.domain_name
  subdomain   = "*"
}


################################################################################
# Kubernetes resources
################################################################################

module "aws_load_balancer_controller" {
  depends_on = [module.acm_certificate, module.eks]
  source     = "./modules/aws-load-balancer-controller"

  aws_account_id            = local.aws_account_id
  aws_region                = local.aws_region
  cluster_name              = var.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_security_group_id    = module.eks.node_security_group_id
  oidc_issuer               = local.oidc_issuer
}

module "cluster_autoscaler" {
  depends_on = [module.eks]
  source     = "./modules/cluster-autoscaler-eks"

  aws_account_id     = local.aws_account_id
  aws_region         = local.aws_region
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  oidc_issuer        = local.oidc_issuer
}

module "ebs_driver" {
  depends_on = [module.eks]
  source     = "./modules/aws-ebs-csi-driver"

  aws_account_id   = local.aws_account_id
  aws_region       = local.aws_region
  cluster_name     = var.cluster_name
  oidc_issuer      = local.oidc_issuer
  volume_tags      = var.tags
}

module "external_dns" {
  depends_on = [module.eks]
  source     = "./modules/external-dns-eks"

  aws_account_id  = local.aws_account_id
  cluster_name    = var.cluster_name
  oidc_issuer     = local.oidc_issuer
  route53_zone_id = data.aws_route53_zone.domain.id
}


################################################################################
# Post-provisioning commands
################################################################################

resource "null_resource" "update_kubeconfig" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_id} --kubeconfig ${local.kubeconfig_file}"
  }
}

resource "null_resource" "update_default_storage_class" {
  depends_on = [module.ebs_driver]

  provisioner "local-exec" {
    command = "kubectl annotate --overwrite storageclass ${local.default_storage_class} storageclass.kubernetes.io/is-default-class=false"
    environment = {
      KUBECONFIG = local.kubeconfig_file
    }
  }

  provisioner "local-exec" {
    command = "kubectl annotate --overwrite storageclass ${module.ebs_driver.storage_class_name} storageclass.kubernetes.io/is-default-class=true"
    environment = {
      KUBECONFIG = local.kubeconfig_file
    }
  }
}
