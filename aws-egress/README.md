# aws-egress

CDP Workload VPC のアウトバウンド通信を、Egress VPC 上の非透過プロキシ（Squid）で制御するための Terraform 雛形です。

## この雛形で作成するもの

- Egress VPC (`10.98.0.0/24`)
- Public subnet（NAT Gateway 用）
- Private subnet（Squid proxy 用）
- Squid proxy EC2（固定 private IP、public IP なし）
- CDP VPC との VPC Peering と相互ルート

## 前提

- `aws/` で CDP Workload Environment が作成済み
- `peer_vpc_id`, `peer_vpc_cidr`, `peer_private_route_table_name` が分かる
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
```

## Proxy 登録（Management Console）

- `Shared Resources > Proxies > Create Proxy Configuration` で登録
- `terraform output mc_proxy_registration` の値を入力
- 登録済み Proxy Configuration は後編集不可のため、変更時は再登録

## ポリシー方針

- CCM v2 は `*.v2.ccm.ap-1.cdp.cloudera.com` の FQDN で制御
- GitHub は `github.com` / `raw.githubusercontent.com` のドメイン許可のみで制御
- NVIDIA NGC は以下を許可
  - `api.ngc.nvidia.com`
  - `files.ngc.nvidia.com`
  - `xfiles.ngc.nvidia.com`
  - `prod.otel.kaizen.nvidia.com`
  - `nvcr.io`
  - `ngc.nvidia.com`
  - `authn.nvidia.com`
- 許可リストは `allowed_fqdns` 変数で管理

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
