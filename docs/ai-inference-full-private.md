# フルプライベート CDP 環境 Cloudera AI Inference 手順

本書は、本リポジトリで構築したフルプライベート環境において **Compute Cluster（Container Service）** と **Cloudera AI Inference** をデプロイし、**AI Registry** 上のモデルから **Model Endpoint** を作成するまでの手順をまとめたものです。

関連ドキュメント:

- [構築手順書](deployment-procedure-full-private.md)（Step 4 MC Proxy **No Proxy Hosts**、Step 12〜14）
- [Cloudera AI Registry / Model Hub 手順書](ai-registry-full-private.md)
- [Model Registry 手動 IRSA 手順書](model-registry-irsa-full-private.md)
- [運用者アクセス手順書](operator-access-procedure-full-private.md)

---

## 1. 前提

| 項目 | 確認 |
| --- | --- |
| Step 4（MC Proxy 登録）完了 | **`No Proxy Hosts` に S3/AWS CIDR 含む**（[構築手順書 §7](deployment-procedure-full-private.md#7-step-4-cdp-management-console-で-proxy-登録)） |
| CDP Environment `AVAILABLE` | `computeClusterEnabled = true` |
| **AI Registry** にモデル登録済み | [ai-registry-full-private.md](ai-registry-full-private.md) |
| 運用者アクセス | Ingress SSM + SOCKS（`*.cloudera.site`） |

**Registry 用 EKS と Inference 用 EKS は別の `liftie-*` クラスタ** です。Knox パッチは **それぞれのクラスタで個別に** 実施します。

---

## 2. 構築の流れ（概要）

```text
[MC]  Compute Cluster（Container Service）作成
[MC]  AI Inference サービス作成（Private LB 推奨）
[EKS] Inference 用 liftie-* CloudShell: Knox JVM プロキシ（DSE-48642）
[EKS] serving-default の cdp-proxy-config 確認（Step 4 漏れ防止）
[PC]  SOCKS ON → Create Endpoint → Storage Logs 確認
```

| 操作場所 | 用途 |
| --- | --- |
| **Management Console** | Compute Cluster / AI Inference 作成、Endpoint ウィザード |
| **EKS CloudShell（Inference 用 liftie-*）** | Knox パッチ、`cdp-proxy-config` 確認 |
| **ローカル + SOCKS** | Inference UI、`deployEndpoint` API（私有ドメイン） |

---

## 3. Step 1: Compute Cluster（Container Service）

**実施箇所:** Cloudera Management Console

1. 対象 Environment で **Compute Cluster**（Container Service）を作成
2. **Environment 作成時と同じ Proxy Configuration**（Step 4 で登録した Proxy）を使用
3. Private 構成（Public LB OFF 等）は Registry と同様の方針を推奨

作成完了まで時間がかかることがあります。MC 上で **Running / Available** になるまで待ちます。

---

## 4. Step 2: AI Inference サービス作成

**実施箇所:** Cloudera Management Console → **AI Inference Services** → Create

| 項目 | フルプライベートでの推奨 |
| --- | --- |
| Environment | 対象環境 |
| Compute Cluster | Step 1 で作成したクラスタ |
| **Enable Public IP Address for Load Balancer** | **OFF**（Private LB） |
| Proxy | 環境と同一 Proxy（自動継承） |

**メモ:** Inference の **Domain name**（例: `https://<prefix>-caii-2.<env>.cloudera.site`）を控えます。Create Endpoint 時の API はこのホスト向けです。

Proxy 設定を MC で変更した場合は、Inference サービス画面の **Refresh** でデータプレーンへ反映します（[NTP サポート](https://docs.cloudera.com/machine-learning/1.5.5/setup-cloudera-ai-inference/topics/ml-ntp-support-cai.html)）。

---

## 5. Step 3: Knox JVM プロキシ（DSE-48642）— Inference 用 EKS CloudShell

### 5.1 背景

非透過プロキシ環境で **Create Endpoint** を押すと `POST .../deployEndpoint` が **401 Unauthorized** になる場合、Inference クラスタ内 **Knox** が Control Plane へ到達できていません（Registry と同型の DSE-48642）。

| DevTools の症状 | 意味 |
| --- | --- |
| `deployEndpoint` → **401** + Bearer あり | **本 Step（Inference 用 Knox パッチ）が必要** |
| `(failed)` / timeout | SOCKS 未設定（[運用者アクセス手順書](operator-access-procedure-full-private.md)） |
| **200 / 201 / 202** | Knox OK。Endpoint 作成開始 |

### 5.2 Inference 用 EKS クラスタの特定

Registry とは **別クラスタ** です。`cdp ml list-ml-serving-apps` の JSON フィールドは **`appName` / `appCrn` / `cluster.clusterName`** です（`name` / `crn` / `cluster.name` ではありません）。

```bash
export ENV_NAME="${ENV_PREFIX}-cdp-env"   # 例: dsol202606-cdp-env

# Inference サービス一覧（フィールド名に注意）
cdp ml list-ml-serving-apps \
  | jq --arg env "${ENV_NAME}" '.apps[] | select(.environmentName == $env) | {
      appName,
      appCrn,
      status,
      clusterName: .cluster.clusterName,
      liftieID: .cluster.liftieID,
      domainName: .cluster.domainName,
      environmentName
    }'

# 対象 Inference の CRN を export（環境に 1 件の場合）
export APP_CRN=$(cdp ml list-ml-serving-apps \
  | jq -r --arg env "${ENV_NAME}" '.apps[] | select(.environmentName == $env) | .appCrn')
echo "APP_CRN=${APP_CRN}"

# EKS クラスタ名（liftie-*）。list から直接取得
export CLUSTER_NAME=$(cdp ml list-ml-serving-apps \
  | jq -r --arg env "${ENV_NAME}" '.apps[] | select(.environmentName == $env) | .cluster.clusterName // .cluster.liftieID')
echo "CLUSTER_NAME=${CLUSTER_NAME}"
```

kubeconfig からクラスタ名を確認する場合（list と突合）:

```bash
export WORK_DIR="${WORK_DIR:-${HOME}/model-registry-irsa}"
mkdir -p "${WORK_DIR}"

cdp ml get-ml-serving-app-kubeconfig --app-crn "${APP_CRN}" \
  | jq -r '.kubeConfig // .kubeconfig' > "${WORK_DIR}/inference.kubeconfig"

export CLUSTER_NAME_FROM_KUBECONFIG=$(kubectl config view --kubeconfig="${WORK_DIR}/inference.kubeconfig" \
  --minify -o jsonpath='{.clusters[0].name}')
echo "CLUSTER_NAME_FROM_KUBECONFIG=${CLUSTER_NAME_FROM_KUBECONFIG}"
```

`kubectl` が無い場合:

```bash
export CLUSTER_NAME_FROM_KUBECONFIG=$(grep -E '^  name: liftie-' "${WORK_DIR}/inference.kubeconfig" | head -1 | awk '{print $2}')
echo "CLUSTER_NAME_FROM_KUBECONFIG=${CLUSTER_NAME_FROM_KUBECONFIG}"
```

EKS コンソールで接続する **`liftie-*` 名** は、通常 `clusterName` または `liftieID` と一致します。`domainName` は Inference UI の FQDN（例: `https://<prefix>-caii-2.<env>.cloudera.site`）であり、EKS クラスタ名とは別です。

> **補足:** ローカル `kubectl` で Inference クラスタに接続する場合は [付録 A](#付録-a-eks-アクセス権grant-ml-serving-app-access) の `grant-ml-serving-app-access` が必要なことがあります。Knox パッチは **EKS コンソール CloudShell** を推奨します。

### 5.3 CloudShell で Knox を更新

1. AWS EKS コンソール → **Inference 用** `liftie-*` を選択 → **接続** → CloudShell
2. JVM 文字列を取得（ローカルまたは CloudShell）:

```bash
cd aws-egress
terraform output -raw knox_jvm_proxy_opts
```

3. CloudShell で実行:

```bash
kubectl get pods -n knox

export KNOX_OPTS='-Dhttps.proxyHost=10.98.0.20 -Dhttps.proxyPort=3128 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true'
# ↑ terraform output -raw knox_jvm_proxy_opts の値を使用

kubectl set env deployment/knox -n knox \
  KNOX_GATEWAY_DBG_OPTS="${KNOX_OPTS}"

kubectl rollout status deployment/knox -n knox
kubectl get pods -n knox
```

`knox-...` が **Running 1/1** になれば OK です。

---

## 6. Step 4: `cdp-proxy-config` 確認（S3 / No Proxy）

Step 4（MC Proxy）で **No Proxy Hosts** を正しく設定していれば、Inference 作成時に各 namespace へ `cdp-proxy-config` が配られます。Endpoint 作成前に **Pod が動く namespace** を確認します。

```bash
kubectl get cm cdp-proxy-config -n serving-default -o yaml | grep -i no_proxy | grep -E '\.amazonaws\.com|\.s3\.amazonaws\.com'
kubectl get cm cdp-proxy-config -n kserve -o yaml | grep -i no_proxy | grep -E '\.amazonaws\.com|\.s3\.amazonaws\.com'
```

| 結果 | 対処 |
| --- | --- |
| `.amazonaws.com` / `.s3.amazonaws.com` **あり** | Step 5（Endpoint 作成）へ |
| **無い**（`.s3.ap-northeast-1.amazonaws.com` のみ等） | 次 §6.1 を実施 |

> **Registry との違い:** Model Hub Import の **K8s Job スケジュール**は **Registry クラスタ**の `model-registry-v2` が行います（[IRSA 手順書 §7](model-registry-irsa-full-private.md)）。Inference 側の主な No Proxy 問題は **Endpoint Pod の S3 取得（storage-initializer）が Squid 403** になるケースです（下記 §6.1）。
>
> MC Proxy の `terraform output -raw mc_proxy_no_proxy_hosts` には `.svc` / `.cluster.local` が含まれますが、**Kubernetes API の ClusterIP（例: `172.20.0.1`）は IP 指定のため `.svc` では bypass されません**。Inference コントローラが K8s API 経由で **Forbidden** になる場合のみ、§6.1 で Service CIDR を追加してください（通常の Endpoint 作成では §6.1 の S3 向け patch が中心）。

### 6.1 不足時の patch（既存環境の回避）

MC Proxy を後から広げられない場合、**Endpoint Pod が参照する namespace** の ConfigMap を更新します。

```bash
export K8S_CLUSTER_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
echo "K8S_CLUSTER_IP=${K8S_CLUSTER_IP}"
export K8S_SVC_CIDR="${K8S_SVC_CIDR:-172.20.0.0/16}"   # clusterIP と整合する Service CIDR

export NO_PROXY_SUFFIX=".amazonaws.com,.s3.amazonaws.com,s3.amazonaws.com,<DATALAKE_BUCKET>.s3.amazonaws.com,${K8S_CLUSTER_IP},${K8S_SVC_CIDR},.svc,.svc.cluster.local,.cluster.local,10.98.0.0/24"

kubectl edit cm cdp-proxy-config -n serving-default
kubectl edit cm cdp-proxy-config -n kserve
```

`NO_PROXY` と `no_proxy` の末尾に `,${NO_PROXY_SUFFIX}` を追加（`HTTP_PROXY` は変更しない）。**S3 向け**（`.amazonaws.com` 等）が最優先。`K8S_CLUSTER_IP` / `K8S_SVC_CIDR` は K8s API が Squid 経由になる場合の追加対策です。

**恒久対応:** 次回再構築時は [構築手順書 Step 4](deployment-procedure-full-private.md#7-step-4-cdp-management-console-で-proxy-登録) の **`terraform output -raw mc_proxy_no_proxy_hosts`** を MC 登録時に使用する。

---

## 7. Step 5: Model Endpoint 作成（ローカル + SOCKS）

1. [運用者アクセス手順書](operator-access-procedure-full-private.md) の SOCKS を起動
2. MC → Cloudera AI → **Model Endpoints** → Create Endpoint
3. Registry モデル・Inference サービスを選択 → **Create Endpoint**

### 7.1 成功判定

| 確認 | 期待 |
| --- | --- |
| DevTools `deployEndpoint` | **401 以外**（200 系） |
| Storage Logs | `Copying contents of s3://...` 後に **ProxyConnectionError / Squid 403 なし** |
| Pod（CloudShell） | `kubectl get pods -n serving-default` → **Running** |

Squid ログ（Proxy EC2）で Datalake バケット向け `TCP_DENIED/403` が出る場合は §6 / 構築手順書 Step 4 の No Proxy を再確認。

---

## 8. 土曜リセット後チェックリスト

```text
□ 構築手順書 Step 4: MC Proxy No Proxy（terraform output -raw mc_proxy_no_proxy_hosts）
□ aws 環境 AVAILABLE、Compute Cluster 作成
□ AI Inference 作成（Private LB）
□ Inference 用 liftie-* CloudShell: Knox KNOX_GATEWAY_DBG_OPTS
□ serving-default cdp-proxy-config に .amazonaws.com / .s3.amazonaws.com
□ SOCKS: Create Endpoint 成功、Endpoint Running
```

---

## 9. トラブルシュート

| 症状 | 確認 |
| --- | --- |
| Create Endpoint → **Communication Error** / **401** | §5 Knox パッチ（**Inference 用** liftie-*） |
| Storage Logs → **Squid 403** / `Tunnel connection failed: 403` | §6 No Proxy（`serving-default` の `cdp-proxy-config`） |
| `172.20.0.1:443` / K8s API **Forbidden**（コントローラログ） | §6.1: `cdp-proxy-config` に `K8S_CLUSTER_IP` / Service CIDR を追加 |
| Storage Logs → `Found credentials from IAM Role` の後 **AccessDenied** | ワーカーロールの S3 読み取りポリシー |
| Inference UI が開かない | SOCKS / 私有 LB |

---

## 付録 A: EKS アクセス権（grant-ml-serving-app-access）

Inference クラスタの CloudShell / ローカル `kubectl` には、CDP 側の付与が必要な場合があります。

### IAM ロール ARN の取得

```bash
aws sts get-caller-identity
# Arn が arn:aws:sts::...:assumed-role/ROLE_NAME/session の場合:
export ROLE_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ROLE_NAME"
```

### 付与（未実施または kubeconfig 取得失敗時）

```bash
cdp ml grant-ml-serving-app-access \
  --resource-crn "${APP_CRN}" \
  --identifier "${ROLE_ARN}"
```

kubeconfig 取得:

```bash
cdp ml get-ml-serving-app-kubeconfig --app-crn "${APP_CRN}" \
  | jq -r '.kubeConfig // .kubeconfig' > "${WORK_DIR}/inference.kubeconfig"
```

EKS 操作（Knox パッチ等）は **EKS コンソール CloudShell** を優先してください。

---

## 付録 B: 週末停止（ノードグループ / Compute Cluster）

本リポジトリの構成では、AI Inference は **既存 Compute Cluster 上** に作成するため、`describe-ml-serving-app` の **`app.instanceGroups` は返りません**（`null` は正常）。ノード情報は **Compute Cluster 側** にあります。

### B.1 まず Inference と Compute Cluster を特定

**注意:** `cdp compute list-clusters` の **`clusterName`**（例: `dsol202606-cc-recovery`）と、`list-ml-serving-apps` の **`cluster.clusterName` / `liftieID`**（例: `liftie-xxxxxxxx`）は **別物** です。名前一致で `CLUSTER_CRN` を探すと **空になります**。

**推奨:** `list-ml-serving-apps` の **`clusterCrn`**（アプリ直下のフィールド）をそのまま使います。

```bash
export ENV_NAME="${ENV_PREFIX}-cdp-env"

cdp ml list-ml-serving-apps \
  | jq --arg env "${ENV_NAME}" '.apps[] | select(.environmentName == $env) | {
      appName,
      appCrn,
      clusterCrn,
      status,
      liftieID: .cluster.liftieID,
      k8sClusterName: .cluster.clusterName,
      domainName: .cluster.domainName
    }'

export APP_CRN=$(cdp ml list-ml-serving-apps \
  | jq -r --arg env "${ENV_NAME}" '.apps[] | select(.environmentName == $env) | .appCrn')

# 方法 A（推奨）: list-ml-serving-apps の clusterCrn を直接使用
export CLUSTER_CRN=$(cdp ml list-ml-serving-apps \
  | jq -r --arg crn "${APP_CRN}" '.apps[] | select(.appCrn == $crn) | .clusterCrn')

export LIFTIE_ID=$(cdp ml list-ml-serving-apps \
  | jq -r --arg crn "${APP_CRN}" '.apps[] | select(.appCrn == $crn) | .cluster.liftieID // .cluster.clusterName')

echo "APP_CRN=${APP_CRN}"
echo "CLUSTER_CRN=${CLUSTER_CRN}"
echo "LIFTIE_ID=${LIFTIE_ID}"
```

`CLUSTER_CRN` が空の場合のみ **方法 B**（liftie ID で Compute Cluster を突合）:

```bash
export LIFTIE_ID="${LIFTIE_ID:?set from above}"

cdp compute list-clusters --env-name-or-crn "${ENV_NAME}" \
  | jq '.clusters[] | {clusterName, clusterCrn, status, isDefault}'

# 各 Compute Cluster の clusterId / clusterName を liftieID と照合
export CLUSTER_CRN=$(cdp compute list-clusters --env-name-or-crn "${ENV_NAME}" \
  | jq -r '.clusters[].clusterCrn' \
  | while read -r crn; do
      cdp compute describe-cluster --cluster-crn "${crn}" \
        | jq -r --arg liftie "${LIFTIE_ID}" --arg crn "${crn}" '
            .cluster as $c
            | ($c.clusterId // $c.clusterName // "") as $id
            | select($id == $liftie or ($c.clusterName // "") == $liftie)
            | $crn
          '
    done | head -1)

echo "CLUSTER_CRN=${CLUSTER_CRN}"
```

突合結果の確認:

```bash
cdp compute describe-cluster --cluster-crn "${CLUSTER_CRN}" \
  | jq '{clusterName: .cluster.clusterName, clusterId: .cluster.clusterId, status: .cluster.status}'
```

### B.2 インスタンスグループ名・instance type の確認（Compute Cluster）

`instanceGroups` は **配列ではなく map** です。

```bash
cdp compute describe-cluster --cluster-crn "${CLUSTER_CRN}" \
  | jq '.cluster.instanceGroups | to_entries[] | {
      instanceGroupName: (.value.instanceGroupName // .key),
      instanceType: (.value.instanceTypes[0] // .value.instanceType // "N/A"),
      minInstance: .value.minInstance,
      maxInstance: .value.maxInstance,
      instanceCount: .value.instanceCount,
      running: .value.instanceStates.running
    }'
```

| 項目 | 取得元 |
| --- | --- |
| `--instance-group-name`（modify 用） | 上記 **`instanceGroupName`** |
| `--instance-type`（modify 用） | 上記 **`instanceType`**（EKS は `instanceTypes[0]` のことが多い） |

### B.3 週末停止の手順（suspend-cluster）

公式前提: **Environment が Start 済みで `AVAILABLE`**、Compute Cluster 上に **稼働中ワークロードなし**（[Cloudera ドキュメント](https://docs.cloudera.com/management-console/cloud/container-service/topics/mc-suspend-resume-compute-clusters-aws.html)）。

**Environment を先に Stop すると FreeIPA が `STOPPED` になり、suspend の Service Discovery 検証が失敗します。** 次の順序を守ってください。

```text
1. MC で Environment Start → AVAILABLE（FreeIPA 起動）
2. Model Endpoint 停止・削除
3. 非 infra インスタンスグループを min=0 max=0 にスケール（B.3.1）
4. ノード 0 になるまで待つ
5. cdp compute suspend-cluster
6. （任意）MC で Environment Stop + egress/bastion EC2 Stop
```

#### B.3.1 suspend 前: インスタンスグループを 0 にスケール

suspend 検証で `mlgpu-xxxx`, `mlinfra` 等が残っていると **FAILED** になります。`modify-ml-serving-app` で **グループごと** min/max を 0 にします。

インスタンスグループと instance type の確認（list または compute describe）:

```bash
# list-ml-serving-apps に instanceGroups がある場合
cdp ml list-ml-serving-apps \
  | jq --arg crn "${APP_CRN}" '.apps[] | select(.appCrn == $crn) | .instanceGroups // [] | .[] | {
      instanceGroupName: (.instanceGroupName // .name),
      instanceType,
      minInstances, maxInstances, instanceCount
    }'

# または compute describe（map 形式）
cdp compute describe-cluster --cluster-crn "${CLUSTER_CRN}" \
  | jq '.cluster.instanceGroups | to_entries[] | {
      instanceGroupName: (.value.instanceGroupName // .key),
      instanceType: (.value.instanceTypes[0] // .value.instanceType),
      instanceCount: .value.instanceCount,
      running: .value.instanceStates.running
    }'
```

検証エラーに出た名前（例: `mlgpu-4889`, `mlgpu-79e1`, `mlinfra`）それぞれに対し:

```bash
# 例: エラーメッセージ / describe の値に置き換え
cdp ml modify-ml-serving-app \
  --app-crn "${APP_CRN}" \
  --instance-group-name "mlgpu-4889" \
  --min 0 --max 0 \
  --instance-type "<上記で確認した instanceType>"

cdp ml modify-ml-serving-app \
  --app-crn "${APP_CRN}" \
  --instance-group-name "mlgpu-79e1" \
  --min 0 --max 0 \
  --instance-type "<instanceType>"

# mlinfra もエラーに含まれる場合は同様（infra だがノード残存時は suspend 不可）
cdp ml modify-ml-serving-app \
  --app-crn "${APP_CRN}" \
  --instance-group-name "mlinfra" \
  --min 0 --max 0 \
  --instance-type "<instanceType>"
```

ノードが 0 になったことを確認してから suspend:

```bash
cdp compute describe-cluster --cluster-crn "${CLUSTER_CRN}" \
  | jq '.cluster.instanceGroups | to_entries[] | {
      name: (.value.instanceGroupName // .key),
      running: .value.instanceStates.running,
      total: .value.instanceStates.total
    }'
```

#### B.3.2 suspend / resume

```bash
cdp compute suspend-cluster --cluster-crn "${CLUSTER_CRN}"

cdp compute describe-cluster --cluster-crn "${CLUSTER_CRN}" \
  | jq '{status: .cluster.status, message: .cluster.message}'
```

`validationResponse.result` が `FAILED` の場合はメッセージ内の **Instance Group** / **FreeIPA** を確認。

再開（月曜など）:

```bash
# 1. Environment Start → AVAILABLE
cdp compute resume-cluster --cluster-crn "${CLUSTER_CRN}"
# 2. 必要なら modify-ml-serving-app で min/max を元に戻す
# 3. Model Endpoint 再デプロイ
```

### B.4 `modify-ml-serving-app` と `describe-ml-serving-app`

- **`describe-ml-serving-app` の `app.instanceGroups` は null**（Compute Cluster 利用時は正常）
- **`list-ml-serving-apps` の `instanceGroups`** または **`compute describe-cluster` の `instanceGroups` map** からグループ名・instance type を取得
- **suspend 前のスケールダウン** と **再開後のスケールアップ** の両方で `modify-ml-serving-app` を使用

```bash
cdp ml list-ml-serving-apps \
  | jq --arg crn "${APP_CRN}" '.apps[] | select(.appCrn == $crn) | .instanceGroups // [] | .[] | {
      instanceGroupName: (.instanceGroupName // .name),
      instanceType,
      minInstances: (.minInstances // .autoscaling.minInstances),
      maxInstances: (.maxInstances // .autoscaling.maxInstances)
    }'
```

---

## 改訂履歴

| 日付 | 内容 |
| --- | --- |
| 2026-06-03 | 初版（AI Inference / Knox DSE-48642 / cdp-proxy-config / Model Endpoint） |
| 2026-06-04 | §5.2: `list-ml-serving-apps` の正しいフィールド名（`appName`/`appCrn`/`cluster.clusterName`）と kubeconfig 取得 |
| 2026-06-04 | 付録 B: 週末停止（`describe-ml-serving-app` に instanceGroups 無し → Compute Cluster 参照） |
| 2026-06-04 | 付録 B.1: `CLUSTER_CRN` は `list-ml-serving-apps.clusterCrn` を使用（liftie 名と compute clusterName の突合は不可） |
| 2026-06-04 | 付録 B.3: suspend 前に Environment AVAILABLE・インスタンスグループ 0 ノード必須 |
| 2026-06-22 | §6: Registry との No Proxy 差分、§6.1 に K8s API（ClusterIP / Service CIDR）を任意追記 |
