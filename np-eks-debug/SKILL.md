---
name: np-eks-debug
description: EKS(dev/stg) 환경의 인프라·배포 상태를 조사한다 — 토폴로지 확인, PR 머지가
  실제 배포됐는지, curl로 API 직접 호출, GitOps/ArgoCD sync 상태, 워커/백엔드 로그로
  증상별 원인 추적. "머지했는데 반영 안 됨", "배포 확인해줘", "API 직접 찔러보고 싶어",
  "워커 로그 봐줘" 같은 인프라 조사 요청에 사용. np run을 직접 실행하려면
  cloud-dev-run(np-enterprise 프로젝트 스킬)을, MQ 큐 상태만 보려면 mq-status를 대신 사용.
argument-hint: "[env(dev|stg)]"
marketplace: false
---

# np-eks-debug — EKS 인프라·배포 상태 조사

## 목적

EKS(dev 또는 stg)에서 "머지했는데 반영이 안 된 것 같다", "지금 뭐가 배포돼 있는지",
"백엔드를 거치지 않고 API를 직접 두드려보고 싶다" 같은 인프라/배포 조사를 한다.
`np run`을 직접 실행해 E2E를 검증하려면 이 스킬이 아니라 np-enterprise 프로젝트의
`cloud-dev-run` 스킬을 쓴다. MQ 큐 상태(ready/unacked/DLQ)만 보려면 `mq-status`를 쓴다.

인자로 `env`(`dev` 또는 `stg`, 생략 시 `dev`)를 받는다. 아래 모든 섹션의 `<env>`는
이 인자로 치환한다.

## 사전 준비

- kubectl context: `kubectx eks-<env>` (context 목록/병합 방식은
  `~/.kube/configs/README.md` 참고 — np_v2 리포의
  `docs/superpowers/specs/2026-09-01-kubeconfig-management-design.md` 설계 결과물)
- `kubectl config current-context`가 `eks-<env>`가 아니면 먼저 `kubectx eks-<env>`로 전환할 것

## 0. 한눈에 보는 토폴로지

```
np CLI (client, 로컬 머신)
  │  NP_CLIENT_API_URL=https://api.<env>.netspresso.ai
  ▼
istio ingress (10.13.18.16) ── EKS 클러스터 np-<env>-eks (ap-northeast-2)
  │
  ├─ enterprise-backend        (pynp, :8000)  ← np CLI가 직접 때리는 유일한 서비스
  │     │  NP_ENGINE_BASE_URL=http://enterprise-engine-api:8000/
  │     ├─ HTTP → enterprise-engine-api   (run.yaml/run.detail.yaml/validate 계산기, stateless)
  │     ├─ RabbitMQ(np.events, :5671 TLS) → enterprise-engine-worker  (run 실제 실행)
  │     ├─ PostgreSQL: np-<env>-pg... (실제 엔드포인트는 §8 인프라 치트시트 참고 — dev는 확인됨, stg는 최초 사용 시 확인 필요)
  │     ├─ S3(=MINIO_* 설정): np-<env>-platform-arm-093529868216 (presigned URL 발급처, stg는 최초 사용 시 확인 필요)
  │     ├─ mosquitto (MQTT, 진행상태 push)
  │     └─ catalog: https://api-npcat.dev.nota.ai (모델/데이터셋 원천 — env 무관하게 항상 dev 카탈로그 사용, 팀 확인 필요시 재검증)
  ├─ enterprise-backend-auth   (:8100, auth.<env>.netspresso.ai)
  ├─ enterprise-backend-sdk / netspresso-sdk-{a..e}  (Phase1 SDK 경로, v2.x — Phase2와 무관)
  ├─ enterprise-frontend       (app.<env>.netspresso.ai)
  └─ model-explorer            (model-explorer.<env>.netspresso.ai)
```

⚠️ **stg 확인 필요 항목**: 위 다이어그램에서 `np-<env>-pg`, `np-<env>-platform-arm-...`,
catalog 엔드포인트는 dev 기준으로 확인된 값이다. stg에서 처음 조사할 때 §2 kubectl로
실제 값을 확인하고 이 표를 업데이트할 것.

---

## 1. 소스 디렉토리 → 실행 위치 매핑

env와 무관하게 항상 동일하다 (배포 대상 클러스터만 dev/stg로 달라짐).

