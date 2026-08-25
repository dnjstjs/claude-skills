---
name: engine-evaluate-debug
description: "Use when engine evaluate 결과에 NaN score, bundle 해석 오류, 시뮬레이터 비교 실패가 나타날 때. SNR NaN 추적, multi-component 번들 문제, presigned URL 다운로드 실패 디버깅에 사용."
marketplace: false
---

# Engine Evaluate Debug — 평가 파이프라인 디버깅 가이드

## Overview

engine evaluate 파이프라인에서 발생하는 문제를 체계적으로 추적하는 가이드.
평가 결과 이상(NaN score), 모델 아티팩트 확보 실패, 시뮬레이터 비교 오류를 다룬다.

## When to Use

- 평가 결과에 `"score": NaN` 이 기록될 때
- `FileSystemError: base model bundle has multiple .pt2 artifacts` 에러
- `PytorchStreamReader failed reading zip archive` 에러
- `ModelArtifactError` 로 평가가 실패할 때
- 시뮬레이터 비교에서 layer 수 불일치 또는 빈 출력

## 환경 접근

```bash
# EKS 클러스터
kubectl config use-context arn:aws:eks:ap-northeast-2:093529868216:cluster/np-dev-eks

# 워커 파드 찾기
kubectl get pods -n netspresso | grep engine-worker

# 워커 로그 (컨테이너 이름 주의: enterprise-engine-worker)
kubectl logs <pod> -n netspresso -c enterprise-engine-worker --since=1h | grep -v FutureWarning | grep -v UserWarning

# DB 직접 조회 (psycopg2)
python3 -c "
import psycopg2
conn = psycopg2.connect(
    host='np-dev-pg.ch6ys2gqcenx.ap-northeast-2.rds.amazonaws.com',
    port=5432, dbname='netspresso', user='netspresso_app',
    password='ouZrdf3GTr4kMACzQ3ZVzHTXBANPwBvY'
)
cur = conn.cursor()
cur.execute('SELECT ...')
print(cur.fetchall())
conn.close()
"
```

## 1. SNR NaN 디버깅

### 근본 원인 패턴

SNR = `10 * log10(signal^2 / noise^2)`. NaN이 되는 경우:

| 원인 | 발생 조건 | 확인 방법 |
|------|----------|----------|
| 출력 텐서 자체가 NaN/inf | 양자화 + GO 모델에 랜덤 입력 | 로그에서 `SNR` 또는 `score` 검색 |
| signal=0, noise=0 | 두 모델 출력이 동일하게 0 | 비교 대상 layer 이름 확인 |
| 빈 텐서 비교 | layer 추출 실패로 빈 결과 | layer count 로그 확인 |

**가장 흔한 케이스**: LLM decode 컴포넌트에서 발생.
decode는 KV cache를 입력으로 받는데, 시뮬레이터가 **랜덤 데이터**로 채움.
AWQ INT4 양자화 + Graph Optimization 모델에 랜덤 KV cache → logit이 NaN/inf →
NaN 텐서끼리 SNR 계산 → NaN.

### NaN 전파 경로

```
시뮬레이터 (랜덤 KV cache 입력)
  → 양자화+GO decode 모델 실행
  → 출력 logit에 NaN/inf 발생
  → SNR 계산: 10 * log10(NaN) = NaN
  → np_evaluator_adapter.py:2119  float(r.score)  # NaN 그대로 보존
  → np_evaluator_adapter.py:2204  _to_transport_metric_value()
     isinstance(NaN, float) == True  # 필터링 안 됨
  → summary.json: {"layers": [{"layer_name": "linear_150", "score": NaN}]}
```

### 확인 순서

```bash
# 1. 워커 로그에서 해당 실험 찾기
kubectl logs <pod> -n netspresso -c enterprise-engine-worker \
  | grep -v FutureWarning | grep -v UserWarning \
  | grep "<experiment-id>"

# 2. 시뮬레이터 비교 로그 확인 (8개 비교 패턴)
# LLM 모델은 prefill + decode 컴포넌트별로 각각 비교
# (prefill + decode) x (INPUT vs INPUT, INPUT vs AQ, INPUT vs GO, INPUT vs OUTPUT)

# 3. 각 비교에서 추출된 layer 수 확인
# 정상: decode = 1 output layer, prefill = 93 output layers (모델에 따라 다름)
# 비정상: decode에서 93개 추출 → PR #322 이전 버그

# 4. NaN이 발생한 비교 쌍 특정
# 예: INPUT_MODEL vs GRAPH_OPTIMIZE, decode 비교
#     Model1=linear_210 (base), Model2=linear_150 (GO)
```

### Multi-Component LLM 비교 패턴

LLM 평가 시 8개 비교가 실행된다:

