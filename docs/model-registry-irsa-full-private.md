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

## 2. 環境変数の設定と確認（最初に実行）

以降のコマンドは **ここで export した変数をそのまま参照**します。`<>` による手動置換は不要です。

### 2.1 ローカル PC — 基本変数

リポジトリルート（または作業ディレクトリ）で、**環境に合わせて次の 4 行だけ編集**してから実行します。

```bash
export AWS_PROFILE="<YOUR_CDP_AWS_PROFILE>"   # 例: cloudera-cdp-20250901
export AWS_REGION="<YOUR_AWS_REGION>"         # 例: ap-northeast-1
export ENV_PREFIX="<YOUR_ENV_PREFIX>"         # 例: dsol202606（aws-init tfvars と同一）
export REPO_ROOT="<YOUR_REPO_ROOT>"         # 例: ~/Documents/git/cdp-tf-fullprivate

export ENV_NAME="${ENV_PREFIX}-cdp-env"
export ROLE_NAME="${ENV_PREFIX}-model-registry-irsa"
export EGRESS_VPC_CIDR="${EGRESS_VPC_CIDR:-10.98.0.0/24}"   # aws-egress tfvars の egress_vpc_cidr
export WORK_DIR="${WORK_DIR:-${HOME}/model-registry-irsa}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
```

### 2.2 ローカル PC — `ACCOUNT_ID` / `DATALAKE_BUCKET` / `CDP_VPC_CIDR` の確認

#### ACCOUNT_ID（信頼ポリシー・ROLE_ARN に使用）

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT_ID=${ACCOUNT_ID}"
aws sts get-caller-identity --output table
```

#### DATALAKE_BUCKET（S3 ポリシーに使用）

CDP は `s3://` または `s3a://` 形式で返すことがあります。バケット名のみを抽出します。

```bash
export STORAGE_BASE=$(cdp environments describe-environment --environment-name "${ENV_NAME}" \
  | jq -r '.environment.logStorage.awsDetails.storageLocationBase')

export DATALAKE_BUCKET=$(echo "${STORAGE_BASE}" | sed 's|^s3a\?://||;s|/$||' | cut -d/ -f1)

echo "STORAGE_BASE=${STORAGE_BASE}"
echo "DATALAKE_BUCKET=${DATALAKE_BUCKET}"
```

任意の存在確認（CDP 用 AWS プロファイル）:

```bash
aws s3 ls "s3://${DATALAKE_BUCKET}/" --region "${AWS_REGION}"
aws s3 ls "s3://${DATALAKE_BUCKET}/data/modelregistry/" --region "${AWS_REGION}" || true
```

`ListBucket` が成功すれば S3 ポリシーの Resource として問題ありません（`data/modelregistry/` が空でも可）。

#### CDP_VPC_CIDR / PROXY_IP

```bash
export CDP_VPC_CIDR=$(cdp environments describe-environment --environment-name "${ENV_NAME}" \
  | jq -r '.environment.network.networkCidr')
echo "CDP_VPC_CIDR=${CDP_VPC_CIDR}"

# aws-egress を apply 済みのマシンで（別ターミナル可）
export PROXY_IP=$(cd "${WORK_DIR}/../aws-egress" 2>/dev/null && terraform output -raw egress_proxy_private_ip)
echo "PROXY_IP=${PROXY_IP}"
```

#### Registry 確認 / Liftie クラスタ名（EKS CloudShell 接続先）

`list-model-registries` のフィールドは **`serviceName` / `domain`** です（`name` / `domainName` ではありません）。

```bash
cdp ml list-model-registries \
  | jq --arg env "${ENV_NAME}" '.modelRegistries[] | select(.environmentName == $env) | {
      serviceName,
      crn,
      domain,
      environmentName,
      status
    }'

export MR_CRN=$(cdp ml list-model-registries \
  | jq -r --arg env "${ENV_NAME}" '.modelRegistries[] | select(.environmentName == $env) | .crn')
echo "MR_CRN=${MR_CRN}"

cdp ml get-model-registry-kubeconfig --model-registry-crn "${MR_CRN}" \
  > "${WORK_DIR}/model-registry.kubeconfig"

export CLUSTER_NAME=$(kubectl config view --kubeconfig="${WORK_DIR}/model-registry.kubeconfig" \
  --minify -o jsonpath='{.clusters[0].name}')
echo "CLUSTER_NAME=${CLUSTER_NAME}"
```

`kubectl` が無い場合:

```bash
export CLUSTER_NAME=$(grep -E '^  name: liftie-' "${WORK_DIR}/model-registry.kubeconfig" | head -1 | awk '{print $2}')
echo "CLUSTER_NAME=${CLUSTER_NAME}"
```

#### ローカル PC — 設定値の一覧確認

