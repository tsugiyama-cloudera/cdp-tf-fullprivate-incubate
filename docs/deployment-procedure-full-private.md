# Cloudera on Cloud フルプライベート環境 構築手順（AWS）

## 1. 目的

本手順は、以下の前提でフルプライベート構成を構築するための実行手順を定義する。

- `aws` は既存Quick Start定義をそのまま利用
- `docs/aws-private.tfvars.template` を任意名の `.tfvars` ファイルにコピーして利用
- `aws-ingress` は既存構成を利用
- `aws-egress` は本リポジトリの雛形を利用

## 2. 前提条件

- AWS認証情報（Profileまたは環境変数）が設定済み
- CDP Terraform Provider利用に必要な認証情報が設定済み
- Terraform `>= 1.5.7` を利用
- CIDR重複がないこと
  - Ingress VPC: `10.99.0.0/24`
  - Egress VPC: `10.98.0.0/24`
  - CDP Workload VPC: 重複しない別CIDR

## 3. 構築全体の流れ

1. `aws` でCDP Workload Environment（privateテンプレート）を構築
2. `aws-ingress` でIngress VPC + Bastion + Peeringを構築
3. `aws-egress` でEgress VPC + Squid + Peeringを構築
4. CDP Management Console の `Shared Resources > Proxies` でProxy登録
5. 環境登録時にProxyを関連付け（必要に応じてCLI `--proxy-config-name`）
6. 接続確認（Ingress経由UIアクセス、Egress許可先疎通）を実施

## 4. Step 1: CDP Workload Environment（`aws`）

## 4.1 tfvarsファイル作成

`docs/aws-private.tfvars.template` を、任意の名前で `aws` 配下にコピーする。

例:

```bash
cp docs/aws-private.tfvars.template aws/fullprivate-prod.tfvars
```

## 4.2 手動修正（必須）

作成した `.tfvars` ファイルを開き、以下2項目を必ず手動で修正する。

- `<ENTER_ENV_PREFIX>`
- `<ENTER_AWS_REGION>`

例:

```hcl
env_prefix = "cdpfp01"
aws_region = "ap-northeast-1"
```

## 4.3 適用

```bash
cd aws
terraform init
terraform plan -var-file=fullprivate-prod.tfvars
terraform apply -var-file=fullprivate-prod.tfvars
```

## 4.4 取得しておく値（後続で利用）

- `aws_vpc_id`（`aws/outputs.tf` 出力）
- CDP VPC CIDR（`aws` の設計値またはAWSコンソールで確認）
- CDP private route table名（既定: `rt-<env_prefix>-private`）

## 5. Step 2: Ingress VPC（`aws-ingress`）

Ingress側のtfvarsを準備し、CDP VPC情報を設定する。

主な設定項目:

- `peer_vpc_id` = Step 1 の `aws_vpc_id`
- `peer_vpc_cidr` = CDP VPC CIDR
- `peer_private_route_table_name` = CDP private route table名
- `ops_vpc_cidr` = `10.99.0.0/24`

実行:

```bash
cd aws-ingress
terraform init
terraform plan -var-file=envs/ntt-poc.tfvars.example
terraform apply -var-file=envs/ntt-poc.tfvars.example
```

## 5.1 Ingress接続（運用時）

1. SSMセッション開始
2. `bastion:22 -> localhost:2222` をポートフォワード
3. ローカルSOCKS起動: `ssh -p 2222 -D 1090 -N ec2-user@localhost`
4. ブラウザ拡張（ZeroOmega等）で `*.cloudera.site` などを `localhost:1090` へ転送

## 5.2 Ingress Peering状態確認（CLI）

`aws-ingress` の `terraform output` で Peering Connection ID を取得し、AWS CLI で `active` を確認する。

```bash
cd aws-ingress
INGRESS_PCX_ID=$(terraform output -raw peering_connection_id)
echo "${INGRESS_PCX_ID}"

AWS_PROFILE=<YOUR_AWS_PROFILE> AWS_REGION=<YOUR_AWS_REGION> \
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "${INGRESS_PCX_ID}" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text
```

期待値: `active`

## 6. Step 3: Egress VPC（`aws-egress`）

## 6.1 tfvars作成

