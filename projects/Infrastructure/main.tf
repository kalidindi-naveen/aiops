module "vpc" {
  source = "./modules/vpc"

  vpc_name     = var.vpc_name
  cidr_block   = var.vpc_cidr
  subnet_cidrs = [for s in var.subnets : s.cidr_block]
  availability_zones = [for s in var.subnets : s.availability_zone]
  cluster_name     = var.cluster_name
}


module "eks" {
  source = "./modules/eks"

  cluster_name     = var.cluster_name
  node_group_name  = var.node_group_name

  instance_types = var.instance_types
  min_size       = var.min_size
  desired_size   = var.desired_size
  max_size       = var.max_size

  subnet_ids = module.vpc.subnet_ids
  depends_on = [module.vpc]
}

module "ecr" {
  source = "./modules/ecr"

  repositories = var.repositories
}


data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name
}

data "aws_caller_identity" "current" {}

provider "kubernetes" {
  alias                  = "eks"
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

provider "helm" {
  alias = "eks"

  kubernetes =  {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
}

# Configure kubeconfig and patch aws-auth ConfigMap
resource "terraform_data" "aws_auth_config" {
  depends_on = [module.eks]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -e
      
      # Update kubeconfig
      aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name} 2>/dev/null || true
      
      # Wait for aws-auth ConfigMap to be created
      echo "Waiting for aws-auth ConfigMap to be available..."
      for i in {1..30}; do
        if kubectl get configmap aws-auth -n kube-system 2>/dev/null; then
          echo "aws-auth ConfigMap found"
          break
        fi
        echo "Attempt $i: Waiting for aws-auth ConfigMap..."
        sleep 2
      done
      
      # Patch the configmap to add current user
      kubectl patch configmap aws-auth -n kube-system --type merge \
        -p "{\"data\":{\"mapUsers\":\"- userarn: arn:aws:iam::${data.aws_caller_identity.current.account_id}:root\n  username: admin\n  groups:\n  - system:masters\"}}" \
        2>/dev/null || echo "ConfigMap already up to date or does not exist yet"
    EOT
  }
}


module "argocd" {
  source = "./modules/argocd"

  providers = {
    kubernetes = kubernetes.eks
    helm       = helm.eks
  }

  depends_on = [module.eks, terraform_data.aws_auth_config]
}