```bash
echo "=== IRSA variables (local) ==="
printf 'ENV_PREFIX=%s\nENV_NAME=%s\nAWS_REGION=%s\nACCOUNT_ID=%s\nDATALAKE_BUCKET=%s\nCDP_VPC_CIDR=%s\nEGRESS_VPC_CIDR=%s\nROLE_NAME=%s\nCLUSTER_NAME=%s\nWORK_DIR=%s\n' \
  "${ENV_PREFIX}" "${ENV_NAME}" "${AWS_REGION}" "${ACCOUNT_ID}" "${DATALAKE_BUCKET}" \
  "${CDP_VPC_CIDR}" "${EGRESS_VPC_CIDR}" "${ROLE_NAME}" "${CLUSTER_NAME}" "${WORK_DIR}"
```

### 2.3 EKS CloudShell — `OIDC_ID` / `ISSUER_URL` の確認

**AI Registry の `liftie-*` クラスタに接続した EKS CloudShell** で実行します（`CLUSTER_NAME` は 2.2 で設定した値）。

```bash
export CLUSTER_NAME="${CLUSTER_NAME}"   # 2.2 と同じ値。CloudShell では再 export すること
export AWS_REGION="${AWS_REGION}"       # 例: ap-northeast-1

export ISSUER_URL=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text)
export OIDC_ID="${ISSUER_URL#*id/}"

echo "ISSUER_URL=${ISSUER_URL}"
echo "OIDC_ID=${OIDC_ID}"
echo "Federated=arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
```

`ACCOUNT_ID` は CloudShell でも次で取得できます（ローカルと同一アカウントであること）:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT_ID=${ACCOUNT_ID}"
```

OIDC プロバイダ登録済みか（ローカル PC または CloudShell）:

```bash
aws iam list-open-id-connect-providers --output text | grep -i "${OIDC_ID}" || echo "NOT FOUND → 第 5 節で create-open-id-connect-provider"
```

**メモ:** `OIDC_ID` は CloudShell で取得後、ローカル PC の第 4.2 節でも同じ値を使います。ローカル PC から `aws eks describe-cluster` が実行できる場合は、第 2.3 節と同じコマンドをローカルで再実行するのが確実です。

CloudShell 用に変数をファイルへ保存する例（ローカル PC、第 2 節完了後）:

```bash
cat > "${WORK_DIR}/irsa-env.sh" <<EOF
export ENV_PREFIX="${ENV_PREFIX}"
export ENV_NAME="${ENV_NAME}"
export AWS_REGION="${AWS_REGION}"
export ACCOUNT_ID="${ACCOUNT_ID}"
export DATALAKE_BUCKET="${DATALAKE_BUCKET}"
export CDP_VPC_CIDR="${CDP_VPC_CIDR}"
export EGRESS_VPC_CIDR="${EGRESS_VPC_CIDR}"
export ROLE_NAME="${ROLE_NAME}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export OIDC_ID="${OIDC_ID:-}"
EOF
chmod 600 "${WORK_DIR}/irsa-env.sh"
echo "Wrote ${WORK_DIR}/irsa-env.sh — CloudShell へコピー後: source irsa-env.sh"
```

---

## 3. 手順概要

```text
[2] 環境変数 export と CLI 確認（ACCOUNT_ID / DATALAKE_BUCKET / OIDC_ID）
[4.1] S3 ポリシー JSON 生成（s3-policy.json）
[5]   EKS OIDC プロバイダ登録
[4.2] 信頼ポリシー JSON 生成（trust-policy.json）— OIDC_ID 取得後
[4.3] IAM ロール作成（初回）または [6] trust policy 更新（Liftie 再作成時）
[7]   EKS CloudShell: SA 注釈 + model-registry-v2 env + 再起動
[8]   成功判定 → Model Hub インポート
```

**ロール名:** `${ENV_PREFIX}-model-registry-irsa`（例: `dsol202606-model-registry-irsa`）

---

## 4. [A] IAM ロールと S3 ポリシー

ローカル PC 等、IAM API が使えるシェルで実行します。**第 2 節の export 済みであること**を確認してください。

### 4.1 S3 ポリシー JSON の生成

`${DATALAKE_BUCKET}` を埋め込んで `s3-policy.json` を生成します。

```bash
cd "${WORK_DIR}"

cat > s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListModelRegistryPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${DATALAKE_BUCKET}",
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
      "Resource": "arn:aws:s3:::${DATALAKE_BUCKET}/data/modelregistry/*"
    }
  ]
}
EOF

echo "=== s3-policy.json (preview) ==="
cat s3-policy.json
grep "${DATALAKE_BUCKET}" s3-policy.json
```

### 4.2 信頼ポリシー JSON の生成

**第 5 節（または 2.3）で `OIDC_ID` を取得した後**に実行します。

```bash
cd "${WORK_DIR}"

cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com",
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:mlx:sa-cdsw-unprivileged"
        }
      }
    }
  ]
}
EOF

echo "=== trust-policy.json (preview) ==="
cat trust-policy.json
grep "${OIDC_ID}" trust-policy.json
```

### 4.3 ロール作成（初回のみ）

```bash
aws iam create-role --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://"${WORK_DIR}/trust-policy.json"

aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "${ENV_PREFIX}-model-registry-s3" \
  --policy-document file://"${WORK_DIR}/s3-policy.json"
```

**再構築時:** ロール `${ENV_PREFIX}-model-registry-irsa` が既にあれば **create は不要**。第 6 節で trust policy のみ更新します。

---

## 5. [B] EKS OIDC プロバイダ登録（クラスタごと）

**EKS CloudShell**（Registry の `liftie-*` クラスタに接続したシェル）で実行します。第 2.3 節で `ISSUER_URL` / `OIDC_ID` を未取得の場合:

```bash
export CLUSTER_NAME="${CLUSTER_NAME}"
export AWS_REGION="${AWS_REGION}"

export ISSUER_URL=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text)
export OIDC_ID="${ISSUER_URL#*id/}"
echo "ISSUER_URL=${ISSUER_URL}"
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

`EntityAlreadyExists` の場合は登録済みです。第 4.2 節へ進みます。

`eksctl` がある場合:

```bash
eksctl utils associate-iam-oidc-provider --cluster "${CLUSTER_NAME}" --approve
```

---

## 6. [C] trust policy を現在クラスタの OIDC ID に更新

**Registry / Liftie を作り直したたび必須**です（OIDC ID が変わる）。

1. 第 2.3 節で新しい `OIDC_ID` を取得
2. 第 4.2 節で `trust-policy.json` を再生成
3. ローカル PC で更新:

```bash
aws iam update-assume-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-document file://"${WORK_DIR}/trust-policy.json"
```

---

## 7. [D] Kubernetes: SA 注釈と Deployment 環境変数

**EKS CloudShell** で実行します。第 2 節の `irsa-env.sh` を CloudShell にコピーして `source` するか、同じ変数を export してください。

```bash
source ~/irsa-env.sh   # または第 2 節で export した変数をそのまま使用

export ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ENV_PREFIX}-model-registry-irsa"

# model-registry-v2 が使用する ServiceAccount（Cloudera AI 新版では sa-cdsw-privileged のことが多い）
export MR_SA=$(kubectl get deploy model-registry-v2 -n mlx \
  -o jsonpath='{.spec.template.spec.serviceAccountName}')
echo "MR_SA=${MR_SA}"

# ServiceAccount に IRSA ロールを紐づけ（trust-policy.json の :sub も ${MR_SA} と一致させること）
kubectl annotate serviceaccount "${MR_SA}" -n mlx \
  eks.amazonaws.com/role-arn="${ROLE_ARN}" --overwrite
```

`model-registry-v2` は MC Proxy 設定により `HTTP_PROXY` が入ります。**S3 / STS は VPC Endpoint 直アクセス（No Proxy）**、Import 時の **model-import Job スケジュールは in-cluster Kubernetes API（例: `https://172.20.0.1:443`）** を使うため、**ClusterIP / Service CIDR も No Proxy に含める**必要があります（`.svc` のみでは IP 宛て API 呼び出しは bypass されません）。AWS CLI は **読み取り専用 rootfs** のため `HOME=/tmp` が必要です。

```bash
export K8S_CLUSTER_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
echo "K8S_CLUSTER_IP=${K8S_CLUSTER_IP}"
# 多くの EKS では 172.20.0.0/16。clusterIP が異なる CIDR の場合は EKS の Service CIDR に合わせて上書き
export K8S_SVC_CIDR="${K8S_SVC_CIDR:-172.20.0.0/16}"

export NO_PROXY_VAL="localhost,127.0.0.1,${K8S_CLUSTER_IP},${K8S_SVC_CIDR},.svc,.svc.cluster.local,.cluster.local,.amazonaws.com,.s3.${AWS_REGION}.amazonaws.com,s3.${AWS_REGION}.amazonaws.com,sts.amazonaws.com,sts.${AWS_REGION}.amazonaws.com,${EGRESS_VPC_CIDR},${CDP_VPC_CIDR}"

echo "NO_PROXY_VAL=${NO_PROXY_VAL}"

kubectl set env deployment/model-registry-v2 -n mlx \
  NO_PROXY="${NO_PROXY_VAL}" \
  no_proxy="${NO_PROXY_VAL}" \
  AWS_REGION="${AWS_REGION}" \
  AWS_DEFAULT_REGION="${AWS_REGION}" \
  HOME=/tmp \
  AWS_CONFIG_FILE=/tmp/.aws/config \
  AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials

kubectl rollout restart deployment/model-registry-v2 -n mlx
kubectl rollout status deployment/model-registry-v2 -n mlx
```