| 소스 (np-enterprise/) | 실행 위치 | 배포 단위 | 로그 보는 곳 |
|---|---|---|---|
| `client/` (np_client, `np` CLI) | 로컬 머신 `.venv` | wheel 설치본 (`pip install np_client-*.whl` 또는 `pip install ./client`) | 터미널 출력. `--debug -v`, `LOG_LEVEL=DEBUG` |
| `backend/` (pynp) | EKS `deploy/enterprise-backend` | image `enterprise-backend:sha-<8>` | `kubectl logs -n netspresso deploy/enterprise-backend` |
| `engine/` role=api (scenario/validate/health) | EKS `deploy/enterprise-engine-api` | image `enterprise-engine-api:sha-<8>` (`ENGINE_ROLE=api`) | `kubectl logs -n netspresso deploy/enterprise-engine-api` |
| `engine/` role=worker (run 실행: GO/GQ/compile/evaluate) | EKS `deploy/enterprise-engine-worker` | image `enterprise-engine-worker:sha-<8>` (`ENGINE_ROLE=worker`) | `kubectl logs -n netspresso deploy/enterprise-engine-worker` |
| `backend-auth/` | EKS `deploy/enterprise-backend-auth` | `enterprise-backend-auth:sha-<8>` | 〃 |
| `frontend/` | EKS `deploy/enterprise-frontend` | | 〃 |
| `common/` (np-common) | backend/engine 이미지에 **포함되어 빌드** | 단독 배포 없음 | 소비자 서비스 로그에서 확인 |
| `sdk/` (Phase1) | `enterprise-backend-sdk` + `netspresso-sdk-*` sts | 태그 `v2.x` | Phase2 이슈와 보통 무관 |

---

## 2. kubectl 기본기

⚠️ **권한 제약 (실측 확인됨, 원본 문서에는 없던 함정)**: 이 kubeconfig가 assume하는
`np-developer-eks-viewer` role은 읽기 전용이다. `kubectl port-forward`/`kubectl exec`는
`Forbidden`으로 막힌다 (`pods/portforward`, `pods/exec` 권한 없음). 아래에서 이 제약과
대안을 먼저 정리하고, 이어서 되는 것들을 정리한다.

```bash
# context 전환 (kubectx eks-<env>, ~/.kube/configs/README.md 참고)
kubectx eks-<env>
kubectl config current-context   # → eks-<env> 확인

# 전체 상태 (조회는 됨)
kubectl get pods -n netspresso -o wide
kubectl get deploy -n netspresso -o wide      # ← IMAGES 컬럼에 sha-<8> 태그 = 배포 버전

# 로그 (deploy/ 대상 — 상주 pod가 있는 backend/engine-api/backend-auth/frontend는 됨)
kubectl logs -n netspresso deploy/enterprise-backend --since=30m -f
kubectl logs -n netspresso deploy/enterprise-engine-api --since=30m | grep -iE "warn|error"
kubectl logs -n netspresso deploy/enterprise-backend --previous   # 재시작 전 로그

# 이벤트/기동 문제 (조회는 됨)
kubectl describe pod -n netspresso -l app.kubernetes.io/name=enterprise-engine-api | tail -30
kubectl get events -n netspresso --sort-by=.lastTimestamp | tail -20
```

### ⚠️ engine-worker 로그는 위 방식으로 못 본다 — oneshot pod

`enterprise-engine-worker`는 상주 deploy가 아니라 **job당 임시 pod**
(`enterprise-engine-worker-np-worker-<id>`)가 실행을 담당한다. 완료되면 pod가 GC되어
`kubectl logs deploy/enterprise-engine-worker`로는 해당 run의 로그가 안 나온다
(grep 0건이 나와도 "로그가 없다"가 아니라 "이미 사라졌다"일 수 있음).

```bash
# 1) 지금 떠 있는 worker pod 전체 나열 (deploy 하나가 아니라 pod 여러 개)
kubectl get pods -n netspresso | grep worker

# 2) run(experiment) ref로 grep해서 내 job이 어느 pod인지 특정
kubectl logs -n netspresso <worker-pod-이름> | grep <experiment-ref-id>

# 3) 아직 Running인 동안에만 직접 로그 가능. Succeeded/Failed로 넘어가면 pod 자체가
#    곧 지워지므로, run 제출 직후 폴링하며 pod를 잡아야 한다:
until kubectl get pod -n netspresso <worker-pod-이름> -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Failed'; do
  sleep 10
done
```

### ⚠️ port-forward/exec가 막힌 것에 대한 대안

