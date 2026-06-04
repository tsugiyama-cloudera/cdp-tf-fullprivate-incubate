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
[7] Cloudera AI       → 環境で有効化 + Proxy 再指定
[8] AI Registry       → 作成（Private Cluster ON）
[9] Knox パッチ       → EKS コンソール CloudShell（DSE-48642）
[10] Model Registry IRSA → 手動 IRSA（Private Registry / Model Hub インポート前）
[11] Model Hub       → SOCKS 経由で確認・インポート
[12] Compute Cluster + AI Inference → MC で Container Service / Inference 作成
[13] Knox パッチ（Inference）→ Inference 用 liftie-* EKS CloudShell（DSE-48642）
[14] Model Endpoint  → Registry モデルをデプロイ（SOCKS + cdp-proxy-config 確認）
```

Step 4 の **No Proxy Hosts** は AI Registry / AI Inference の S3 取得失敗を防ぐため **必須** です（`localhost,127.0.0.1` のみ不可）。

Step 7〜11 の詳細は **[Cloudera AI Registry / Model Hub 手順書](ai-registry-full-private.md)** を参照。  
Step 10（手動 IRSA）の詳細は **[Model Registry 手動 IRSA 手順書](model-registry-irsa-full-private.md)** を参照。  
Step 12〜14 の詳細は **[Cloudera AI Inference 手順書](ai-inference-full-private.md)** を参照。

### 使用する tfvars テンプレート

| ステップ | テンプレート | コピー先の例 |
| --- | --- | --- |
| Step 1 | `docs/aws-init-private.tfvars.template` | `aws-init/envs/fullprivate-init.tfvars` |
| Step 2 | `docs/aws-ingress-private.tfvars.template` | `aws-ingress/envs/fullprivate.tfvars` |
| Step 3 | `docs/aws-egress-private.tfvars.template` | `aws-egress/envs/fullprivate.tfvars` |
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
terraform output aws_private_route_table_ids
terraform output -raw aws_key_pair_name
```

| 出力名 | 利用先 |
| --- | --- |
| `aws_vpc_id` | `aws-ingress` / `aws-egress` の `peer_vpc_id` |
| `aws_vpc_cidr` | `aws-ingress` / `aws-egress` の `peer_vpc_cidr` |
| `aws_private_route_table_ids` | `aws-ingress` / `aws-egress` が remote state から自動参照（手動設定不要） |
| `aws_key_pair_name` | Bastion / CDP ノード SSH（`aws-init` で生成した `.pem` も参照） |

SSH 秘密鍵は `aws-init` 実行ディレクトリに `<env_prefix>-ssh-key.pem` として保存される。

---

## 5. Step 2: Ingress VPC（`aws-ingress`）

### 5.1 tfvars 準備

```bash
cp docs/aws-ingress-private.tfvars.template aws-ingress/envs/fullprivate.tfvars
```

主な設定項目（Step 1 の出力を反映）:

```hcl
env_prefix = "cdpfp01"   # aws-init と同一

peer_vpc_id   = "<aws-init の aws_vpc_id>"
peer_vpc_cidr = "<aws-init の aws_vpc_cidr>"

bastion_key_name = "cdpfp01-keypair"   # aws-init の aws_key_pair_name と同一（必須）

# peer_private_route_table_ids は省略可（../aws-init/terraform.tfstate から自動取得）

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

構築後の SSH / ブラウザ（SOCKS）アクセスの詳細は **[運用者アクセス手順書](operator-access-procedure-full-private.md)** を参照。

概要:

1. AWS SSM で bastion に接続
2. `bastion:22` → `localhost:2222` をポートフォワード
3. ローカルで SOCKS 起動: `ssh -p 2222 -D 1090 -N ec2-user@localhost`
4. ブラウザ拡張（ZeroOmega 等）で `*.cloudera.site` などを `localhost:1090` へ転送

---

## 6. Step 3: Egress VPC（`aws-egress`）

### 6.1 tfvars 作成

```bash
cp docs/aws-egress-private.tfvars.template aws-egress/envs/fullprivate.tfvars
```

主な設定（Step 1 の出力を反映）:

```hcl
env_prefix = "cdpfp01"   # aws-init と同一