---

## 8. [E] 成功判定

**EKS CloudShell** で実行します（`DATALAKE_BUCKET` を export 済みであること）。

```bash
export DATALAKE_BUCKET="${DATALAKE_BUCKET}"

kubectl exec -n mlx deploy/model-registry-v2 -c model-registry-v2 -- sh -c "
  mkdir -p /tmp/.aws
  export HOME=/tmp
  export AWS_CONFIG_FILE=/tmp/.aws/config
  export AWS_SHARED_CREDENTIALS_FILE=/tmp/.aws/credentials
  echo AWS_ROLE_ARN=\$AWS_ROLE_ARN
  echo NO_PROXY=\$NO_PROXY
  aws sts get-caller-identity
  aws s3 ls s3://${DATALAKE_BUCKET}/data/modelregistry/ 2>&1 | head -5
"
```

| 結果 | 判定 |
| --- | --- |
| `get-caller-identity` で `assumed-role/${ENV_PREFIX}-model-registry-irsa/...` | **IRSA OK** |
| `s3 ls` でエラーなし（空でも可） | **S3 OK** |
| `InvalidIdentityToken` / `No OpenIDConnect provider found` | [B][C] を再実施（OIDC ID 不一致） |
| `Failed to connect to proxy URL` | `NO_PROXY` 不足 → 第 7 節を再適用 |
| `[Errno 30] Read-only file system: .../.aws` | `HOME=/tmp` 等が Deployment に無い → 第 7 節を再適用 |
| Import **500** / `172.20.0.1:443/apis/batch/v1/.../jobs` **Forbidden** | K8s API が Squid 経由 → 第 7 節の `K8S_CLUSTER_IP` / `K8S_SVC_CIDR` を `NO_PROXY` に含める |

**Kubernetes API 到達確認（任意・Import 500 時）:**

```bash
kubectl exec -n mlx deploy/model-registry-v2 -c model-registry-v2 -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -sk -o /dev/null -w "k8s_jobs_api_http_code=%{http_code}\n" \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://172.20.0.1:443/apis/batch/v1/namespaces/mlx/jobs?labelSelector=app%3Dmodel-registry"
'
```

`200` または RBAC 起因の `403`（Forbidden だが Squid 経由でない）なら K8s API 経路は OK。`403` + Squid ログに `172.20.0.1` が出る場合は `NO_PROXY` 不足です。

成功後、[ai-registry-full-private.md](ai-registry-full-private.md) に従い **Model Hub からインポート**します。

---

## 9. 土曜リセット後チェックリスト（IRSA 部分）

```text
□ 第 2 節: cdp ml list-model-registries で対象 Registry が installation:finished
□ 第 2 節: 新 Liftie クラスタ名を CLUSTER_NAME に export
□ 第 2.3 / 5 節: 新クラスタの OIDC プロバイダ登録
□ 第 4.2 / 6 節: trust-policy.json 再生成 + update-assume-role-policy
□ 第 7 節: SA 注釈 + NO_PROXY + HOME=/tmp + 再起動
□ 第 8 節: get-caller-identity 成功
□ Model Hub インポート成功
```

---

## 10. トラブルシュート

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `Unable to locate credentials` | IRSA 未設定 | 本書 第 7 節 |
| `InvalidIdentityToken` / OIDC provider not found | IAM に OIDC 未登録、または trust policy の ID が旧クラスタのまま | 第 2.3 / 5 / 6 節 |
| `Failed to connect to proxy URL`（`aws` 実行時） | S3/STS が Squid 経由 | 第 7 節の `NO_PROXY_VAL` を再適用 |
| `[Errno 30] Read-only file system` | Pod の `$HOME/.aws` が read-only | 第 7 節の `HOME=/tmp` と `AWS_*_FILE` |
| Import **500** / K8s Job API **Forbidden**（`172.20.0.1:443`） | K8s API が Squid 経由 | 第 7 節: `K8S_CLUSTER_IP` / `K8S_SVC_CIDR` を `NO_PROXY` に追加 |
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
| 2026-06-04 | 環境変数ベースのコピペ実行、CLI 確認手順（ACCOUNT_ID / DATALAKE_BUCKET / OIDC_ID）、heredoc によるポリシー JSON 生成 |
| 2026-06-04 | §2.2: `list-model-registries` の正しいフィールド名、`get-model-registry-kubeconfig` から `CLUSTER_NAME` 自動取得 |
| 2026-06-22 | §7: `NO_PROXY` に Kubernetes API（ClusterIP / Service CIDR / `.svc`）追加、`MR_SA` 自動取得 |