**로그는 Grafana의 익명 Loki datasource proxy로 curl 조회.** `grafana.<env>.netspresso.ai`가
익명 접근을 허용하므로 로그인 세션 없이 datasource proxy를 통해 Loki를 직접 쿼리할 수 있다
(worker pod가 GC된 뒤에도 Loki에는 retention 기간 동안 남아 있다):

```bash
# Loki datasource uid 확인 (dev/stg 모두 P8E80F9AEF21F6940로 확인된 적 있음 — 최초 사용 시 재확인 권장)
curl -s https://grafana.<env>.netspresso.ai/api/datasources | python3 -m json.tool | grep -A3 '"type": "loki"'

# 쿼리 (namespace/pod/container 라벨로 필터)
curl -sG "https://grafana.<env>.netspresso.ai/api/datasources/proxy/uid/<UID>/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="netspresso"} |= "<검색 패턴>"' \
  --data-urlencode "start=<유닉스나노초 시작>" \
  --data-urlencode "end=<유닉스나노초 끝>" \
  --data-urlencode "limit=200" \
  --data-urlencode "direction=forward"
```

**engine-api에 직접 POST해서 backend를 우회 재현하는 것(원본 문서의 port-forward 절차)은
viewer role로는 할 수 없다.** 이 조사가 필요하면 exec/port-forward 권한이 있는 사람에게
요청하거나, Grafana Loki로 engine-api 로그에서 같은 단서(`dataset_source_path is not
provided` 같은 경고)를 찾는 방식으로 대신한다.

### 그 외

```bash
# 강제 재기동 (권한이 있다면 — viewer role에서는 이것도 Forbidden일 수 있음, 시도 후 확인)
kubectl rollout restart deploy/enterprise-engine-api -n netspresso
kubectl rollout status  deploy/enterprise-engine-api -n netspresso
```

로그 팁:
- backend 로그는 JSON 라인. 액세스 로그는 `"logger": "app.access"` (`method`/`path`/`status_code`/`duration_ms`).
  ```bash
  kubectl logs -n netspresso deploy/enterprise-backend --since=15m \
    | grep '"app.access"' | python3 -c "import sys,json;[print(json.loads(l)['ts'],json.loads(l)['method'],json.loads(l)['path'],json.loads(l)['status_code']) for l in sys.stdin]"
  ```
- engine 로그는 `[np_engine] (<env>)` prefix. **개발자용 경고가 근본원인을 직접 말해주는 경우 많음**
  (예: `dataset_source_path is not provided — run.yaml will have no 'metric: # Available:' comment`).

### DB 직접 조회 (컨테이너 안 grep/exec가 막혀 있으므로 이 경로도 실제로는 제한적)

exec 자체가 viewer role에서 Forbidden이므로 아래는 exec 권한이 있는 경우의 참고용 경로다
(원본 문서의 예시 경로 `/app/src/...`는 낡았다 — 실제 경로는 `/app/backend/src/pynp`):

```bash
# 시스템 python3에는 DB 드라이버가 없다. 앱 venv를 써야 한다.
kubectl exec -i -n netspresso deploy/enterprise-backend -- \
  sh -c 'cd /app/backend && .venv/bin/python -' < script.py
```

### kubectl 플래그 표기 함정

`--kubeconfig=경로`처럼 등호로 붙이면 셸이 `~`를 확장하지 않아 파일을 못 찾는 에러가 난다.
`--kubeconfig 경로`처럼 공백으로 띄워 쓸 것.

---

## 3. "머지됐는데 반영됐나?" — 배포 버전 확인 절차

이미지 태그 규칙: **`sha-<커밋 앞8자리>`** (dev 브랜치 push → 자동. stg는 별도 트리거 — §CI/CD 표 참고).

```bash
# 1) 지금 떠 있는 버전
kubectl get deploy -n netspresso -o wide | grep -oE "(backend|engine-api|engine-worker):sha-[a-f0-9]+"

# 2) 그 sha가 내 PR(머지커밋)을 포함하는지
cd <np-enterprise 클론 경로> && git fetch origin dev
MERGE_SHA=$(gh pr view <PR번호> --repo nota-github/np-enterprise --json mergeCommit --jq .mergeCommit.oid)
git merge-base --is-ancestor $MERGE_SHA <배포sha8> && echo "포함됨" || echo "미포함(구버전)"

# 3) GitOps 원장 (desired state) — ArgoCD가 이걸 보고 sync
gh api repos/nota-github/np-k8s-platform/contents/envs/<env>-aws/values.yaml \
  --jq '.content' | base64 -d | grep -E "^\w+:|^  tag:"
#   backend.tag / engineApi.tag / engineWorker.tag / frontend.tag ...

# 4) ArgoCD sync 상태
kubectl get applications -n argocd
#   21-netspresso-backend / 25-netspresso-engine-api / 26-netspresso-engine-worker
#   SYNC=Synced + HEALTH=Healthy 인데 pod 태그가 낡았으면 → rollout 문제, describe로 확인
# UI: https://argocd.<env>.netspresso.ai (⚠️ stg 실제 URL 다를 수 있음 — 최초 사용 시 확인)
```

