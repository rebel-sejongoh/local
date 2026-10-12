# codesigner CI 구조와 LLVM/MLIR 기반 compiler를 CI에 올리는 방법 (정리)

_2026-10-07 기준. 세션 대화 정리, 확인한 사실과 제안을 구분해 적음._
_2026-10-11: §4.5 LLVM/MLIR prebuilt 빌드 절차(시험 빌드 완료, 새 버전으로 다시 돌리는 방법) 추가._

## 1. CI가 무엇을 어떻게 돌리는가

| 층 | 파일 | 내용 |
|---|---|---|
| workflow | `.github/workflows/ci-pr.yml`, `ci-nightly.yml`, `ci-hardware.yml` | job 목록, runner, 컨테이너 이미지, 변경 경로별 lane 선택(`changes` job) |
| 빌드 공유 | `.github/workflows/_build.yml` | 무거운 의존성(gem5, PrecSim)을 run당 한 번 준비해 artifact로 공유 |
| 환경 준비 | `.github/scripts/ci-setup.sh` | job마다 실행. env flag(`MOON`, `AARCH64`, `FULL`, `CONAN` …)로 설치 대상 선택. moon 버전 고정(`MOON_VERSION=2.5.4`) |
| lane 실체 | `Makefile`의 `ci-*` target / `CI_PR_LANES_*`, 각 project `moon.yml` | CI와 `make test`가 같은 target을 호출 |
| 보조 script | `RepoInfra/ci/` (`fetch_artifact.sh`, `fetch_overlay.sh`, `build_info.sh`) | 미리 빌드된 산출물 받기와 검증 |
| 문서 | `docs/github-workflow.md`, `docs/local-dev-workflow.md`, `docs/testing/lanes.md`, `docs/testing/change-selection.md` | |

바로 확인하는 명령:
```bash
grep -n "^CI_PR_LANES" Makefile    # PR lane 목록
make -n ci-mcc                     # lane이 실행하는 명령
moon query tasks --id mcc          # project task
make ci-mirror-check               # workflow ↔ Makefile 일치 검사
```

### runner와 이미지 (확인한 사실)
- runner: `CODESIGNER_RUNNER = fast-3-c12m192` (uDC Kubernetes, org 공용 self-hosted).
- 실행 방식: `k8s-novolume` container hook. job마다 pod가 생성되고 사라짐 → 상시 접속할 머신 없음.
  - local composite action(`uses: ./...`)이 안 돼서 `run: bash .github/scripts/ci-setup.sh` 방식을 씀.
  - workflow `volumes:`로 host path를 mount할 수 없음(runner pod에 없는 경로는 ENOENT).
- 이미지: `ghcr.io/rebellions-sw/rbln-build:0.10.5-dev7-g52cdcec6b-ubuntu22.04-py3.10`
  - repo 밖에서 빌드됨(`docs/github-workflow.md` §5). org 공용(ccost, lmcache-rbln 등도 사용).
  - 빌드하는 repo/담당자는 확인 못 함. `gh auth refresh -s read:packages` 후
    `gh api orgs/rebellions-sw/packages/container/rbln-build`로 연결된 repo 확인 가능.
  - 이미지에 `gh` CLI 없음(release-wheels.yml 주석).
- CI는 `/tools`, `/mnt/shared_data`(NFS) 를 볼 수 없음 → `config.mk`의 `LLVM_DIR=/tools/...`는 로컬 전용.

### CI runner에 들어가 보는 방법
| 방법 | 확인 가능한 것 | 필요한 것 |
|---|---|---|
| CI 이미지를 로컬 docker로 실행 | 소프트웨어 환경(패키지, 컴파일러) | docker, `read:packages` scope |
| 조사용 job 실행 | 실제 runner의 mount, 네트워크, 리소스 | 임시 브랜치 workflow에 `ls /mnt`, `df`, `free` 등 |
| tmate류 대화형 action | job 안 shell | org 보안 정책 확인, `k8s-novolume`에서 동작 미검증 |
| infra 담당자에게 요청 | `kubectl exec`로 pod 접속 | infra 권한 |

## 2. CI에서 VP 돌리기 (issue #1530)

