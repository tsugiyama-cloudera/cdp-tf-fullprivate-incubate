# Model Registry 手動 IRSA 手順（フルプライベート / Private AI Registry）

本書は、フルプライベート環境で **Private AI Registry**（`endpointPublicAccess: false`）を利用する際、Model Hub インポート時に発生する **`Unable to locate credentials`** を回避するための **手動 IRSA（IAM Roles for Service Accounts）** 手順です。

関連ドキュメント:

- [構築手順書](deployment-procedure-full-private.md)（Terraform 構築〜 Step 7〜10）
- [Cloudera AI Registry / Model Hub 手順書](ai-registry-full-private.md)（Knox パッチ・SOCKS・Model Hub）
- [運用者アクセス手順書](operator-access-procedure-full-private.md)

---

## 1. いつ必要か

| 症状 | ログ / CLI の例 |
| --- | --- |
| Model Hub インポート **Failed** | `Unable to locate credentials` |
| Pod 内 `aws sts get-caller-identity` 失敗 | 同上 |
| SA `sa-cdsw-unprivileged` | **`eks.amazonaws.com/role-arn` 注釈なし** |

**背景:** Private AI Registry 作成時、CDP が Datalake バケット（例: `s3://<env_prefix>-buk-*/data/modelregistry/`）へ書き込む IRSA を Pod に付与しない場合があります。Squid 経由 S3 では **IAM 認証は代替できません**（ネットワーク経路の問題ではない）。

**実施タイミング:**

- [ai-registry-full-private.md](ai-registry-full-private.md) の **Knox パッチ（DSE-48642）後**
- **Model Hub インポート前**
- **土曜リセットで Registry / Liftie クラスタを作り直したたび**（EKS の OIDC ID が変わる）

**実施箇所:**

- **IAM 操作** … ローカル PC または AWS CloudShell（`iam:*` 権限）
- **kubectl 操作** … **AI Registry の EKS コンソール → 接続 → CloudShell**（プライベート EKS API）

---

## 2. 事前に控える値

環境ごとに次をメモします（`<>` を実値に置換）。

| 変数 | 取得方法 | 例 |
| --- | --- | --- |
| `ENV_PREFIX` | `aws` / `aws-init` の tfvars | `ts0531p` |
| `ACCOUNT_ID` | `aws sts get-caller-identity --query Account` | `981304421142` |
| `AWS_REGION` | 環境リージョン | `ap-northeast-1` |
| `CLUSTER_NAME` | `cdp ml list-model-registries` 後、EKS コンソールの Liftie 名 | `liftie-ldnlh2zf` |
| `DATALAKE_BUCKET` | `cdp environments describe-environment` の `logStorage.awsDetails.storageLocationBase` から | `ts0531p-buk-d01c9d5b` |
| `CDP_VPC_CIDR` | 同上 `network.networkCidr` | `10.10.0.0/16` |
| `EGRESS_VPC_CIDR` | 設計固定 | `10.98.0.0/24` |
| `PROXY_IP` | `aws-egress` の `terraform output -raw egress_proxy_private_ip` | `10.98.0.20` |

```bash
# Registry / 環境名の確認（ローカル PC）
cdp ml list-model-registries | jq '.modelRegistries[] | select(.environmentName|test("<ENV>-cdp-env")) | {environmentName, domain, status}'

cdp environments describe-environment --environment-name <ENV_PREFIX>-cdp-env \
  | jq '{networkCidr: .environment.network.networkCidr, logStorage: .environment.logStorage.awsDetails.storageLocationBase}'
```

---

## 3. 手順概要

```text
[A] IAM: S3 ポリシー付きロール作成（初回のみ、または trust policy 更新）
[B] IAM: EKS クラスタ用 OIDC プロバイダ登録（クラスタごと）
[C] IAM: ロール trust policy を現在の OIDC ID に更新（クラスタ再作成のたび）
[D] EKS CloudShell: SA 注釈 + model-registry-v2 env + 再起動
[E] 成功判定 → Model Hub インポート
```

**ロール名の推奨:** `<ENV_PREFIX>-model-registry-irsa`（例: `ts0531p-model-registry-irsa`）

---

## 4. [A] IAM ロールと S3 ポリシー（初回）