egress_vpc_cidr = "10.98.0.0/24"

peer_vpc_id   = "<aws-init の aws_vpc_id>"
peer_vpc_cidr = "<aws-init の aws_vpc_cidr>"

# peer_private_route_table_ids は省略可（../aws-init/terraform.tfstate から自動取得）
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

### 6.3.1 `allowed_fqdns` 変更時の注意

Squid の許可リストは Proxy EC2 の `user_data` で初回起動時に書き込まれる。`allowed_fqdns` を変更したら **必ず `aws-egress` を再 apply** する（Proxy EC2 が再作成される）。apply 後に Proxy 上で反映を確認する:

```bash
grep us-west /etc/squid/allowed_domains.txt
sudo systemctl status squid
```

`terraform plan` で `aws_instance.proxy` が **update in-place** のみ（`replace` なし）の場合、Squid 設定はディスク上更新されない。次を実行する:

```bash
terraform apply -replace=aws_instance.proxy -var-file=envs/<your-egress>.tfvars
```

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

**重要:** `No Proxy Hosts` は **Step 5（CDP 環境作成）より前** に、漏れなく設定する。  
`localhost,127.0.0.1` のみだと、後続の **Model Hub インポート** や **AI Inference の Model Endpoint 作成** で Datalake S3 が Squid 経由になり `403` / `Unable to locate credentials` 系の失敗が起きやすい（VPC Endpoint 直アクセスが正）。

### 7.1 出力値の取得

```bash
cd aws-egress
terraform output mc_proxy_registration
terraform output -raw mc_proxy_no_proxy_hosts
terraform output -raw egress_proxy_private_ip
```

MC 登録時は **`terraform output -raw mc_proxy_no_proxy_hosts` の文字列をそのまま** `No Proxy Hosts` に貼り付ける（手入力ミス防止）。

### 7.2 MC 登録項目

| MC の項目 | 設定値 |
| --- | --- |
| Name | `mc_proxy_registration.proxy_config_name`（例: `<env_prefix>-egress-proxy`。Step 5 の `proxy_config_name` と一致） |
| Protocol | `HTTP` |
| Server Host | `mc_proxy_registration.server_host`（固定 Private IP） |
| Server Port | `3128` |
| **No Proxy Hosts** | **`terraform output -raw mc_proxy_no_proxy_hosts` の値をそのまま使用** |
| Inbound Proxy CIDR | Server Host が IP の場合は不要。FQDN の場合は CDP VPC CIDR（`peer_vpc_cidr`）を指定 |

### 7.3 No Proxy Hosts に含まれる項目（`aws-egress` デフォルト）

`aws-egress/main.tf` が `peer_vpc_cidr` / `egress_vpc_cidr` / リージョンから次を生成する。

| カテゴリ | 例（抜粋） | 目的 |
| --- | --- | --- |
| ローカル | `localhost`, `127.0.0.1`, `169.254.169.254` | メタデータ・ループバック |
| クラスタ内部 | `.svc`, `.cluster.local`, `.internal` | Kubernetes 内部通信 |
| CDP UI | `.cloudera.site` | 私有 LB / 環境 FQDN |
| **AWS / S3（必須）** | `.amazonaws.com`, `.s3.amazonaws.com`, `s3.amazonaws.com`, `.s3.<region>.amazonaws.com` | **Datalake バケット・STS・ECR を Squid 迂回** |
| AWS API（リージョン） | `ec2.<region>.amazonaws.com`, `api.ecr.<region>.amazonaws.com`, `sts.<region>.amazonaws.com` 等 | VPC Endpoint 利用 |
| VPC CIDR | `<peer_vpc_cidr>`, `<egress_vpc_cidr>` | 環境内・Egress VPC 直通信 |

