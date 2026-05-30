# aws-init

CDP Workload Environment 用の **AWS 基盤（VPC / IAM / S3 / Security Groups）** を先行作成する Terraform です。

- Phase 1: `aws-init`（本フォルダ）
- Phase 2: `aws-ingress` / `aws-egress` + MC Proxy 登録
- Phase 3: `aws`（CDP Environment / Datalake 作成）

## 使い方

```bash
cp envs/fullprivate-init.tfvars.example envs/fullprivate-init.tfvars
# 値を編集

terraform init
terraform plan -var-file=envs/fullprivate-init.tfvars
terraform apply -var-file=envs/fullprivate-init.tfvars
```

## 主な出力（後続ステップで利用）

- `aws_vpc_id`
- `aws_vpc_cidr`
- `aws_private_route_table_ids`
- `aws_key_pair_name`

```bash
terraform output aws_vpc_id
terraform output aws_vpc_cidr
```

`aws/` は `../aws-init/terraform.tfstate` を参照して CDP 環境を作成します。