```bash
cp aws-egress/envs/fullprivate.tfvars.example aws-egress/envs/fullprivate.tfvars
```

## 6.2 主要設定

- `egress_vpc_cidr = "10.98.0.0/24"`
- `peer_vpc_id` = Step 1 の `aws_vpc_id`
- `peer_vpc_cidr` = CDP VPC CIDR
- `peer_private_route_table_name` = CDP private route table名

注記:

- CCM v2 は FQDN制御（`*.v2.ccm.ap-1.cdp.cloudera.com`）を採用
- GitHubはドメイン制御（`github.com`, `raw.githubusercontent.com`）のみ
- NVIDIA NGC向けに `api.ngc.nvidia.com`, `files.ngc.nvidia.com`, `xfiles.ngc.nvidia.com`, `prod.otel.kaizen.nvidia.com`, `nvcr.io`, `ngc.nvidia.com` を許可する

## 6.3 適用

```bash
cd aws-egress
terraform init
terraform plan -var-file=envs/fullprivate.tfvars
terraform apply -var-file=envs/fullprivate.tfvars
```

## 6.4 出力値確認

- `egress_proxy_private_ip`
- `egress_proxy_url`
- `egress_peering_connection_id`

## 6.5 Egress Peering状態確認（CLI）

`aws-egress` の `terraform output` で Peering Connection ID を取得し、AWS CLI で `active` を確認する。

```bash
cd aws-egress
EGRESS_PCX_ID=$(terraform output -raw egress_peering_connection_id)
echo "${EGRESS_PCX_ID}"

AWS_PROFILE=<YOUR_AWS_PROFILE> AWS_REGION=<YOUR_AWS_REGION> \
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "${EGRESS_PCX_ID}" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text
```

期待値: `active`

## 7. Step 4: CDP Management Console でProxy登録

`aws-egress` で作成した Squid を、CDP Shared Resource として登録する。

実施箇所:

- Cloudera Management Console
- `Shared Resources > Proxies > Create Proxy Configuration`

入力値の例:

- Protocol: `HTTP`
- Server Host: `<egress_proxy_private_ip>` または Proxy の内部FQDN
- Server Port: `3128`
- No Proxy Hosts: `localhost,127.0.0.1`
- Inbound Proxy CIDR:
  - Server Host に **FQDN** を使う場合は設定必須
  - Server Host に **IP** を使う場合は不要

注意:

- 登録済みProxy設定はCDP上で編集できないため、変更時は再登録する
- Data Services（CDE/CDW/CDF/AI）は、環境レベル設定に加えてサービス有効化時にもProxy設定が必要

## 8. Step 5: 環境関連付け（登録時）

環境作成時に、Step 4で作成したProxy Configurationを関連付ける。

- UI: Environment登録ウィザードでProxyを選択
- CLI: `cdp environments create-aws-environment ... --proxy-config-name <name>`

注記:

- 現行 `aws/` のTerraform雛形は `proxy-config-name` 相当の入力を持たないため、運用上はUI/CLIでの関連付け手順を前提とする

## 9. Step 6: 動作確認

- Ingress
  - SSMでbastion接続できる
  - SOCKS経由でCDP UIへアクセスできる
- Egress
  - 許可ドメイン（CDP API/CCM v2/GitHub等）へ接続できる
  - 非許可ドメインは遮断される

## 9.1 Egress Proxy経由の疎通確認（CLI）

`aws-egress` の Proxy インスタンスへ SSM Run Command を実行し、`curl -x` で Squid 経由の到達性を確認する。

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

期待値:

- `Status` が `Success`
- `StdOut` に各ホストのHTTPステータス（`200`/`301`/`302`/`401`/`403` など）が返る
- `curl` エラー（名前解決失敗、タイムアウト、接続拒否）が出ない

## 10. ロールバック/再実行方針

- 原則は依存の逆順で削除する
  1. `aws-egress`
  2. `aws-ingress`
  3. `aws`
- 再作成時は `peer_vpc_id` や route table名の再確認を必ず行う

## 11. 関連ドキュメント

- ネットワーク設計: `docs/network-design-full-private.md`
- CDP private用テンプレート: `docs/aws-private.tfvars.template`
