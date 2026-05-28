# Cloudera on Cloud フルプライベート環境 構築手順（AWS）

## 1. 目的

本手順は、フルプライベート構成を **段階的な Terraform ディレクトリ** で構築するための実行手順を定義する。

| ディレクトリ | 役割 | 実行タイミング |
| --- | --- | --- |
| `aws-init` | VPC / IAM / S3 / SG / SSH キーペア | **最初** |
| `aws-ingress` | Ingress VPC + Bastion + Peering | 基盤作成後 |
| `aws-egress` | Egress VPC + Squid Proxy + Peering | 基盤作成後 |
| （MC） | Proxy Configuration 登録 | Egress 作成後、**CDP 環境作成前** |
| `aws` | CDP Workload Environment + Datalake | Proxy 登録後 |

## 2. 前提条件

- AWS 認証情報（Profile または環境変数）が設定済み
- CDP Terraform Provider 利用に必要な認証情報が設定済み
- Terraform `>= 1.5.7`
- 全ステップで **同じ `env_prefix`** を使用する（例: `cdpfp01`）
- CIDR が重複しないこと
  - Ingress VPC: `10.99.0.0/24`
  - Egress VPC: `10.98.0.0/24`
  - CDP Workload VPC: 上記と重複しない別 CIDR（`aws-init` が作成）

## 3. 構築全体の流れ

**重要:** `aws-init` で `private_network_extensions = false` とする場合、CDP 環境作成時点で **Egress Proxy 経由の CCM v2 接続が必須** です。  
CDP 環境（`aws`）は、Egress 構築と Management Console での Proxy 登録が完了してから実行してください。

```text
[1] aws-init          → VPC / IAM / S3 / キーペア
[2] aws-ingress       → Bastion + Peering (10.99.0.0/24)
[3] aws-egress        → Squid Proxy + Peering (10.98.0.0/24)
[4] MC Proxies        → Shared Resources > Proxies に登録
[5] aws               → CDP Environment（proxy_config_name 指定）
[6] 動作確認          → Ingress UI / Egress 疎通
```

### 使用する tfvars テンプレート

| ステップ | テンプレート | コピー先の例 |
| --- | --- | --- |
| Step 1 | `docs/aws-init-private.tfvars.template` | `aws-init/envs/fullprivate-init.tfvars` |
| Step 2 | `aws-ingress/envs/*.tfvars.example` | `aws-ingress/envs/fullprivate.tfvars` |
| Step 3 | `aws-egress/envs/fullprivate.tfvars.example` | `aws-egress/envs/fullprivate.tfvars` |
| Step 5 | `docs/aws-private.tfvars.template` | `aws/fullprivate-prod.tfvars` |

---

## 4. Step 1: CDP 基盤作成（`aws-init`）

### 4.1 tfvars ファイル作成

```bash
cp docs/aws-init-private.tfvars.template aws-init/envs/fullprivate-init.tfvars
```

### 4.2 手動修正（必須）

以下を環境に合わせて置換する。

- `<ENTER_ENV_PREFIX>`（12 文字以内、小文字・数字・ハイフン）
- `<ENTER_AWS_REGION>`

例:

```hcl
env_prefix = "cdpfp01"
aws_region = "ap-northeast-1"

deployment_template = "private"
private_network_extensions = false
create_vpc_endpoints       = true

ingress_extra_cidrs_and_ports = {
  cidrs = ["10.99.0.0/24"]
  ports = [22, 443]
}
```

### 4.3 適用

```bash
cd aws-init
terraform init
terraform plan -var-file=envs/fullprivate-init.tfvars
terraform apply -var-file=envs/fullprivate-init.tfvars
```

### 4.4 出力値の取得（後続ステップで使用）

```bash
terraform output -raw aws_vpc_id
terraform output -raw aws_vpc_cidr
terraform output -raw peer_private_route_table_name
terraform output -raw aws_key_pair_name
```

| 出力名 | 利用先 |
| --- | --- |
| `aws_vpc_id` | `aws-ingress` / `aws-egress` の `peer_vpc_id` |
| `aws_vpc_cidr` | `aws-ingress` / `aws-egress` の `peer_vpc_cidr` |
| `peer_private_route_table_name` | `peer_private_route_table_name` |
| `aws_key_pair_name` | Bastion / CDP ノード SSH（`aws-init` で生成した `.pem` も参照） |

