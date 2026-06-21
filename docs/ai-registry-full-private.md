# フルプライベート CDP 環境 Cloudera AI Registry / Model Hub 手順

本書は、本リポジトリで構築したフルプライベート環境において **Cloudera AI Registry** をデプロイし、**Model Hub** からモデルをインポートするまでの手順をまとめたものです。

関連ドキュメント:

- [構築手順書](deployment-procedure-full-private.md)（`aws-init` 〜 `aws` まで）
- [Model Registry 手動 IRSA 手順書](model-registry-irsa-full-private.md)（Private Registry の Model Hub インポート前）
- [Cloudera AI Inference 手順書](ai-inference-full-private.md)（Compute Cluster / Model Endpoint）
- [運用者アクセス手順書](operator-access-procedure-full-private.md)（SOCKS 経由の `*.cloudera.site` アクセス）
- [ネットワーク設計書](network-design-full-private.md)

---

## 1. 前提

次が完了していること。

| 項目 | 確認 |
| --- | --- |
| `aws-egress` 適用済み | Squid が `running` |
| MC `Shared Resources > Proxies` 登録済み | `proxy_config_name` が `aws` の tfvars と一致。**No Proxy Hosts** に S3/AWS 含む（[構築手順書 Step 4](deployment-procedure-full-private.md#7-step-4-cdp-management-console-で-proxy-登録)） |
| CDP Environment `AVAILABLE` | `deployment_template = "private"` |
| 環境で **Cloudera AI 有効化**済み | 有効化時に **同一 Proxy** を指定 |
| 運用者アクセス | Ingress SSM + SOCKS（Model Hub / Registry UI 用） |

**Terraform では AI Registry やクラスタ内 Knox は管理しません。** Registry 作成後に [DSE-48642](https://docs.cloudera.com/machine-learning/cloud/release-notes/topics/ml-known-issues-limitations.html) の Knox JVM プロキシ設定が **毎環境・毎回** 必要です（土曜リセットで再構築する場合も同様）。

---

## 2. 構築の流れ（概要）

```text
[MC]  Cloudera AI を環境で有効化（Proxy 再指定）
[MC]  AI Registry 作成（Private Cluster ON、Public LB OFF）
[EKS] AWS コンソール CloudShell で Knox パッチ + model-registry-v2 再起動
[IAM] Model Registry 手動 IRSA（インポート前。Private Registry で必須の場合あり）
[PC]  SOCKS ON で Model Hub 動作確認・インポート
```

| 操作場所 | 用途 |
| --- | --- |
| **ローカル PC** | `cdp ml`、Terraform output、ブラウザ（MC / Model Hub） |
| **AWS EKS コンソール（CloudShell）** | **AI Registry の EKS 上で `kubectl`**（`liftie-*` クラスタ） |
| **ローカル + SOCKS** | `*.cloudera.site`（Registry URL / Model Hub API） |

プライベート EKS API はローカル `kubectl` からは届かないことが多いです。**Registry クラスタの操作は EKS コンソールの CloudShell を使います**（ローカル `kubectl` + SOCKS は Model Hub 用の Registry HTTPS 確認向けであり、EKS API 操作には使いません）。

---

## 3. Step 1: Cloudera AI の有効化

**実施箇所:** Cloudera Management Console

1. 対象 Environment を開く
2. **Cloudera AI** を有効化
3. **Environment 作成時と同じ Proxy Configuration** を選択

Data Service は環境レベルに加え、有効化時にも Proxy 指定が必要です（[Using a non-transparent proxy](https://docs.cloudera.com/management-console/cloud/proxy/topics/mc-proxy-server-overview.html)）。

---

## 4. Step 2: AI Registry の作成

**実施箇所:** Cloudera Management Console → Cloudera AI → **Create AI Registry**

| 項目 | フルプライベートでの推奨 |
| --- | --- |
| Environment | 対象環境（例: `ts0531p`） |
| **Private Cluster** | **ON（チェック）** |
| **Enable Public IP Address for Load Balancer** | **OFF（チェックしない）** |

Private LB のため、Registry UI（`modelregistry.*.cloudera.site`）は [運用者アクセス手順書](operator-access-procedure-full-private.md) の **SOCKS** 経由で開きます。

作成完了まで 15〜60 分かかることがあります。MC 上で **Available** になるまで Model Hub 操作は待ちます。

**メモ:** Registry 作成後、MC の AI Registries 詳細に表示される **Domain name**（`https://modelregistry.ml-....cloudera.site`）を控えます。

---

## 5. Step 3: Knox JVM プロキシ（DSE-48642）— EKS CloudShell

### 5.1 背景

Model Hub で Registry を選択すると `GET .../api/v2/models` が **401** になる場合、非透過プロキシ環境で Registry 内 **Knox** が Control Plane へ到達できていないことがあります（DSE-48642）。

**症状の切り分け（ブラウザ DevTools）:**

| `/api/v2/models` の Status | 意味 |
| --- | --- |
| `(failed)` / timeout | SOCKS 未設定など（[運用者アクセス手順書](operator-access-procedure-full-private.md)） |
| **401** + `Authorization: Bearer` あり | **本 Step（Knox パッチ）が必要** |
| **200** | Knox パッチ済み。Model Hub インポートへ |

### 5.2 JVM オプション文字列の取得

`aws-egress` の Terraform output を使用します（手入力ミス防止）。

```bash
cd aws-egress
terraform output -raw knox_jvm_proxy_opts
```

表示例:

```text
-Dhttps.proxyHost=10.98.0.20 -Dhttps.proxyPort=3128 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true
```

Proxy の IP/Port は MC Environment Summary の Proxy 表示と一致していることを確認します。

### 5.3 EKS クラスタの特定

`cdp ml list-model-registries` の JSON フィールドは **`serviceName` / `domain`** です（`name` / `domainName` ではありません）。EKS クラスタ名（`liftie-*`）は **`get-model-registry-kubeconfig`** から取得します。

```bash
export ENV_NAME="${ENV_PREFIX}-cdp-env"   # 例: dsol202606-cdp-env

# Registry 一覧（フィールド名に注意）
cdp ml list-model-registries \
  | jq --arg env "${ENV_NAME}" '.modelRegistries[] | select(.environmentName == $env) | {
      serviceName,
      crn,
      domain,
      environmentName,
      status,
      endpointPublicAccess
    }'

# 対象 Registry の CRN を export（環境に 1 件の場合）
export MR_CRN=$(cdp ml list-model-registries \
  | jq -r --arg env "${ENV_NAME}" '.modelRegistries[] | select(.environmentName == $env) | .crn')
echo "MR_CRN=${MR_CRN}"

# kubeconfig から EKS クラスタ名（liftie-*）を取得
export WORK_DIR="${WORK_DIR:-${HOME}/model-registry-irsa}"
mkdir -p "${WORK_DIR}"

cdp ml get-model-registry-kubeconfig --model-registry-crn "${MR_CRN}" \
  > "${WORK_DIR}/model-registry.kubeconfig"

export CLUSTER_NAME=$(kubectl config view --kubeconfig="${WORK_DIR}/model-registry.kubeconfig" \
  --minify -o jsonpath='{.clusters[0].name}')
echo "CLUSTER_NAME=${CLUSTER_NAME}"
```

`kubectl` が無い場合の代替:

```bash
export CLUSTER_NAME=$(grep -E '^  name: liftie-' "${WORK_DIR}/model-registry.kubeconfig" | head -1 | awk '{print $2}')
echo "CLUSTER_NAME=${CLUSTER_NAME}"
```

> **補足:** `domain` は Registry の FQDN（例: `modelregistry.<env>.cloudera.site`）です。EKS コンソールで接続する **`liftie-*` クラスタ名** とは別物です。

### 5.4 AWS EKS コンソールで CloudShell を開く

1. AWS マネジメントコンソール → **Amazon EKS**
2. リージョン（例: `ap-northeast-1`）を合わせる
3. クラスタ一覧から **AI Registry のクラスタ**（例: `liftie-xlkdtt9v`）を選択
4. **接続**（Connect）をクリック
5. 画面の手順に従い、**CloudShell 上のターミナル**で `kubectl` を実行する方式を選ぶ

> **補足:** 接続 UI 上は「CloudShell」と表示されます。ローカル PC のターミナルではなく、**AWS 側からプライベート EKS API に到達できるシェル**で作業します。

接続に使う IAM ユーザー/ロールは、次の **IAM ロール ARN**（SSO の assumed-role セッション ARN ではない）で EKS Access が付与されている必要があります。

```text
arn:aws:iam::<ACCOUNT_ID>:role/AWSReservedSSO_<role-name>_<suffix>
```

`grant-model-registry-access` でエラーになった場合は [付録 A](#付録-a-eks-アクセス権grant-model-registry-access) を参照。

### 5.5 CloudShell で Knox を更新

CloudShell ターミナルで実行します。`KNOX_OPTS` は 5.2 の output を貼り付けます。

```bash
# 確認
kubectl get pods -n knox
kubectl auth can-i update deployment -n knox

# 方法 A: 環境変数を置換（推奨・edit 不要）
export KNOX_OPTS='-Dhttps.proxyHost=10.98.0.20 -Dhttps.proxyPort=3128 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true'

kubectl set env deployment/knox -n knox \
  KNOX_GATEWAY_DBG_OPTS="${KNOX_OPTS}"

# 反映待ち（-w は Ctrl+C で終了）
kubectl get pods -n knox -w
```

`knox-xxxxxxxx-xxxxx` が **Running 1/1** 1 本になれば OK です。旧 Pod の `Terminating` / `Error` はローリング更新中の表示で、新 Pod が Running なら問題ありません。

**方法 B（edit）:** 公式 workaround どおり `kubectl edit deployment knox -n knox` で `KNOX_GATEWAY_DBG_OPTS` の `value:` 先頭に同じ文字列を追加してもよいです。

設定確認:

```bash
kubectl get deployment knox -n knox -o yaml | grep -A2 KNOX_GATEWAY_DBG_OPTS
```

### 5.6 model-registry-v2 の再起動

```bash
kubectl rollout restart deployment model-registry-v2 -n mlx
kubectl get pods -n mlx
```

`model-registry-v2` が **Running** になるまで待ちます。

---

## 6. Step 4: Model Registry 手動 IRSA（Private Registry / Model Hub インポート前）

Private AI Registry（`endpointPublicAccess: false`）では、Model Hub インポート時に Pod 内 `aws s3 cp` が **`Unable to locate credentials`** で失敗することがあります。CDP が IRSA を Pod に付与しない場合、**Knox パッチ後・インポート前**に次を実施します。

**詳細手順（IAM ロール、OIDC プロバイダ、trust policy 更新、SA 注釈、`NO_PROXY` / `HOME=/tmp`、成功判定）:**

→ **[model-registry-irsa-full-private.md](model-registry-irsa-full-private.md)**

`NO_PROXY` には **S3 / STS 向け CIDR・FQDN** に加え、Import 時に Job をスケジュールする **Kubernetes API（ClusterIP / Service CIDR）** も含めてください（§7 参照）。`.svc` のみでは `https://172.20.0.1:443` 宛て API 呼び出しが Squid 経由になり、Import **500** になることがあります。

**成功判定の目安（EKS CloudShell）:**

```bash
kubectl exec -n mlx deploy/model-registry-v2 -c model-registry-v2 -- sh -c '
  mkdir -p /tmp/.aws && export HOME=/tmp
  aws sts get-caller-identity
'
```

`assumed-role/<env_prefix>-model-registry-irsa/...` が表示されれば Model Hub インポートへ進めます。

---

## 7. Step 5: Model Hub の確認（ローカル + SOCKS）

Knox パッチは **EKS CloudShell**、Model Hub の UI/API 確認は **ローカル PC + SOCKS** です。

1. [運用者アクセス手順書](operator-access-procedure-full-private.md) のとおり SSM ポートフォワード + `ssh -D 1090 -N` を起動
2. ブラウザ拡張で **`*.cloudera.site`** を SOCKS `127.0.0.1:1090` に設定
3. Cloudera コンソール → Model Hub → Import
4. DevTools → Network で Registry 選択時の  
   `GET https://modelregistry.<...>.cloudera.site/api/v2/models` が **401 以外**（理想は **200**）であること
5. NGC 等のモデルインポートを実施

NGC 向け FQDN は `aws-egress` の `allowed_fqdns` に含めます（[aws-egress/README.md](../aws-egress/README.md)）。

---

## 8. 土曜リセット後のチェックリスト

```text
□ aws-init / aws-ingress / aws-egress / aws 再 apply
□ MC Proxy 再登録（変更時は削除→再作成）
□ Cloudera AI 有効化 + Proxy
□ AI Registry 作成（Private Cluster ON）
□ terraform output knox_jvm_proxy_opts を控える
□ EKS CloudShell: knox set env + model-registry-v2 restart
□ 手動 IRSA（model-registry-irsa-full-private.md）— 新 Liftie ごとに OIDC / trust policy 更新、§7 NO_PROXY に K8s API 含む
□ SOCKS: Model Hub /api/v2/models が 401 以外
□ モデルインポート成功
```

---

## 9. トラブルシュート

| 症状 | 確認 |
| --- | --- |
| Model Hub で Registry 選択時 **401** | DSE-48642。CloudShell で 5.5〜5.6 を実施 |
| インポート **Unable to locate credentials** | [手動 IRSA 手順書](model-registry-irsa-full-private.md) |
| インポート **500** / `172.20.0.1:443/.../jobs` **Forbidden** | [IRSA 手順書 §7](model-registry-irsa-full-private.md)：`NO_PROXY` に K8s API（ClusterIP / Service CIDR）不足 |
| インポート **InvalidIdentityToken** | 同上 §5〜6（OIDC プロバイダ / trust policy の OIDC ID） |
| `[Errno 30] Read-only file system`（`aws`） | 同上 §7（`HOME=/tmp`） |
| Registry UI が開かない | SOCKS / `ingress_extra_cidrs_and_ports` の 443 |
| CloudShell で `kubectl` forbidden | [付録 A](#付録-a-eks-アクセス権grant-model-registry-access) |
| `grant` で `principalArn ... not valid` | `--identifier` に **IAM ロール ARN** を指定（セッション ARN 不可） |
| ローカル `kubectl` timeout | 想定内。EKS API 操作は CloudShell を使う |
| インポート中 NGC **403** | Squid `allowed_fqdns` / Proxy EC2 再作成（構築手順書 §6.3.1） |

---

## 付録 A: EKS アクセス権（grant-model-registry-access）

Registry クラスタの CloudShell / kubectl には、CDP 側の付与と AWS EKS Access の両方が必要です。

### IAM ロール ARN の取得

```bash
aws sts get-caller-identity
# Arn が arn:aws:sts::...:assumed-role/ROLE_NAME/session の場合:
export ROLE_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ROLE_NAME"
```

### 付与（未実施または失敗時）

```bash
export REGISTRY_CRN="crn:cdp:ml:..."

cdp ml grant-model-registry-access \
  --resource-crn "${REGISTRY_CRN}" \
  --identifier "${ROLE_ARN}"

cdp ml list-model-registry-access --resource-crn "${REGISTRY_CRN}"
```

`User has already been granted` と出て kubeconfig だけ欲しい場合:

```bash
cdp ml get-model-registry-kubeconfig --model-registry-crn "${REGISTRY_CRN}"
```

EKS 操作は **CloudShell** を優先し、ローカル kubeconfig は参照用で十分です。

---

## 改訂履歴

| 日付 | 内容 |
| --- | --- |
| 2026-05-31 | 初版（AI Registry / DSE-48642 / EKS CloudShell / Model Hub） |
| 2026-06-03 | 手動 IRSA 手順書へのリンク・Step 4 追加 |
| 2026-06-03 | MC Proxy No Proxy 前提・Inference 手順書リンク |
| 2026-06-04 | §5.3: `list-model-registries` の正しいフィールド名（`serviceName`/`domain`）と `get-model-registry-kubeconfig` による `liftie-*` 取得 |
| 2026-06-22 | §6: Import 500（K8s API Forbidden）と `NO_PROXY`（K8s ClusterIP / Service CIDR）の注意を追記 |