### CI/CD 파이프라인 (누가 뭘 배포하나)

| 워크플로우 | 트리거 | 산출물 | 배포 대상 |
|---|---|---|---|
| `⛵ K8s [Backend/Engine-API/Engine-Worker/Frontend] build → ECR → GitOps` | dev push (paths 필터) — **자동** | ECR+DockerHub `sha-<8>` + np-k8s-platform values.yaml writeback PR (dev는 auto-merge) | **EKS dev (api.dev)** — ArgoCD가 수 분 내 sync |
| `⭐CI [Engine] 테스트 및 이미지생성` (`enterprise-engine-ci.yml`) | push는 **테스트만**. 이미지는 dispatch/call 시에만 | DockerHub `notadockerhub/*:latest-dev` | 없음 (이미지 push까지만) |
| `⭐️CI/CD [Engine] 통합` (`enterprise-engine-cicd.yml`) | **수동 dispatch** | latest-dev 빌드 + compose 배포 | 3090i 등 on-prem compose 스택 |
| `⭐️CD [Server] 배포` (`enterprise-backend-cd.yml`) | **수동 dispatch** | — | dev→swd-dev-01, staging/demo→3090i, prod→SSM |

핵심: **EKS(api.dev)는 머지만 하면 자동 배포**(빌드~sync 총 30분 내외).
**EKS stg는 배포 트리거가 dev와 다를 수 있음 — 최초 조사 시 위 표의 실제 stg 행 확인 필요.**
**3090i/on-prem compose 스택은 수동 dispatch 없으면 영원히 구버전** (이건 EKS와 무관한 별도 스택, §7 참고).

```bash
# 머지 후 자동 빌드가 돌았는지
gh run list --repo nota-github/np-enterprise --branch dev --limit 10 \
  --json displayTitle,name,conclusion,createdAt,headSha \
  --jq '.[] | "\(.createdAt) \(.conclusion) \(.name) [\(.headSha[0:8])]"'
```

---

## 4. backend API 직접 호출 (curl)

베이스: `https://api.<env>.netspresso.ai` · 스펙: `/openapi.json` · Swagger: `/docs`

⚠️ **project/experiment 조회는 workspace 스코프** — CLI의 Bearer 토큰 없이 curl하면
내 리소스가 `Project not found`로 나온다 (버그 아님, `find_by_ref_id(ref_id, workspace_id)`).

⚠️ **stg 주의**: staging(`:8000`) 환경은 run/export API가 배포되지 않은 상태로 확인된 적 있음
(np-enterprise `qa-phase2` 스킬 기준). 조회 계열(`GET /api/v1/projects` 등)은 되더라도
run 제출/export는 stg에서 안 될 수 있으니 실패 시 이 항목부터 의심할 것.

```bash
# CLI가 쓰는 workspace 토큰 추출 (np workspace init 때 발급, ~/.config/np/credentials.json)
TOKEN=$(python3 -c "import json;d=json.load(open('$HOME/.config/np/credentials.json'));print(d.get('token') or d.get('access_token') or list(d.values())[0])")
AUTH="Authorization: Bearer $TOKEN"

# 내 로컬 project 디렉토리 ↔ backend ref_id 매핑
python3 -m json.tool ~/.config/np/refs.json

# 자주 쓰는 조회 (<env>를 dev 또는 stg로 치환)
curl -s -H "$AUTH" https://api.<env>.netspresso.ai/api/v1/projects | python3 -m json.tool
curl -s -H "$AUTH" https://api.<env>.netspresso.ai/api/v1/projects/<ref>/datasets | python3 -m json.tool
curl -s -H "$AUTH" "https://api.<env>.netspresso.ai/api/v1/datasets/samples?size=100" | python3 -m json.tool
curl -s -H "$AUTH" https://api.<env>.netspresso.ai/api/v1/experiments/projects/<project_ref> | python3 -m json.tool
```