```
비교 대상 (4쌍):
  INPUT_MODEL vs INPUT_MODEL   (기준선)
  INPUT_MODEL vs AUTO_QUANT    (양자화 효과)
  INPUT_MODEL vs GRAPH_OPTIMIZE (GO 효과)       ← NaN 빈발
  INPUT_MODEL vs OUTPUT_MODEL  (최종)

컴포넌트 (2개):
  prefill  — 많은 output layer (예: 93개)
  decode   — 적은 output layer (예: 1개)

총 8개 = 4쌍 x 2컴포넌트
```

## 2. 모델 아티팩트 번들 오류

### `multiple .pt2 artifacts` 에러

**원인**: `sole_pt2_in()` (base_model_archive.py)이 번들 tar에서 .pt2를 하나만 기대하는데,
multi-component 번들(prefill.pt2 + decode.pt2)에서 2개 이상 발견.

**정상 해소 조건**: `artifact_index.json` 사이드카 파일이 번들 안에 있어야 함.

```
bundle.tar
  ├── artifact_index.json    ← 역할(prefill/decode) 매핑
  ├── smollm2_prefill.pt2
  └── smollm2_decode.pt2
```

**사이드카 검색 경로** (base_model_archive.py):
1. `path.parent` — .pt2와 같은 디렉터리
2. `extract_dir` — 추출 루트
3. `extract_dir / "exported"` — exported 하위

**확인 방법**:
```bash
# S3에서 번들 다운로드하여 내용 확인
aws s3 cp s3://bucket/raw/catalog/models/.../bundle.tar /tmp/
tar tf /tmp/bundle.tar  # artifact_index.json 존재 여부 확인
```

### `PytorchStreamReader failed reading zip archive` 에러

**원인**: tar 번들을 그대로 `model.pt2`로 이름만 바꿔 저장하면 발생.
`_resolve_artifact()`에서 `is_tar()` 판정 → `extract()` 호출이 필요한데,
이 과정이 누락되면 tar를 pt2로 읽으려다 실패.

### Standalone vs Inline Evaluate 차이

| 항목 | Inline (np run 내부) | Standalone (np evaluate) |
|------|---------------------|------------------------|
| 모델 확보 | `component_set_beside_pt2` | `sole_pt2_in` |
| 번들 해석 | `component_paths_for_artifacts()` | `extract()` → 단일 pt2 기대 |
| 실패 시 | 건너뛰기 가능 | `ModelArtifactError` throw |

## 3. 실험 추적 DB 쿼리

```sql
-- 실험 → 프로젝트 → 베이스 모델 추적
SELECT e.experiment_ref_id, e.project_ref_id, p.alias
FROM experiment e
JOIN project p ON e.project_ref_id = p.project_ref_id
WHERE e.experiment_ref_id = '<experiment-id>';

-- 프로젝트의 베이스 모델 S3 키
SELECT am.ai_model_ref_id, am.name, am.object_key
FROM project p
JOIN ai_model am ON p.project_ref_id = ... -- 프로젝트별 조인 구조 확인 필요
WHERE p.project_ref_id = '<project-id>';

-- 실험의 Job 체인 (step 순서)
SELECT j.job_ref_id, j.job_type, j.status, j.model_ref_id,
       am.object_key
FROM job j
LEFT JOIN ai_model am ON j.model_ref_id = am.ai_model_ref_id
WHERE j.experiment_ref_id = '<experiment-id>'
ORDER BY j.step;
```

## 4. 핵심 코드 위치

| 파일 | 역할 |
|------|------|
| `engine/src/np_engine/common/base_model_archive.py` | tar 판정, 추출, sole_pt2_in |
| `engine/src/np_engine/common/artifact_call_spec.py` | artifact_index.json 파싱, 컴포넌트 매핑 |
| `engine/src/np_engine/adapter/outbound/evaluate/http_model_artifact_adapter.py` | presigned URL 다운로드, 번들 resolve |
| `engine/src/np_engine/adapter/outbound/evaluate/np_evaluator_adapter.py:2204` | `_to_transport_metric_value` — NaN 통과 지점 |
| `engine/src/np_engine/application/evaluate/run/evaluate_run_service.py:416` | `_prepare_inputs()` — 모델 아티팩트 확보 |
| `np-evaluator: src/np_evaluator/simulator/native/model_loader.py` | output layer 추출 (PR #322 수정 대상) |

## Common Mistakes

| 실수 | 올바른 방법 |
|------|-----------|
| 컨테이너 이름을 `engine-worker`로 지정 | `enterprise-engine-worker` 사용 |
| 로그에서 FutureWarning에 묻힘 | `grep -v FutureWarning \| grep -v UserWarning` 필터 |
| NaN을 모델 결함으로 단정 | 시뮬레이터 랜덤 입력이 원인인지 먼저 확인 |
| DB에서 `experiment_ref_id`로 ai_model 직접 조회 | job 테이블을 거쳐 model_ref_id 추적 |
| standalone evaluate 실패를 번들 문제로 단정 | sole_pt2_in vs component_set_beside_pt2 경로 차이 확인 |
