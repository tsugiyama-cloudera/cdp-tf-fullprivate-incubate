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

Registry とは **別クラスタ** です。

```bash
cdp ml list-ml-serving-apps | jq '.apps[] | {name, crn, status, clusterName: .cluster.name}'
```

または MC の AI Inference 詳細から EKS クラスタ名（例: `liftie-4zh7cz62`）を控えます。

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

### 6.1 不足時の patch（既存環境の回避）

MC Proxy を後から広げられない場合、**Endpoint Pod が参照する namespace** の ConfigMap を更新します。

```bash
export NO_PROXY_SUFFIX='.amazonaws.com,.s3.amazonaws.com,s3.amazonaws.com,<DATALAKE_BUCKET>.s3.amazonaws.com,10.98.0.0/24'

kubectl edit cm cdp-proxy-config -n serving-default
kubectl edit cm cdp-proxy-config -n kserve
```

`NO_PROXY` と `no_proxy` の末尾に `,${NO_PROXY_SUFFIX}` を追加（`HTTP_PROXY` は変更しない）。

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
| Storage Logs → `Found credentials from IAM Role` の後 **AccessDenied** | ワーカーロールの S3 読み取りポリシー |
| Inference UI が開かない | SOCKS / 私有 LB |

---

## 改訂履歴

| 日付 | 内容 |
| --- | --- |
| 2026-06-03 | 初版（AI Inference / Knox DSE-48642 / cdp-proxy-config / Model Endpoint） |
