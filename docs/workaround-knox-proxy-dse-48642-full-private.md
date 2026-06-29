# ワークアラウンド: Knox JVM プロキシ（DSE-48642）

本書は、フルプライベート環境（非透過プロキシ / Squid）で **Cloudera AI Registry** または **Cloudera AI Inference** 利用時に、Knox が Control Plane へ到達できず **401 Unauthorized** になる既知事象 [DSE-48642](https://docs.cloudera.com/machine-learning/cloud/release-notes/topics/ml-known-issues-limitations.html) への **手動ワークアラウンド** です。

**メイン手順書（要否確認のみ）:**

- Registry: [ai-registry-full-private.md](ai-registry-full-private.md) §5
- Inference: [ai-inference-full-private.md](ai-inference-full-private.md) §5

関連:

- [構築手順書 Step 4](deployment-procedure-full-private.md#7-step-4-cdp-management-console-で-proxy-登録)（MC Proxy 登録）
- `scripts/patch-ai-registry-knox-proxy.sh`（CloudShell 用コマンド表示）

---

## 1. いつ必要か

| 対象 | 症状（SOCKS + DevTools） | 意味 |
| --- | --- | --- |
| **Registry** | `GET .../api/v2/models` → **401** + `Authorization: Bearer` あり | Registry 用 Knox パッチ **必要** |
| **Registry** | 上記 → **200** | **不要**（CDP 自動注入済み、または既にパッチ済み） |
| **Inference** | `POST .../deployEndpoint` → **401** + Bearer あり | Inference 用 Knox パッチ **必要** |
| **Inference** | 上記 → **200 系** | **不要** |

**注意:** Cloudera AI のバージョンアップ後、**Inference クラスタでは CDP がプロビジョニング時に `KNOX_GATEWAY_DBG_OPTS` を自動注入する**場合があります。再構築のたびに **§2 の確認コマンド** を実行し、未設定かつ 401 のときだけ本書 §4 を実施してください。

Registry 側は **自動注入されないことが多い** ため、再構築後は Knox 設定の有無を必ず確認してください。

---

## 2. 要否確認（EKS CloudShell）

**Registry 用 `liftie-*` と Inference 用 `liftie-*` は別クラスタ** です。それぞれで実行します。

### 2.1 Knox Deployment の JVM プロキシ

```bash
kubectl get deployment knox -n knox -o yaml | grep -A2 KNOX_GATEWAY_DBG_OPTS
```

| 結果 | 判定 |
| --- | --- |
| `-Dhttps.proxyHost=<Squid IP> -Dhttps.proxyPort=3128` **あり** | Knox パッチ **済み**（手動 or CDP 自動）。§3 の UI テストへ |
| 空 / `-Dcom.sun.jndi.ldap` のみ | **未設定** → §4 実施（401 が出ている場合） |

Squid の IP/Port は MC Environment Summary の Proxy、または:

```bash
cd aws-egress && terraform output -raw knox_jvm_proxy_opts
```

### 2.2 UI / API の消極テスト（ローカル PC + SOCKS）

[運用者アクセス手順書](operator-access-procedure-full-private.md) の SOCKS を有効にしたうえで:

| 対象 | 確認 |
| --- | --- |
| Registry | Model Hub → Import → Registry 選択時の `GET .../api/v2/models` |
| Inference | Model Endpoints → Create Endpoint 時の `POST .../deployEndpoint` |

**401 かつ §2.1 で未設定** → §4 を実施。  
**200 系** → 本ワークアラウンド **不要**。

---

## 3. EKS クラスタの特定

### Registry

```bash
export ENV_NAME="${ENV_PREFIX}-cdp-env"
export MR_CRN=$(cdp ml list-model-registries \
  | jq -r --arg env "${ENV_NAME}" '.modelRegistries[] | select(.environmentName == $env) | .crn')
cdp ml get-model-registry-kubeconfig --model-registry-crn "${MR_CRN}" > /tmp/mr.kubeconfig
grep -E '^  name: liftie-' /tmp/mr.kubeconfig | head -1
```

EKS コンソール → 表示された **`liftie-*`** → **接続 → CloudShell**。

### Inference

```bash
export ENV_NAME="${ENV_PREFIX}-cdp-env"
cdp ml list-ml-serving-apps \
  | jq --arg env "${ENV_NAME}" '.apps[] | select(.environmentName == $env) | .cluster.clusterName'
```

EKS コンソール → **Inference 用** `liftie-*` → **接続 → CloudShell**。

---

## 4. パッチ手順（401 かつ Knox 未設定の場合）

**実施箇所:** 対象サービスの **EKS コンソール CloudShell**（Private EKS API。ローカル `kubectl` は通常不可）。

### 4.1 JVM オプション文字列

```bash
cd aws-egress
terraform output -raw knox_jvm_proxy_opts
```

表示例:

```text
-Dhttps.proxyHost=10.98.0.20 -Dhttps.proxyPort=3128 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true
```

### 4.2 Knox Deployment を更新

```bash
kubectl get pods -n knox
kubectl auth can-i update deployment -n knox

export KNOX_OPTS='-Dhttps.proxyHost=10.98.0.20 -Dhttps.proxyPort=3128 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true'
# ↑ terraform output -raw knox_jvm_proxy_opts の値を使用

kubectl set env deployment/knox -n knox \
  KNOX_GATEWAY_DBG_OPTS="${KNOX_OPTS}"

kubectl rollout status deployment/knox -n knox
kubectl get deployment knox -n knox -o yaml | grep -A2 KNOX_GATEWAY_DBG_OPTS
```

`knox-...` が **Running 1/1** になるまで待ちます。

**方法 B:** `kubectl edit deployment knox -n knox` で `KNOX_GATEWAY_DBG_OPTS` の `value:` 先頭に同じ文字列を追加しても可（[DSE-48642 公式 workaround](https://docs.cloudera.com/machine-learning/cloud/release-notes/topics/ml-known-issues-limitations.html)）。

### 4.3 Registry のみ: model-registry-v2 再起動

Inference では通常 **不要** です。

```bash
kubectl rollout restart deployment model-registry-v2 -n mlx
kubectl rollout status deployment/model-registry-v2 -n mlx
```

### 4.4 成功判定

§2.2 の DevTools テストを再実行し、**401 が解消**することを確認します。

---

## 5. スクリプト（コマンド表示）

リポジトリルートから Registry 向け CloudShell コマンドを表示:

```bash
chmod +x scripts/patch-ai-registry-knox-proxy.sh
./scripts/patch-ai-registry-knox-proxy.sh
```

Inference 向けも **同じ `KNOX_OPTS`** です。対象 EKS クラスタが **Inference 用 liftie-*** であることだけ注意してください。

---

## 6. 注意事項

- **CDP 非公式ワークアラウンド** です。Helm reconcile で設定が消える場合があります。再構築・Upgrade 後は §2 を再実行してください。
- Knox パッチは **Registry クラスタと Inference クラスタで個別** です。片方だけ実施しても、もう一方の 401 は解消しません。
- `(failed)` / timeout は Knox 以前の **SOCKS 未設定** 等の可能性があります（[運用者アクセス手順書](operator-access-procedure-full-private.md)）。

---

## 改訂履歴

| 日付 | 内容 |
| --- | --- |
| 2026-06-22 | 初版（要否確認 + Registry/Inference 共通パッチ。メイン手順書から分離） |
