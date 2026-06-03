# aws-egress

CDP Workload VPC のアウトバウンド通信を、Egress VPC 上の非透過プロキシ（Squid）で制御するための Terraform 雛形です。

## この雛形で作成するもの

- Egress VPC (`10.98.0.0/24`)
- Public subnet（NAT Gateway 用）
- Private subnet（Squid proxy 用）
- Squid proxy EC2（固定 private IP、public IP なし）
- CDP VPC との VPC Peering と相互ルート

## 前提

- `aws-init` が適用済み（`peer_vpc_id` / `peer_vpc_cidr` は tfvars に設定。private route table ID は `aws-init` の state から自動取得）
- 同一 AWS アカウント内で peering を `auto_accept` できる
- CDP 側は Management Console の `Shared Resources > Proxies` で Proxy 登録して利用する

## 使い方

1. 変数ファイルを作成

```bash
cp envs/fullprivate.tfvars.example envs/fullprivate.tfvars
```

2. 値を環境に合わせて編集（`peer_vpc_id` など）

3. 適用

```bash
terraform init
terraform plan -var-file=envs/fullprivate.tfvars
terraform apply -var-file=envs/fullprivate.tfvars
```

4. 出力値確認（MC登録用）

```bash
terraform output mc_proxy_registration
terraform output -raw knox_jvm_proxy_opts
```

`knox_jvm_proxy_opts` は Cloudera AI **Registry および AI Inference**（Compute Cluster）作成後の Knox パッチ（DSE-48642）用 JVM 文字列です。適用手順は `docs/ai-registry-full-private.md`、`docs/ai-inference-full-private.md` および `scripts/patch-ai-registry-knox-proxy.sh` を参照。

`mc_proxy_no_proxy_hosts`（または `terraform output mc_proxy_registration` の `no_proxy_hosts`）は MC Proxy 登録時の **No Proxy Hosts** にそのまま使用します。`localhost,127.0.0.1` のみでは S3 向け通信が Squid 経由になり Model Hub / Model Endpoint が失敗しやすいです。

## Proxy 登録（Management Console）

- `Shared Resources > Proxies > Create Proxy Configuration` で登録
- `terraform output mc_proxy_registration` の値を入力
- **`No Proxy Hosts` には `no_proxy_hosts`（または `terraform output -raw mc_proxy_no_proxy_hosts`）を漏れなく設定** — 詳細は `docs/deployment-procedure-full-private.md` Step 4
- 登録済み Proxy Configuration は後編集不可のため、変更時は再登録

## ポリシー方針

- CCM v2 は次を許可（ワークロードリージョン `ap-1` と Jumpgate relay の `us-west-1` の両方）
  - `*.v2.ccm.ap-1.cdp.cloudera.com`
  - `*.v2.us-west-1.ccm.cdp.cloudera.com`
- Compute Cluster（Liftie / EKS ワーカー）向け
  - `*.us-west-1.cdp.cloudera.com`
  - `*.monitoring.us-west-1.cdp.cloudera.com`
  - `dbusapi.us-west-1.sigma.altus.cloudera.com`
  - `cloudformation.ap-northeast-1.amazonaws.com`（`cfn-signal --https-proxy` 用。VPC Endpoint があっても Proxy 経由）
- GitHub は `github.com` / `raw.githubusercontent.com` のドメイン許可のみで制御
- PyPI（Cloudera AI Workbench 等での `pip install`）は以下を許可
  - `pypi.org`
  - `files.pythonhosted.org`
  - `pypi.python.org`
  - `test.pypi.org`
  - `test-files.pythonhosted.org`
- NVIDIA NGC は以下を許可
  - `api.ngc.nvidia.com`
  - `files.ngc.nvidia.com`
  - `xfiles.ngc.nvidia.com`
  - `prod.otel.kaizen.nvidia.com`
  - `nvcr.io`
  - `ngc.nvidia.com`
  - `authn.nvidia.com`
- 許可リストは `allowed_fqdns` 変数で管理
- `allowed_fqdns` を変更した場合は `terraform apply` で Proxy EC2 が再作成される（`user_data_replace_on_change` + `replace_triggered_by`）。Private IP は固定のため MC Proxy 登録の Server Host は通常変更不要
- 過去に `allowed_fqdns` だけ変更して in-place 更新された場合は、一度 `terraform apply -replace=aws_instance.proxy` で再作成する

## 動作確認（CLI）

### Peering が active であることを確認

```bash
EGRESS_PCX_ID=$(terraform output -raw egress_peering_connection_id)
AWS_PROFILE=<YOUR_AWS_PROFILE> AWS_REGION=<YOUR_AWS_REGION> \
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "${EGRESS_PCX_ID}" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text
```

期待値: `active`

### Proxy 経由の到達性確認（Proxy インスタンス上）

```bash
AWS_PROFILE=<YOUR_AWS_PROFILE>
AWS_REGION=<YOUR_AWS_REGION>
ENV_PREFIX=<YOUR_ENV_PREFIX>

PROXY_INSTANCE_ID=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Name,Values=${ENV_PREFIX}-egress-proxy" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

CMD_ID=$(aws ssm send-command \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --instance-ids "${PROXY_INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --comment "Proxy connectivity test for CDP/NGC" \
  --parameters 'commands=[
    "set -e",
    "for host in api.ap-1.cdp.cloudera.com api.ngc.nvidia.com files.ngc.nvidia.com xfiles.ngc.nvidia.com prod.otel.kaizen.nvidia.com nvcr.io github.com; do echo === ${host} ===; curl -sS -o /dev/null -w \"%{http_code}\\n\" -x http://127.0.0.1:3128 https://${host}; done"
  ]' \
  --query 'Command.CommandId' \
  --output text)

aws ssm get-command-invocation \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --command-id "${CMD_ID}" \
  --instance-id "${PROXY_INSTANCE_ID}" \
  --query '{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' \
  --output json
```