Datalake バケットが `bucket.s3.amazonaws.com` 形式で boto3 から参照されるため、**`.amazonaws.com` と `.s3.amazonaws.com` は必須**（`.s3.ap-northeast-1.amazonaws.com` だけでは不足する）。

追加ホストが必要な場合は `aws-egress` の tfvars で `mc_proxy_no_proxy_hosts_extra` に指定する。

```hcl
# aws-egress/envs/fullprivate.tfvars の例
mc_proxy_no_proxy_hosts_extra = ["<datalake-bucket>.s3.amazonaws.com"]
```

### 7.4 CDP CLI で登録する場合（UI の代替）

```bash
cd aws-egress
PROXY_NAME=$(terraform output -json mc_proxy_registration | jq -r '.proxy_config_name')
PROXY_HOST=$(terraform output -raw egress_proxy_private_ip)
NO_PROXY=$(terraform output -raw mc_proxy_no_proxy_hosts)

cdp environments create-proxy-config \
  --proxy-config-name "${PROXY_NAME}" \
  --protocol http \
  --host "${PROXY_HOST}" \
  --port 3128 \
  --no-proxy-hosts "${NO_PROXY}"
```

### 7.5 注意事項

- 登録済み Proxy は MC 上で **編集不可**。変更時は削除→再作成（既存 Environment の `proxy_config_name` は再構築時に合わせる）
- Data Services（CDE / CDW / CDF / Cloudera AI / **AI Inference**）は、環境レベルに加えサービス有効化時にも Proxy 設定が必要
- MC Proxy 設定はクラスタ内 `cdp-proxy-config` ConfigMap の **上流**。Step 4 を正しく行えば Inference 作成後の `serving-default` でも S3 用 No Proxy が配られる **想定**だが、Endpoint 作成前に [AI Inference 手順書](ai-inference-full-private.md) §6 の確認を推奨

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
- Cloudera AI 利用時は NGC / GitHub / PyPI 等の許可先へ Proxy 経由で到達できる

---

## 10. Step 7〜14: Cloudera AI（Registry / Inference）（要約）

Terraform の範囲外（MC / EKS 上のリソース）です。土曜リセットで環境を作り直すたびに **Step 7〜14** が必要です。

| Step | 実施箇所 | 内容 |
| --- | --- | --- |
| 7 | MC | Cloudera AI 有効化（Step 4 と同一 Proxy） |
| 8 | MC | AI Registry 作成（Private Cluster ON、Public LB OFF） |
| 9 | **EKS CloudShell（Registry 用 liftie-*）** | Knox `KNOX_GATEWAY_DBG_OPTS` + `model-registry-v2` 再起動（DSE-48642） |
| 10 | **IAM + EKS CloudShell** | Model Registry 手動 IRSA（Model Hub インポート前） |
| 11 | ローカル + SOCKS | Model Hub インポート |
| 12 | MC | Compute Cluster（Container Service）+ **AI Inference** 作成（Private LB 推奨） |
| 13 | **EKS CloudShell（Inference 用 liftie-*）** | **Knox JVM プロキシ**（Create Endpoint の 401 回避。Registry とは **別クラスタ**） |
| 14 | ローカル + SOCKS | Model Endpoint 作成・Storage Logs 確認 |

Step 10: **[Model Registry 手動 IRSA 手順書](model-registry-irsa-full-private.md)**  
Step 7〜11 詳細: **[ai-registry-full-private.md](ai-registry-full-private.md)**  
Step 12〜14 詳細: **[ai-inference-full-private.md](ai-inference-full-private.md)**

Knox 用 JVM 文字列（Registry / Inference **共通**）:

```bash
cd aws-egress
terraform output -raw knox_jvm_proxy_opts
```

Registry 向け CloudShell コマンド表示:

```bash
chmod +x scripts/patch-ai-registry-knox-proxy.sh
./scripts/patch-ai-registry-knox-proxy.sh
```