SSH 秘密鍵は `aws-init` 実行ディレクトリに `<env_prefix>-ssh-key.pem` として保存される。

---

## 5. Step 2: Ingress VPC（`aws-ingress`）

### 5.1 tfvars 準備

```bash
cp aws-ingress/envs/ntt-poc.tfvars.example aws-ingress/envs/fullprivate.tfvars
```

主な設定項目（Step 1 の出力を反映）:

```hcl
env_prefix = "cdpfp01"   # aws-init と同一

peer_vpc_id                   = "<aws-init の aws_vpc_id>"
peer_vpc_cidr                 = "<aws-init の aws_vpc_cidr>"
peer_private_route_table_name = "<aws-init の peer_private_route_table_name>"

ops_vpc_cidr = "10.99.0.0/24"
```

### 5.2 適用

```bash
cd aws-ingress
terraform init
terraform plan -var-file=envs/fullprivate.tfvars
terraform apply -var-file=envs/fullprivate.tfvars
```

### 5.3 Ingress Peering 状態確認（CLI）

```bash
INGRESS_PCX_ID=$(terraform output -raw peering_connection_id)

AWS_PROFILE=<YOUR_AWS_PROFILE> AWS_REGION=<YOUR_AWS_REGION> \
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "${INGRESS_PCX_ID}" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text
```

期待値: `active`

### 5.4 Ingress 接続（運用時）

1. AWS SSM で bastion に接続
2. `bastion:22` → `localhost:2222` をポートフォワード
3. ローカルで SOCKS 起動: `ssh -p 2222 -D 1090 -N ec2-user@localhost`
4. ブラウザ拡張（ZeroOmega 等）で `*.cloudera.site` などを `localhost:1090` へ転送

---

## 6. Step 3: Egress VPC（`aws-egress`）

### 6.1 tfvars 作成

```bash
cp aws-egress/envs/fullprivate.tfvars.example aws-egress/envs/fullprivate.tfvars
```

主な設定（Step 1 の出力を反映）:

```hcl
env_prefix = "cdpfp01"   # aws-init と同一

egress_vpc_cidr = "10.98.0.0/24"

peer_vpc_id                   = "<aws-init の aws_vpc_id>"
peer_vpc_cidr                 = "<aws-init の aws_vpc_cidr>"
peer_private_route_table_name = "<aws-init の peer_private_route_table_name>"
```

### 6.2 適用

```bash
cd aws-egress
terraform init
terraform plan -var-file=envs/fullprivate.tfvars
terraform apply -var-file=envs/fullprivate.tfvars
```

### 6.3 出力値確認

```bash
terraform output mc_proxy_registration
terraform output -raw egress_proxy_private_ip
terraform output -raw egress_peering_connection_id
```

`mc_proxy_registration` は Step 4（MC 登録）と Step 5（`proxy_config_name`）で使用する。

### 6.4 Egress Peering 状態確認（CLI）

```bash
EGRESS_PCX_ID=$(terraform output -raw egress_peering_connection_id)

AWS_PROFILE=<YOUR_AWS_PROFILE> AWS_REGION=<YOUR_AWS_REGION> \
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "${EGRESS_PCX_ID}" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text
```

期待値: `active`

### 6.5 Egress Proxy 経由の疎通確認（CLI・任意）

Proxy インスタンス上から Squid 経由で許可先へ到達できることを確認する。

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

期待値: `Status` が `Success`、各ホストで HTTP ステータスが返る（`curl` エラーなし）

---

## 7. Step 4: CDP Management Console で Proxy 登録

`aws-egress` で作成した Squid を Shared Resource として登録する。

**実施箇所:** Cloudera Management Console → `Shared Resources` → `Proxies` → `Create Proxy Configuration`

登録値は `aws-egress` の出力を使用する。

```bash
cd aws-egress
terraform output mc_proxy_registration
```

| MC の項目 | 設定値の例 |
| --- | --- |
| Name | `cdpfp01-egress-proxy`（`proxy_config_name` として Step 5 で使用） |
| Protocol | `HTTP` |
| Server Host | `mc_proxy_registration.server_host`（固定 Private IP） |
| Server Port | `3128` |
| No Proxy Hosts | `localhost,127.0.0.1` |
| Inbound Proxy CIDR | Server Host が IP の場合は不要。FQDN の場合は CDP VPC CIDR を指定 |