ref_id 종류 구분 (혼동 주의):
- `Dataset.ref_id` — 원본 데이터셋 (예: imagenet1k)
- `DatasetSample.ref_id` — split 샘플 (예: imagenet1k_calib_seed42_n2). **`project_dataset.dataset_ref_id`에 저장되는 건 이것**
- `ProjectDataset.ref_id` — 매핑 행 자체의 id

---

## 5. np CLI 쪽 디버깅 (로컬 머신)

```bash
np health ready                         # 연결 확인 (NP_CLIENT_API_URL이 대상 env를 가리키는지 먼저 확인)
np <cmd> --debug -v                     # 상세 로그
LOG_LEVEL=DEBUG np <cmd> --debug        # 더 상세

# CLI 상태 파일
~/.config/np/credentials.json   # workspace Bearer 토큰
~/.config/np/refs.json          # 로컬 경로 → project/experiment ref_id
~/.np/config.json               # workspace_path 오버라이드 (오래된 값 주의)

# 소스로 설치해 client 수정 테스트
pip install -e <np-enterprise 클론 경로>/client
```

---

## 6. 증상별 진단 순서 (플레이북)

### A. run.yaml / run.detail.yaml 내용이 이상함 (주석 누락, 필드 누락 …)
1. `np experiments create` 직후 **engine-api 로그**부터 — 경고가 원인을 직접 말해줌:
   ```bash
   kubectl logs -n netspresso deploy/enterprise-engine-api --since=10m | grep -iE "warn|hint|dataset|metric"
   ```
2. 경고가 `dataset_source_path is not provided` 류면 → **backend가 안 보낸 것**.
   backend의 `_generate_basic_run_yaml` 입력(calibration 조회) 검증: §4로 project datasets 조회.
3. engine 자체 의심이면 → §2의 "port-forward/exec가 막힌 것에 대한 대안" 참고
   (viewer role로는 engine에 직접 POST 불가 — Grafana Loki로 engine-api 로그에서 유추).
4. 배포 버전 의심이면 → §3.

### B. `np run` 이 안 돌거나 멈춤
1. backend가 제출은 받았나: backend 로그 `app.access`에서 `POST /api/v1/runs` 확인.
2. worker가 집었나: §2 "engine-worker 로그는 위 방식으로 못 본다" 절차로 실행 중인 worker pod를 찾아 확인
   — `deploy/enterprise-engine-worker`가 아니라 개별 job pod다.
3. **`np run`이 PENDING에서 안 넘어가면 MQ 토폴로지 누락도 의심할 것.** 배포(코드)와 MQ 큐/바인딩
   프로비저닝은 별개 작업이라, 필요한 큐가 없으면 backend consume이 60초 주기로 crash loop에
   빠지고 증상은 "run이 pending에서 멈춤"으로만 보인다. 큐 상태 확인·프로비저닝은 `mq-status`
   스킬을 쓴다.
4. 진행상태 push(MQTT)만 문제면 mosquitto pod 확인.

### C. 5xx / 타임아웃
1. `curl -sI https://api.<env>.netspresso.ai/` → istio-envoy 응답 자체가 오는지 (안 오면 VPN/DNS).
2. backend 로그에서 해당 `x-request-id` 또는 path grep.
3. backend→engine 구간이면 `np-engine API call failed after 3 retries` / `FRS_007` 검색.
4. DB면: RDS `np-<env>-pg...`. **exec가 viewer role에서 Forbidden이므로 backend pod 안에서
   직접 조회는 exec 권한이 있는 사람에게 요청해야 한다** — 참고 경로는 §2 "DB 직접 조회" 참고.

### D. 모델/데이터셋 카탈로그 문제 (`np models` / `np datasets` 결과 이상)
- backend는 `https://api-npcat.dev.nota.ai` (NP_CATALOG_*)에서 동기화 (env 무관하게 항상 dev 카탈로그).
  backend 로그에서 `catalog` grep.
- preset 재적재가 있었으면 ref_id가 통째로 바뀔 수 있음 → 기존 project가 유령 ref를 물고 있는지 §4로 대조.

### E. "머지했는데 그대로임"
- §3 절차. 요약: pod sha 확인 → 머지커밋 포함 여부 → GitOps values → ArgoCD.
- EKS가 최신인데도 재현되면 **배포 문제가 아니라 경로상 다른 버그**.

