# cdp-tf-fullprivate

Cloudera Data Platform（CDP）Public Cloud を **AWS 上でフルプライベート構成** として構築するための Terraform リポジトリです。

CDP Workload Environment にパブリック IP を持たせず、**Ingress VPC（Bastion）** と **Egress VPC（Squid 非透過プロキシ）** を VPC Peering で接続し、Control Plane および許可済み外部宛先への通信を制御します。Cloudera AI Registry / Model Hub / AI Inference まで含めた PoC・検証向けの手順書も同梱しています。

---

## 特徴

| 項目 | 内容 |
| --- | --- |
| ネットワーク | `deployment_template = "private"`、Workload VPC に public subnet / NAT なし |
| 外向き通信 | Egress VPC 上の Squid（FQDN 許可リスト）経由 |
| 運用者アクセス | AWS SSM → Bastion → SOCKS / SSH（パブリック IP なし） |
| CDP 接続 | CCM v2 / Control Plane は Proxy 経由（`private_network_extensions = false` 時必須） |
| AI ワークロード | Private AI Registry、Model Hub、AI Inference、Model Endpoint 向け手順を文書化 |

---

## アーキテクチャ概要

```text
運用者 PC
  └─ SSM Session Manager → Ingress VPC (10.99.0.0/24) Bastion
        └─ VPC Peering → CDP Workload VPC (aws-init / aws)
              └─ VPC Peering → Egress VPC (10.98.0.0/24) Squid Proxy
                    └─ 許可 FQDN のみ外部へ（Control Plane / S3 / GitHub 等）
```

詳細は [docs/network-design-full-private.md](docs/network-design-full-private.md) を参照してください。

---

## リポジトリ構成

| ディレクトリ | 役割 |
| --- | --- |
| [`aws-init/`](aws-init/) | Phase 1: Workload VPC / IAM / S3 / SG / SSH キーペア |
| [`aws-ingress/`](aws-ingress/) | Ingress VPC + Bastion + Workload VPC への Peering |
| [`aws-egress/`](aws-egress/) | Egress VPC + Squid Proxy + Peering + MC Proxy 用 output |
| [`aws/`](aws/) | Phase 3: CDP Environment / Datalake（`aws-init` の remote state 参照） |
| [`docs/`](docs/) | 構築・運用・AI ワークロード手順書、tfvars テンプレート |
| [`scripts/`](scripts/) | Knox プロキシパッチ等の補助スクリプト |

**Terraform 適用順:** `aws-init` → `aws-ingress` / `aws-egress` → MC Proxy 登録 → `aws`

---

## ドキュメント一覧

### 構築・設計

| ドキュメント | 内容 |
| --- | --- |
| [docs/deployment-procedure-full-private.md](docs/deployment-procedure-full-private.md) | **メイン構築手順**（Step 1〜14） |
| [docs/network-design-full-private.md](docs/network-design-full-private.md) | ネットワーク設計・CIDR・Proxy 方針 |
| [docs/operator-access-procedure-full-private.md](docs/operator-access-procedure-full-private.md) | SSM / SOCKS による運用者アクセス |

### tfvars テンプレート（`docs/` 配下）

| ファイル | 対象 |
| --- | --- |
| [docs/aws-init-private.tfvars.template](docs/aws-init-private.tfvars.template) | `aws-init` |
| [docs/aws-ingress-private.tfvars.template](docs/aws-ingress-private.tfvars.template) | `aws-ingress` |
| [docs/aws-egress-private.tfvars.template](docs/aws-egress-private.tfvars.template) | `aws-egress` |
| [docs/aws-private.tfvars.template](docs/aws-private.tfvars.template) | `aws` |

### Cloudera AI

| ドキュメント | 内容 |
| --- | --- |
| [docs/ai-registry-full-private.md](docs/ai-registry-full-private.md) | AI Registry / Model Hub / Knox パッチ（DSE-48642） |
| [docs/model-registry-irsa-full-private.md](docs/model-registry-irsa-full-private.md) | Private Registry 向け手動 IRSA |
| [docs/ai-inference-full-private.md](docs/ai-inference-full-private.md) | Compute Cluster / AI Inference / Model Endpoint |

---

## クイックスタート

1. **前提:** Terraform `>= 1.5.7`、AWS CLI、CDP CLI、Session Manager プラグイン
2. 全ステップで **同一 `env_prefix`**（12 文字以内）を使用
3. CIDR が重複しないこと（Ingress `10.99.0.0/24`、Egress `10.98.0.0/24`、Workload VPC は別 CIDR）

```bash
# Step 1: 基盤
cp docs/aws-init-private.tfvars.template aws-init/envs/fullprivate-init.tfvars
cd aws-init && terraform init && terraform apply -var-file=envs/fullprivate-init.tfvars

# Step 2〜3: Ingress / Egress（tfvars を docs テンプレートからコピーして編集）
# Step 4: MC Shared Resources > Proxies に aws-egress の output を登録
# Step 5: CDP Environment
cp docs/aws-private.tfvars.template aws/fullprivate-prod.tfvars
cd aws && terraform init && terraform apply -var-file=fullprivate-prod.tfvars
```

**重要:** `aws` は **Egress 構築と MC Proxy 登録の後** に実行してください。Proxy の **No Proxy Hosts** は S3 / STS 用に十分な値が必要です（`terraform output -raw mc_proxy_no_proxy_hosts`）。

以降の Cloudera AI 手順は [docs/deployment-procedure-full-private.md](docs/deployment-procedure-full-private.md) の Step 7〜14 に従います。

---

## 構築の流れ（全体）

```text
[1]  aws-init          VPC / IAM / S3 / キーペア
[2]  aws-ingress       Bastion + Peering
[3]  aws-egress        Squid Proxy + Peering
[4]  MC Proxies        Proxy Configuration 登録
[5]  aws               CDP Environment + Datalake
[6]  動作確認          Ingress / Egress 疎通
[7]  Cloudera AI 有効化
[8]  AI Registry 作成
[9]  Knox パッチ（Registry EKS）
[10] Model Registry IRSA（Private Registry 時）
[11] Model Hub インポート
[12] Compute Cluster + AI Inference
[13] Knox パッチ（Inference EKS）
[14] Model Endpoint 作成
```

---

## 補助スクリプト

| スクリプト | 用途 |
| --- | --- |
| [scripts/patch-ai-registry-knox-proxy.sh](scripts/patch-ai-registry-knox-proxy.sh) | Registry / Inference 用 Knox JVM プロキシ設定（DSE-48642） |

---

## 設計上の注意

- **`aws/` 配下の既存 `.tf` は原則変更しない** — ネットワーク拡張は `aws-init` / `aws-ingress` / `aws-egress` で実施
- **Squid 経由 S3 では IAM 認証は代替できない** — No Proxy と VPC Endpoint の組み合わせが重要
- **Private AI Registry** では Model Hub インポート前に [手動 IRSA](docs/model-registry-irsa-full-private.md) が必要な場合がある
- **Registry 用 EKS と Inference 用 EKS は別 `liftie-*` クラスタ** — Knox パッチはそれぞれ個別に実施
- CDP Terraform Provider の Environment Update で既知の不具合がある場合は、CDP CLI による Proxy 更新を検討（手順書参照）

---

## 関連 README

- [aws-init/README.md](aws-init/README.md)
- [aws-egress/README.md](aws-egress/README.md)
- [aws/README.md](aws/README.md)（terraform-docs 生成）

---

## ライセンス / 著作権

各 Terraform モジュールのヘッダに記載のとおり、Cloudera Quick Start ベースの構成を含みます。利用前に各ファイルのライセンス表記を確認してください。