注意:

- 登録済み Proxy は MC 上で編集できない。変更時は削除して再登録する
- Data Services（CDE / CDW / CDF / Cloudera AI）は、環境レベルに加えサービス有効化時にも Proxy 設定が必要

参考: [Using a non-transparent proxy](https://docs.cloudera.com/management-console/cloud/proxy/topics/mc-proxy-server-overview.html)

---

## 8. Step 5: CDP Workload Environment 作成（`aws`）

### 8.1 tfvars 作成

```bash
cp docs/aws-private.tfvars.template aws/fullprivate-prod.tfvars
```

### 8.2 手動修正（必須）

`env_prefix` / `aws_region` は **aws-init と同一** にする。  
`proxy_config_name` は Step 4 で MC に登録した名前と一致させる。

```hcl
env_prefix = "cdpfp01"
aws_region = "ap-northeast-1"

deployment_template = "private"
proxy_config_name   = "cdpfp01-egress-proxy"

# aws-init と同じ値（バリデーション用）
private_network_extensions = false
```

### 8.3 適用

`aws/` はデフォルトで `../aws-init/terraform.tfstate` を参照する。

```bash
cd aws
terraform init
terraform plan -var-file=fullprivate-prod.tfvars
terraform apply -var-file=fullprivate-prod.tfvars
```

state ファイルのパスが異なる場合は tfvars または CLI で上書きする。

```hcl
# aws/fullprivate-prod.tfvars に追記する場合
# init_state_path = "../aws-init/terraform.tfstate"
```

### 8.4 出力確認

```bash
terraform output cdp_environment_name
terraform output cdp_environment_crn
```

---

## 9. Step 6: 動作確認

### Ingress

- SSM で bastion に接続できる
- SOCKS 経由で CDP UI（`*.cloudera.site` 等）にアクセスできる

### Egress / CDP

- CDP Environment が `AVAILABLE` になる
- Cloudera AI 利用時は NGC / GitHub 等の許可先へ Proxy 経由で到達できる

---

## 10. 失敗時の復旧（CREATE_FAILED / jumpgate.proxy-generic-error）

### 症状例

- `FreeIpa creation operation failed`
- `jumpgate.proxy-generic-error`
- `failed to get tunnel status ... redis: nil`

### 主な原因

1. Step 4（MC Proxy 登録）より前に Step 5（`aws`）を実行した
2. `proxy_config_name` が未設定、または MC 登録名と不一致
3. `aws-init` が未適用のまま `aws` を実行した（remote state 参照エラー）
4. Squid 許可リストに CCM v2 / NGC 宛先が不足

### 復旧手順

1. 失敗した CDP Environment を削除（MC または `cd aws && terraform destroy -var-file=fullprivate-prod.tfvars`）
2. Step 3〜4（`aws-egress` + MC Proxy 登録）が完了していることを確認
3. `aws/fullprivate-prod.tfvars` の `proxy_config_name` を確認
4. `cd aws && terraform apply -var-file=fullprivate-prod.tfvars` を再実行

### 旧構成（単一 `aws` フォルダ）から移行する場合

以前 `aws/` だけで VPC 基盤まで作成していた場合は、次のいずれかを実施する。

- **推奨:** テスト環境なら一度 destroy し、`aws-init` から手順どおり再構築
- **上級者向け:** `terraform state mv` で `module.cdp_aws_prereqs` 等を `aws-init` へ移管（手順は環境依存のため個別設計）

---

## 11. ロールバック / 削除順序

依存関係の逆順で削除する。

1. `aws`（CDP Environment）
2. `aws-egress`
3. `aws-ingress`
4. `aws-init`（VPC / IAM / S3 等）

再作成時は Step 1 から順に実施し、`peer_vpc_id` および route table 名を再確認する。

---

## 12. 関連ドキュメント

- ネットワーク設計: `docs/network-design-full-private.md`
- 基盤用 tfvars: `docs/aws-init-private.tfvars.template`
- CDP 環境用 tfvars: `docs/aws-private.tfvars.template`
- `aws-init/README.md` / `aws-egress/README.md`