Inference 向けは [ai-inference-full-private.md](ai-inference-full-private.md) §5 を参照（対象 EKS クラスタが **Inference 用 liftie-*** であること）。

**注意:** プライベート EKS API は **ローカル `kubectl` からは通常届きません**。EKS コンソール **接続 → CloudShell** を使用する。UI（`*.cloudera.site`）は SOCKS 経由。

---

## 11. 失敗時の復旧（CREATE_FAILED / jumpgate.proxy-generic-error）

### 症状例

- `FreeIpa creation operation failed`
- `jumpgate.proxy-generic-error`
- `failed to get tunnel status ... redis: nil`

### 主な原因

1. Step 4（MC Proxy 登録）より前に Step 5（`aws`）を実行した
2. `proxy_config_name` が未設定、または MC 登録名と不一致
3. `aws-init` が未適用のまま `aws` を実行した（remote state 参照エラー）
4. Squid 許可リストに CCM v2 / NGC 宛先が不足（特に Jumpgate `relayServer` の `*.v2.us-west-1.ccm.cdp.cloudera.com`。`ap-1` のみ許可していると Squid で `TCP_DENIED/403`）

### Squid で Jumpgate が拒否されている場合

FreeIPA の `/etc/jumpgate/config.toml` の `relayServer` を確認し、同ホストへ Proxy 経由で CONNECT できることを試す。

```bash
RELAY_HOST=$(sudo grep relayServer /etc/jumpgate/config.toml | sed 's|.*https://||;s|/.*||')
curl -v -x "http://<PROXY_IP>:3128" --connect-timeout 10 "https://${RELAY_HOST}/" 2>&1 | grep -E 'CONNECT|403|200'
```

Proxy 上で `TCP_DENIED/403` が出る場合は `allowed_fqdns` に `*.v2.us-west-1.ccm.cdp.cloudera.com` を追加して `aws-egress` を再 apply する。

### Compute Cluster（EKS ワーカー）が CREATE_FAILED の場合

症状例:

- `Compute cluster ... failed`
- `Received 0 SUCCESS signal(s) out of 2`
- ワーカーログ: `cfn-signal` → `cloudformation.ap-northeast-1.amazonaws.com` → `403 Forbidden`

Squid で拒否されやすい FQDN:

- `cloudformation.ap-northeast-1.amazonaws.com`
- `api.us-west-1.cdp.cloudera.com`
- `dbusapi.us-west-1.sigma.altus.cloudera.com`
- `receive.api.monitoring.us-west-1.cdp.cloudera.com`

確認:

```bash
curl -v -x "http://<PROXY_IP>:3128" --connect-timeout 10 \
  https://cloudformation.ap-northeast-1.amazonaws.com/ 2>&1 | grep -E 'CONNECT|403|200'
```

`allowed_fqdns` 更新後は `terraform apply -replace=aws_instance.proxy` で Proxy を再作成し、Compute Cluster を再初期化する。

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

## 12. ロールバック / 削除順序

依存関係の逆順で削除する。

1. `aws`（CDP Environment）
2. `aws-egress`
3. `aws-ingress`
4. `aws-init`（VPC / IAM / S3 等）

再作成時は Step 1 から順に実施し、`peer_vpc_id` および route table 名を再確認する。

---

## 13. 関連ドキュメント

- ネットワーク設計: `docs/network-design-full-private.md`
- 運用者アクセス（SOCKS）: `docs/operator-access-procedure-full-private.md`
- Cloudera AI Registry / Model Hub: `docs/ai-registry-full-private.md`
- Cloudera AI Inference / Model Endpoint: `docs/ai-inference-full-private.md`
- 基盤用 tfvars: `docs/aws-init-private.tfvars.template`
- Ingress 用 tfvars: `docs/aws-ingress-private.tfvars.template`
- Egress 用 tfvars: `docs/aws-egress-private.tfvars.template`
- CDP 環境用 tfvars: `docs/aws-private.tfvars.template`
- `aws-init/README.md` / `aws-egress/README.md`