- VP 바이너리: `/mnt/shared_data/airflow/rebel_compute_lib2/vp/` (EVT1: `260521_vp_rebel_evt1_arbcal`).
  로컬 복사본: `spec_source_inventory/rebel_compute_lib2/vp/`.
- 필요 라이브러리: `libsystemc.so.2.3`(rcl2 `docker/`), 필요시 GCC12 `libstdc++`.
- **지금 CI는 불가.** fast-3가 원래는 VAST의 `/mnt/shared_data`를 mount했으나, 2026-10-06 VAST 장애로
  CephFS로 전환됨(udc-k8s#11193). 되돌리는 것은 작은 설정 변경.
- 장기안: Artifactory에 고정 복사본 + sha256 검증. HW팀의 복사 허용 여부 확인 필요.
- **이름이 같아도 빌드가 바뀔 수 있음** → sha256 기록 필수.
  2026-10-07 EVT1 sha256: `c0b7580bb8f5f0a0314013e7bb345410b7a690ea07daab1ae41b73ff05065dcb`
  (로컬 복사본도 동일, add 비교 652 대 284 cycle은 이 빌드로 측정).

## 3. 큰 외부 의존성을 다루는 repo의 선례

| 방식 | 선례 | 특징 |
|---|---|---|
| A. 고정 release를 받아 오기 | gem5: `config.mk`의 `GEM5_SDK_RELEASE ?= gem5-rbln-sdk-v10`, `rebellions-sw/gem5-rbln` Release, `fetch_overlay.sh`, `BUILD_INFO`(recipe_sha256) 검증 | release asset은 만료 없음, 버전을 한 줄로 고정 |
| B. run마다 한 번 빌드해 공유 | PrecSim: `_build.yml` + `fetch_artifact.sh` cross-run cache | cache miss 때 오래 걸림 |
| C. CI 이미지에 넣기 | #597 option B(apt 패키지) | 이미지가 repo 밖이라 변경이 느림 |

### GitHub Release란
- repo 페이지의 배포판 기능: tag + 설명 + 첨부 파일(asset). asset 하나 2GB 이하.
- codesigner: https://github.com/rebellions-sw/codesigner/releases
  (`v0.0.2` Latest, `codesigner-0.0.2.zip` 107MB / `v0.0.1`)
  - `release-wheels.yml`이 `v*` tag에서 배포 wheel들(gts, r100, r200, simulator, verification …)을
    `dist/codesigner-<ver>.zip`으로 묶고, 빈 venv에서 검증한 뒤 `actions/github-script`로 Release에 첨부.
- gem5-rbln: `gem5-rbln-sdk-v10`(Latest), v9 이하는 Pre-release.

## 4. LLVM/MLIR 위에 compiler를 만든다면

### 4.1 배포 패키지로 시작 (가장 빠름)
- Ubuntu 22.04 기본 저장소: `libmlir-13/14/15-dev`만 있음(최신 15.0.7) → 너무 오래됨.
- **apt.llvm.org**: `libmlir-<N>-dev`, `mlir-<N>-tools` (jammy용, 최신 major 몇 개).
  ```bash
  wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc
  echo "deb http://apt.llvm.org/jammy/ llvm-toolchain-jammy-19 main" | sudo tee /etc/apt/sources.list.d/llvm-19.list
  sudo apt update && sudo apt install -y libmlir-19-dev mlir-19-tools
  cmake -DMLIR_DIR=/usr/lib/llvm-19/lib/cmake/mlir -DLLVM_DIR=/usr/lib/llvm-19/lib/cmake/llvm ...
  ```
  - CI: `ci-setup.sh`에 저장소 추가 + `apt_ensure`.
  - 한계: major만 고정(point release는 바뀜 → 버전 log 기록), job마다 다운로드(#597 mirror 문제),
    빌드 옵션 선택 불가(assertion off, shared lib).
- conda-forge `mlir`: 버전 정확히 고정 가능하지만 repo가 uv 기반.
- LLVM GitHub release 바이너리에는 보통 MLIR 없음.

### 4.2 직접 빌드해서 Release로 올리기 (버전·옵션 고정이 필요할 때)
구성:
```
config.mk                        LLVM_REF / LLVM_RELEASE 고정
RepoInfra/ci/build_llvm.sh       빌드 방법 (hash가 release 이름에 들어감)
.github/workflows/build-llvm.yml 빌드 → Release (가끔 실행)
RepoInfra/ci/fetch_llvm.sh       받기 + sha256/BUILD_INFO 검증
Makefile  dep-llvm / ci-<compiler>
```
`build-llvm.yml` 골격:
```yaml
on:
  workflow_dispatch:
  push: { branches: [dev], paths: [config.mk, RepoInfra/ci/build_llvm.sh] }
jobs:
  build:
    runs-on: ${{ vars.CODESIGNER_RUNNER }}
    timeout-minutes: 240
    container:   # CI 이미지와 같은 OS/glibc로 빌드
      image: ${{ vars.CODESIGNER_IMAGE_NAME }}:${{ vars.CODESIGNER_IMAGE_TAG }}-py3.10
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@v6
      - run: bash RepoInfra/ci/build_llvm.sh out/      # 같은 tag Release가 있으면 skip
      - uses: actions/github-script@v7                 # 이미지에 gh 없음 → REST API로 Release 생성
```
- release 이름: `llvm-<ref>-<build_llvm.sh hash>`, prerelease로 표시해 배포판과 구분.
- 쓰는 쪽: `dep-llvm`이 받아 검증. CI에서는 소스 빌드 fallback 없이 FAIL(안내 메시지).
- repo 규칙: `build-llvm` job을 `check-ci-mirror`의 `INFRA_JOBS`에 등록,
  `docs/github-workflow.md` 표와(lane이면) `docs/testing/lanes.md`에 반영.
- 대안 저장소: Artifactory(CI에 인증 정보 있음).

### 4.3 개발 VM에서 빌드해 직접 올리기
- 권한 확인됨: codesigner admin/push, gem5-rbln WRITE. 개발 VM = Ubuntu 22.04.5, gcc 12, glibc 2.35.
  ```bash
  tar -C install -I 'zstd -19 -T0' -cf llvm-19.1.7-mlir.tar.zst .
  sha256sum llvm-19.1.7-mlir.tar.zst > SHA256SUMS
  gh release create llvm-19.1.7-mlir-v1 llvm-19.1.7-mlir.tar.zst SHA256SUMS BUILD_INFO \
    -R rebellions-sw/codesigner --prerelease --title "LLVM 19.1.7 + MLIR (CI dependency)" --notes "..."
  ```
- 주의:
  - `/tools/.../GCC-12.1.0`의 libstdc++에 링크하면 CI에서 실행 불가 → 시스템 compiler 사용,
    `ldd`로 `/tools`·`/mnt` 참조 없는지 확인. 가장 확실한 것은 CI 이미지 컨테이너에서 빌드.
  - `BUILD_INFO`(LLVM commit, cmake 인자, compiler 버전, 빌드 머신) 첨부 + 빌드 script commit.
  - tag 덮어쓰기 금지, 다시 빌드하면 `-v2`.
  - codesigner Release에 의존성을 둘지는 팀 합의(gem5는 별도 repo 사용).
- 안정되면 같은 script를 `build-llvm.yml`로 옮겨 재현성 확보.

### 4.4 gcc 대신 clang으로 빌드
- 현재 repo CI는 clang 미사용(`config.mk`: `SIM_CC=gcc`, `SIM_CXX=g++`, `SOC_CC=aarch64-linux-gnu-gcc`).
  CI 이미지에 clang이 있는지는 미확인.
- 준비: apt.llvm.org `clang-19 lld-19`를 `ci-setup.sh` flag(예: `CLANG=true`)로 설치.
  또는 직접 빌드하는 LLVM Release에 `clang;lld`를 포함(첫 빌드만 다른 compiler 필요).
  ```bash
  cmake -G Ninja -S llvm-project/llvm -B build \
    -DCMAKE_C_COMPILER=clang-19 -DCMAKE_CXX_COMPILER=clang++-19 -DLLVM_USE_LINKER=lld \
    -DLLVM_ENABLE_PROJECTS=mlir -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_PARALLEL_LINK_JOBS=2 -DLLVM_CCACHE_BUILD=ON
  ```
- 표준 라이브러리는 시스템 libstdc++ 유지(libc++로 바꾸면 gcc로 빌드된 코드와 맞추기 어려움).
- `clang --version`을 log/`BUILD_INFO`에 남김.

### 4.5 LLVM/MLIR prebuilt 빌드 절차 (2026-10-11 시험 빌드)

**결정한 것**
- 버전: 최신 upstream release tag (`llvmorg-23.1.3`, commit `0d261d1c`). 버전당 한 번 빌드해 올리고, 다음 버전으로 바꿀 때까지 계속 씀.
- 저장 위치: **GitHub Release** (codesigner, prerelease, tag `llvm-...`).
  - asset은 만료 없음 (90일 제한은 Actions artifact). asset 하나 2GB 이하.
  - CI와 개발 VM이 같은 흐름: `gh release download` → sha256 확인 → 압축 해제. 인증은 CI는 `GH_TOKEN: ${{ github.token }}`,
    개발 VM은 `gh auth login` 한 번. S3 key를 env에 둘 필요 없음.
  - 올리는 쪽은 독립 workflow `build-llvm.yml`(수동 실행, `permissions: contents: write`, `GITHUB_TOKEN`).
    gh는 `apt_ensure_gh`로 설치. 같은 tag가 있으면 skip.
  - S3(VP가 있는 `s3://codesign`)는 key 배포가 필요해서 제외. precsim처럼 CI cache로 두는 방식은 만료(45/90일)돼서 제외.
- Python DSL로 갈 거라 Python bindings ON. custom dialect binding은 downstream이 install의 `src/python`으로 자기 package를 빌드.
- mcc 등 repo 전체가 Python 3.10 고정(`.python-version`, CI 이미지 `-py3.10`). extension은 downstream이 자기 Python으로 빌드하므로
  prebuilt가 3.10에 강하게 묶이지는 않음(다른 버전으로는 아직 미확인).

**빌드 옵션과 이유**

| 옵션 | 값 | 이유 |
|---|---|---|
| `CMAKE_BUILD_TYPE` | Release | 크기·속도. RelWithDebInfo는 크기가 몇 배 |
| library | static (기본) | 컴파일러 바이너리가 혼자 돎 |
| `LLVM_ENABLE_PROJECTS` | mlir | clang/lld 제외 |
| `LLVM_TARGETS_TO_BUILD` | X86 | NPU backend는 직접 작성, host용만 |
| `LLVM_ENABLE_ASSERTIONS` | ON | MLIR 개발에 verifier/assert 필요. ABI에 영향 → downstream도 같은 값 |
| RTTI / EH | OFF (기본) | downstream도 `-fno-rtti` |
| `LLVM_INSTALL_UTILS` | ON | lit용 `FileCheck`, `not`, `count`, `split-file` |
| `LLVM_BUILD_TOOLS` | **OFF** | `llvm-*`, `mlir-opt` 등 tool 제외 (bin 1.9GB → 37MB). install 후 파일만 지우면 cmake export가 없는 파일을 가리켜 `find_package` 실패 |
| `MLIR_ENABLE_BINDINGS_PYTHON` | ON | Python DSL용 |
| zlib/zstd/libxml2/terminfo/libedit/libpfm | OFF | 외부 `-dev` 의존 제거 |
| tests/benchmarks/examples/docs | OFF | 빌드 시간 |
| `LLVM_PARALLEL_LINK_JOBS` | 4 | 링크 메모리 |
| install 후 `python_packages/` 삭제 | | cp310용 prebuilt `mlir` package(223MB). downstream은 쓰지 않음. export에서 참조 안 함 |

**시험 빌드에서 막힌 것 (script에 반영됨)**
1. 시스템 python3.10에 header 없음(`python3.10-dev` 미설치) → `uv venv --managed-python -p 3.10`.
2. MLIR cmake가 `Python3`와 `Python`(nanobind용)을 따로 찾음 → `Python3_EXECUTABLE`, `Python_EXECUTABLE` 둘 다 지정.
3. `LLVM_USE_LINKER=gold` → nanobind의 `-z undefs`를 gold가 모름 → 기본 linker(bfd) 사용. 빌드 시간 문제없음.
4. cmake 3.22에서 경고: LLVM 24부터 cmake ≥ 3.31 필요. 다음 버전 올릴 때 CI 이미지 cmake 확인.

**결과** (개발 VM: 14 core, 125GB RAM, Ubuntu 22.04, gcc 12.3)

| | 값 |
|---|---|
| configure + build | 약 14분 (851s, 5,127 step) |
| install + zstd -19 | 약 30초 |
| install 크기 | 1.1GB (lib 857M, include 167M, bin 37M, src 13M) |
| `llvm-mlir.tar.zst` | 130MB |
| 런타임 의존 | 시스템 libc/libstdc++만 (GLIBC 2.34, GLIBCXX 3.4.30 → Ubuntu 22.04 OK) |

**검증** (`verify.sh`: upstream `mlir/examples/standalone`을 install에 대고 빌드)
- standalone(custom dialect + C API + nanobind extension) 빌드 성공.
- lit 7개 중 4개 통과. 실패 3개는 예상된 것: plugin test 2개는 upstream `mlir-opt` 필요(뺐음),
  `smoketest.py` 마지막 부분은 upstream `mlir` package import(뺐음). custom dialect 부분은 통과.
- Python에서 `.td`로 생성된 builder로 custom op 생성 + verify 통과:
  ```
  %0 = arith.addi %c2_i32, %c2_i32 : i32
  %1 = standalone.foo %0 : i32          ← standalone.foo(...) builder
  !standalone.custom<"bar">             ← CustomType.get()
  ```
- downstream 주의:
  - `MLIR_INCLUDE_TESTS`는 install 값(OFF)을 물려받음 → downstream에서 `-DMLIR_INCLUDE_TESTS=ON`.
  - 쓰는 upstream dialect는 `python/CMakeLists.txt`의 source 목록 두 곳과 C++ `register_dialects`에 추가.
  - upstream 예제 `register_dialects(load=True)`는 standalone을 load하지 않는 버그 → `ctx.load_all_available_dialects()`로 우회.

**새 버전으로 다시 돌리기**
```bash
# 0. 최신 release tag 확인
git ls-remote --tags --refs https://github.com/llvm/llvm-project.git 'llvmorg-*' \
  | sed 's|.*refs/tags/||' | grep -v rc | sort -V | tail -3

# 1. 새 버전의 Python 요구 버전 확인 → build.sh의 uv pip install 줄과 맞춤
curl -s https://raw.githubusercontent.com/llvm/llvm-project/<REF>/mlir/python/requirements.txt

# 2. 빌드 (background, 약 15분) → ~/llvm-build/out/<REF>/{llvm-mlir.tar.zst,SHA256SUMS,BUILD_INFO}
cd ~/llvm-build && ./build.sh <REF> > build-<REF>.log 2>&1 &

# 3. 검증 (standalone 빌드 + lit + Python builder)
./verify.sh <REF> 2>&1 | tee verify-<REF>.log
```
- 디렉터리: `~/llvm-build/{src,build,install,out,verify}/<REF>`, 공용 `venv/`(uv-managed 3.10, nanobind·lit 등).
  위치는 `LLVM_BUILD_ROOT`로 바꿀 수 있음.
- 확인할 것: `build_seconds`(BUILD_INFO), tarball 크기(2GB 이하), `verify.sh`에서 실패가 위 3개뿐인지,
  `ldd`에 `/tools`·`/mnt` 참조 없는지. 옵션이나 예제가 바뀌어 새로 깨지는 것은 위 "막힌 것" 목록에 추가.
- 이 script들은 아직 repo 밖(`~/llvm-build/`). repo로 옮길 때 `RepoInfra/ci/build_llvm.sh` + `build-llvm.yml`(CI 이미지 컨테이너에서 빌드)로.

<details><summary><code>~/llvm-build/build.sh</code></summary>

```bash
#!/usr/bin/env bash
# build.sh [REF] — build LLVM + MLIR (static, assertions, Python bindings) and pack the install.
#   REF: an llvm-project tag, e.g. llvmorg-23.1.3 (default below)
# Output: $W/out/$REF/{llvm-mlir.tar.zst,SHA256SUMS,BUILD_INFO}
set -euo pipefail
REF="${1:-llvmorg-23.1.3}"
W="${LLVM_BUILD_ROOT:-$HOME/llvm-build}"
SRC=$W/src/$REF BLD=$W/build/$REF INST=$W/install/$REF OUT=$W/out/$REF
mkdir -p "$W/src" "$W/build" "$W/install" "$OUT"
cd "$W"
log() { echo "[$(date '+%F %T')] $*"; }
t0=$(date +%s)

log "venv"   # uv-managed Python: the system python3.10 has no headers (python3.10-dev)
[ -d venv ] || uv venv -q --managed-python -p 3.10 venv
# Pins from mlir/python/requirements.txt of the LLVM version being built; check them on a version bump.
uv pip install -q -p venv/bin/python 'nanobind>=2.9,<3.0' 'PyYAML>=5.4.0,<=6.0.3' 'typing_extensions>=4.12.2' \
  'numpy>=2.1.0,<=2.1.2' 'ml_dtypes>=0.5.0,<=0.6.0' lit
PY=$W/venv/bin/python

log "source $REF"
[ -d "$SRC" ] || git clone -q --depth 1 --branch "$REF" https://github.com/llvm/llvm-project.git "$SRC"
t1=$(date +%s)

log "configure"
CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_ENABLE_PROJECTS=mlir
  -DLLVM_TARGETS_TO_BUILD=X86
  -DLLVM_ENABLE_ASSERTIONS=ON
  -DLLVM_INSTALL_UTILS=ON          # FileCheck, not, count, split-file for lit
  -DLLVM_BUILD_TOOLS=OFF           # no llvm-*/mlir-* tools (removing them after install breaks the cmake exports)
  -DMLIR_ENABLE_BINDINGS_PYTHON=ON
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_PARALLEL_LINK_JOBS=4      # no LLVM_USE_LINKER=gold: gold rejects nanobind's `-z undefs`
)
cmake -G Ninja -S "$SRC/llvm" -B "$BLD" -DCMAKE_INSTALL_PREFIX="$INST" \
  -DPython3_EXECUTABLE="$PY" -DPython_EXECUTABLE="$PY" "${CMAKE_ARGS[@]}"

log "build"
ninja -C "$BLD"
t2=$(date +%s)

log "install"
rm -rf "$INST"
cmake --install "$BLD" --strip > /dev/null
rm -rf "$INST/python_packages"   # prebuilt cp310 package; downstream builds its own from src/python
t3=$(date +%s)

log "package"
cat > "$INST/BUILD_INFO" <<INFO
ref=$REF
commit=$(git -C "$SRC" rev-parse HEAD)
cmake_args=${CMAKE_ARGS[*]}
cxx=$(c++ --version | head -1)
python=$("$PY" --version)
os=$(. /etc/os-release && echo "$PRETTY_NAME"), glibc $(ldd --version | head -1 | awk '{print $NF}')
host=$(hostname), $(nproc) cores
build_seconds=$((t2-t1))
INFO
tar -C "$INST" -I 'zstd -19 -T0' -cf "$OUT/llvm-mlir.tar.zst" .
cp "$INST/BUILD_INFO" "$OUT/"
(cd "$OUT" && sha256sum llvm-mlir.tar.zst > SHA256SUMS)
t4=$(date +%s)

log "done"
echo "times(s): clone=$((t1-t0)) configure+build=$((t2-t1)) install=$((t3-t2)) package=$((t4-t3)) total=$((t4-t0))"
du -sh "$INST" "$INST/lib" "$INST/bin" "$INST/include"
ls -l "$OUT"
```
</details>

<details><summary><code>~/llvm-build/verify.sh</code></summary>

```bash
#!/usr/bin/env bash
# verify.sh [REF] — check an install from build.sh the way a downstream compiler uses it:
# build upstream's mlir/examples/standalone (custom dialect + C API + Python bindings) against it,
# run its lit tests, and build a custom op from Python.
set -euo pipefail
REF="${1:-llvmorg-23.1.3}"
W="${LLVM_BUILD_ROOT:-$HOME/llvm-build}"
SRC=$W/src/$REF INST=$W/install/$REF PY=$W/venv/bin/python
SA=$W/verify/$REF/src SB=$W/verify/$REF/build
rm -rf "$W/verify/$REF" && mkdir -p "$W/verify/$REF"

# The example's Python package holds only the builtin dialect; add func and arith (two lists).
cp -r "$SRC/mlir/examples/standalone" "$SA"
sed -i 's|^\( *\)MLIRPythonSources.Dialects.builtin$|&\n\1MLIRPythonSources.Dialects.func\n\1MLIRPythonSources.Dialects.arith|' \
  "$SA/python/CMakeLists.txt"

echo "== env check: tools needed for lit, cmake exports load"
ls "$INST/bin" | grep -xE 'FileCheck|not|count|split-file|mlir-tblgen'
env -u LD_LIBRARY_PATH ldd "$INST/bin/mlir-tblgen" | grep -E 'stdc|/tools|/mnt' || true

echo "== build standalone"
cmake -G Ninja -S "$SA" -B "$SB" -DCMAKE_BUILD_TYPE=Release -DMLIR_DIR="$INST/lib/cmake/mlir" \
  -DMLIR_INCLUDE_TESTS=ON -DLLVM_EXTERNAL_LIT="$W/venv/bin/lit" \
  -DMLIR_ENABLE_BINDINGS_PYTHON=ON -DPython3_EXECUTABLE="$PY" -DPython_EXECUTABLE="$PY" > "$SB.configure.log"
ninja -C "$SB" > "$SB.build.log"

echo "== lit (expected failures: the 2 plugin tests need upstream mlir-opt, and smoketest.py's last"
echo "   part imports upstream's 'mlir' package; neither is in the install)"
"$W/venv/bin/lit" -s "$SB/test" || true

echo "== Python: build a custom op with the generated builder"
PYTHONPATH="$SB/python_packages/standalone" "$PY" - <<'EOF'
from mlir_standalone.ir import Context, Location, Module, InsertionPoint, IntegerType
from mlir_standalone.dialects import arith
from mlir_standalone.dialects import standalone_nanobind as standalone
with Context() as ctx, Location.unknown():
    standalone.register_dialects()
    ctx.load_all_available_dialects()   # the example registers standalone but never loads it
    i32 = IntegerType.get_signless(32)
    m = Module.create()
    with InsertionPoint(m.body):
        c = arith.constant(i32, 2)
        standalone.foo(arith.addi(c, c))
    m.operation.verify()
    print(m)
    print(standalone.CustomType.get("bar"))
EOF
```
</details>

## 5. LLVM 빌드가 CI에서 실패할 때 디버깅

1. **같은 CI 이미지로 로컬 재현** (가장 효과적)
   ```bash
   gh auth refresh -h github.com -s read:packages
   gh auth token | docker login ghcr.io -u <user> --password-stdin
   docker run --rm -it -v $PWD:/w -w /w ghcr.io/rebellions-sw/rbln-build:<tag>-py3.10 bash
   ```
2. **실패 시 artifact 남기기**: `build.log`, `CMakeCache.txt`, `CMakeConfigureLog.yaml`, `.ninja_log`를
   `if: failure()` + `actions/upload-artifact`로. `ninja -k 0`, 빌드 전 `nproc`/`free -g`/`df -h`/버전 출력.
   `gh run rerun <id> --debug`.
3. **빠른 반복**: `workflow_dispatch` 입력(cmake 인자, target), 일부 target만 빌드, ccache.
4. **자주 나오는 원인**: 링크 OOM(exit 137 → `LLVM_PARALLEL_LINK_JOBS`, lld), timeout, 디스크 부족.
5. **정말 접속이 필요하면**: tmate류 action(정책 확인), 또는 실패 시 `sleep`으로 pod를 살려 두고
   infra 담당자가 `kubectl exec`.

## 6. 이번 세션에서 개발 VM에 설치한 것
- `gh` 2.102.0 (GitHub 공식 apt 저장소), `gcc-aarch64-linux-gnu` 11.4.0, `moon` 2.5.4(`~/.local/bin`).
- `make test`(`test-ci`)를 로컬에서 돌리려면 위 셋이 필요했음.
- 2026-10-11: uv-managed CPython 3.10.21(`~/.local/share/uv/python/`), LLVM 시험 빌드 작업 디렉터리 `~/llvm-build/`(§4.5).
