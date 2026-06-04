terraform {
  backend "s3" {
    bucket       = "yugesh-simple-terraform-state-2026"
    key          = "infra/terraform.tfstate"
    region       = "ap-south-1"
  }
}