ローカル PC 等、IAM API が使えるシェルで実行します。

### 4.1 S3 ポリシー（インラインポリシー）

`DATALAKE_BUCKET` を置換して `s3-policy.json` を作成します。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListModelRegistryPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<DATALAKE_BUCKET>",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["data/modelregistry/*", "data/*"]
        }
      }
    },
    {
      "Sid": "ReadWriteModelRegistryObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::<DATALAKE_BUCKET>/data/modelregistry/*"
    }
  ]
}
```

### 4.2 信頼ポリシー（後で [C] でも更新）

`trust-policy.json` は **Step [B] で取得する OIDC ID** を埋めてから使います（4.3 はスキップし [B]→[C] 後に `create-role` でも可）。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.<AWS_REGION>.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<AWS_REGION>.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com",
          "oidc.eks.<AWS_REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:mlx:sa-cdsw-unprivileged"
        }
      }
    }
  ]
}
```

### 4.3 ロール作成（初回のみ）

```bash
export ENV_PREFIX="<ENV_PREFIX>"
export ROLE_NAME="${ENV_PREFIX}-model-registry-irsa"

aws iam create-role --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "${ENV_PREFIX}-model-registry-s3" \
  --policy-document file://s3-policy.json
```

**再構築時:** ロール `ts0531p-model-registry-irsa` が既にあれば **create は不要**。[C] で trust policy のみ更新します。

---

## 5. [B] EKS OIDC プロバイダ登録（クラスタごと）

**EKS CloudShell**（Registry の `liftie-*` クラスタに接続したシェル）で実行します。

```bash
export CLUSTER_NAME="<CLUSTER_NAME>"   # 例: liftie-ldnlh2zf
export AWS_REGION="<AWS_REGION>"

export ISSUER_URL=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text)
echo "ISSUER_URL=${ISSUER_URL}"

export OIDC_ID="${ISSUER_URL#*id/}"
echo "OIDC_ID=${OIDC_ID}"
```

登録済みか確認:

```bash
aws iam list-open-id-connect-providers --output text | grep -i "${OIDC_ID}" || echo "NOT FOUND"
```

未登録なら作成:

```bash
aws iam create-open-id-connect-provider \
  --url "${ISSUER_URL}" \
  --client-id-list sts.amazonaws.com
```

`EntityAlreadyExists` の場合は登録済みです。[C] へ進みます。

`eksctl` がある場合:

```bash
eksctl utils associate-iam-oidc-provider --cluster "${CLUSTER_NAME}" --approve
```

---

## 6. [C] trust policy を現在クラスタの OIDC ID に更新

**Registry / Liftie を作り直すたび必須**です（OIDC ID が `8D1E06781...` → `ACC02DB56...` のように変わる）。

ローカル PC 等で `trust-policy.json` の `<OIDC_ID>` / `<ACCOUNT_ID>` / `<AWS_REGION>` を [B] の値で埋め、更新:

```bash
export ROLE_NAME="<ENV_PREFIX>-model-registry-irsa"

aws iam update-assume-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-document file://trust-policy.json
```

---

## 7. [D] Kubernetes: SA 注釈と Deployment 環境変数

**EKS CloudShell** で実行します。

```bash
export ACCOUNT_ID="<ACCOUNT_ID>"
export ENV_PREFIX="<ENV_PREFIX>"
export ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ENV_PREFIX}-model-registry-irsa"

# ServiceAccount に IRSA ロールを紐づけ
kubectl annotate serviceaccount sa-cdsw-unprivileged -n mlx \
  eks.amazonaws.com/role-arn="${ROLE_ARN}" --overwrite
```

`model-registry-v2` は MC Proxy 設定により `HTTP_PROXY` が入ります。**S3 / STS は VPC Endpoint 直アクセス（No Proxy）**、AWS CLI は **読み取り専用 rootfs** のため `HOME=/tmp` が必要です。

```bash
export NO_PROXY_VAL='localhost,127.0.0.1,.amazonaws.com,.s3.ap-northeast-1.amazonaws.com,s3.ap-northeast-1.amazonaws.com,sts.amazonaws.com,<EGRESS_VPC_CIDR>,<CDP_VPC_CIDR>'

kubectl set env deployment/model-registry-v2 -n mlx \
  NO_PROXY="${NO_PROXY_VAL}" \
  no_proxy="${NO_PROXY_VAL}" \
  AWS_REGION=<AWS_REGION> \
  AWS_DEFAULT_REGION=<AWS_REGION> \
  HOME=/tmp \
  AWS_CONFIG_FILE=/tmp/.aws/config \
  AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials

kubectl rollout restart deployment/model-registry-v2 -n mlx
kubectl rollout status deployment/model-registry-v2 -n mlx
```

`<EGRESS_VPC_CIDR>` / `<CDP_VPC_CIDR>` の例: `10.98.0.0/24`, `10.10.0.0/16`

---

## 8. [E] 成功判定

CloudShell:

```bash
kubectl exec -n mlx deploy/model-registry-v2 -c model-registry-v2 -- sh -c '
  mkdir -p /tmp/.aws
  export HOME=/tmp
  export AWS_CONFIG_FILE=/tmp/.aws/config
  export AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials
  echo AWS_ROLE_ARN=$AWS_ROLE_ARN
  echo NO_PROXY=$NO_PROXY
  aws sts get-caller-identity
  aws s3 ls s3://<DATALAKE_BUCKET>/data/modelregistry/ 2>&1 | head -5
'
```

| 結果 | 判定 |
| --- | --- |
| `get-caller-identity` で `assumed-role/<ENV_PREFIX>-model-registry-irsa/...` | **IRSA OK** |
| `s3 ls` でエラーなし（空でも可） | **S3 OK** |
| `InvalidIdentityToken` / `No OpenIDConnect provider found` | [B][C] を再実施（OIDC ID 不一致） |
| `Failed to connect to proxy URL` | `NO_PROXY` 不足 → 第 7 節を再適用 |
| `[Errno 30] Read-only file system: .../.aws` | `HOME=/tmp` 等が Deployment に無い → 第 7 節を再適用 |

成功後、[ai-registry-full-private.md](ai-registry-full-private.md) に従い **Model Hub からインポート**します。

---

## 9. 土曜リセット後チェックリスト（IRSA 部分）

```text
□ cdp ml list-model-registries で対象 Registry が installation:finished
□ 新 Liftie クラスタ名（liftie-*）を控える
□ [B] 新クラスタの OIDC プロバイダ登録
□ [C] trust policy の OIDC ID を更新（ロールは再利用可）
□ [D] SA 注釈 + NO_PROXY + HOME=/tmp + 再起動
□ [E] get-caller-identity 成功
□ Model Hub インポート成功
```

---

## 10. トラブルシュート

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `Unable to locate credentials` | IRSA 未設定 | 本書 [D] |
| `InvalidIdentityToken` / OIDC provider not found | IAM に OIDC 未登録、または trust policy の ID が旧クラスタのまま | [B][C] |
| `Failed to connect to proxy URL`（`aws` 実行時） | S3/STS が Squid 経由 | `NO_PROXY` に `.amazonaws.com`, `sts.amazonaws.com` 等 |
| `[Errno 30] Read-only file system` | Pod の `$HOME/.aws` が read-only | `HOME=/tmp` と `AWS_*_FILE` を Deployment に設定 |
| Import 時 NGC **403** | Squid ACL | [aws-egress/README.md](../aws-egress/README.md)、構築手順書 §6.3 |
| Knox / Model Hub **401** | DSE-48642 | [ai-registry-full-private.md](ai-registry-full-private.md) §5 |

---

## 11. 注意事項

- **CDP 非公式ワークアラウンド**です。恒久対応は Cloudera サポート／製品修正を推奨します。
- Registry **Helm アップグレード**で SA 注釈や env が消える場合があります。再適用してください。
- **Squid 経由 S3** は IAM を代替せず、設計上も VPC Endpoint + No Proxy が正です。
- MC Proxy の `noProxyHosts` を広げる恒久化は、既存環境では Proxy 差し替え不可のため、次回環境再構築時に CLI で新 Proxy 名を作成する運用を検討してください（[deployment-procedure-full-private.md](deployment-procedure-full-private.md) §7）。

---

## 改訂履歴

| 日付 | 内容 |
| --- | --- |
| 2026-06-03 | 初版（Private AI Registry Model Hub インポート向け手動 IRSA） |