### F. engine-worker가 느리거나 타임아웃 남 (성능 의심)
- worker pod는 dev·stg 모두 실측 **60코어/200Gi** 할당(2026-08 확인, req=lim 고정). "리소스가
  부족해서 느리다"고 바로 단정하지 말 것 — 과거 사례로 단일스레드 압축 처리가 병목이었는데
  리소스 부족으로 오진한 적이 있다. 먼저 `kubectl top pod`로 실제 CPU 사용률을 확인해
  할당량 대비 얼마나 쓰고 있는지(수 코어만 쓰고 나머지는 노는지) 보고 나서 원인을 좁힌다.

---

## 7. 3090i 스택 (np-e2e, 별도 환경 — EKS와 무관)

EKS dev/stg와 별개인 on-prem compose 스택. `--env` 인자와 무관하게 항상 동일한 대상.

```bash
ssh -i ~/.ssh/id_rsa_3090i_wonseon.song -p 2222 wonseon.song@10.169.20.121

docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
#  np-e2e-backend     notadockerhub/enterprise-backend:latest-dev      :18002->8000
#  np-e2e-engine-api  notadockerhub/enterprise-engine-api:latest-dev   :18010->8000
#  np-e2e-worker      notadockerhub/enterprise-engine-worker:latest-dev
#  enterprise-backend(-auth)  latest-staging  :8000/:8110   ← staging, 건드리지 말 것

docker logs np-e2e-backend --since 30m | tail -50
docker inspect np-e2e-engine-api --format '{{.Image}}' | xargs docker inspect --format '{{.Created}}'   # 이미지 빌드 시각
```

- `latest-dev` 이미지는 **`⭐️CI/CD [Engine] 통합` / `CI/CD [Server]` 수동 dispatch 시에만** 갱신.
  머지만으로는 절대 안 바뀜. 재기동 전 worker가 job 실행 중인지 로그로 확인할 것.
- GH Actions self-hosted runner(`3090i`)이기도 함.

---

## 8. 인프라 치트시트

| 항목 | dev | stg |
|---|---|---|
| EKS | `np-dev-eks` (ap-northeast-2, account 093529868216) | `np-stg-eks` (ap-northeast-2, account 093529868216) |
| kubectl context | `eks-dev` | `eks-stg` |
| DB | `np-dev-pg.ch6ys2gqcenx.ap-northeast-2.rds.amazonaws.com:5432` db=netspresso | ⚠️ 확인 필요 — `kubectl -n netspresso get deploy enterprise-backend -o yaml \| grep -i DATABASE` |
| S3 | `np-dev-platform-arm-093529868216` | ⚠️ 확인 필요 — 동일 방법으로 backend env에서 `MINIO_*`/`S3_*` grep |
| ingress | istio, 10.13.18.16 — api/app/model-explorer/auth `.dev.netspresso.ai` | ⚠️ 확인 필요 — `.stg.netspresso.ai` 패턴 추정, ingress IP는 다를 수 있음 |
| ArgoCD | https://argocd.dev.netspresso.ai (apps: `2x-netspresso-*`) | ⚠️ 확인 필요 |
| Loki(Grafana) datasource uid | `P8E80F9AEF21F6940` (실측 확인, env가 바뀌어도 동일했음 — 최초 사용 시 재확인 권장) | 〃 |

공통 (env 무관):

| 항목 | 값 |
|---|---|
| ECR | `093529868216.dkr.ecr.ap-northeast-2.amazonaws.com/netspresso-v2/<svc>:sha-<8>` |
| GitOps repo | `nota-github/np-k8s-platform` → `envs/<env>-aws/values.yaml` |
| MQ | Amazon MQ RabbitMQ :5671 TLS, exchange `np.events` (큐 상세는 `mq-status` 스킬) |
| catalog | `https://api-npcat.dev.nota.ai` (user internal@nota.ai, env 무관 항상 dev) |
| 3090i | `wonseon.song@10.169.20.121 -p 2222`, 키 `~/.ssh/id_rsa_3090i_wonseon.song` (§7, EKS와 무관) |
| CLI 토큰 | `~/.config/np/credentials.json` / ref 매핑 `~/.config/np/refs.json` |
| kubectl role | `np-developer-eks-viewer` (IAM 유저 직접 접근 불가, `--role-arn` 필수 — `~/.kube/configs/README.md` 참고). **읽기 전용**이라 `port-forward`/`exec` Forbidden, 로그는 Grafana Loki proxy로 (§2) |

⚠️ **stg 값을 확인하면 이 표의 해당 행을 직접 업데이트할 것** — "확인 필요" 상태로 방치하지 않는다.
