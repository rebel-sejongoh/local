# CI 실패를 CI container image에서 재현하기

CI에서 PrecSim build, gem5, LLVM build나 lane setup이 깨졌을 때, CI와 같은 image를 받아서
그 job의 YAML step을 순서대로 다시 실행하는 방법을 정리한 문서.
(이 VM에서 실제로 돌려 본 절차는 아니다. workflow 파일을 읽고 정리했다.)

## 0. 실패한 job에서 확인할 것

| 항목 | 어디서 |
|---|---|
| workflow 파일과 job 이름 | 실패한 run 페이지. 예: `_build.yml`의 `precsim`, `ci-pr.yml`의 `ci-r100-gts-value` |
| commit sha, run id | run URL |
| image tag | job log의 "Initialize containers" step. 예: `ghcr.io/rebellions-sw/rbln-build:0.10.5-dev7-g52cdcec6b-ubuntu22.04-py3.10` |
| env 플래그 | 그 job의 "provision" step `env:` (`MOON`, `AARCH64`, `FULL`, `CONAN`) |

image tag는 `vars.CODESIGNER_IMAGE_TAG`에서 오는데, 이 변수는 권한이 없으면 안 보인다. job log에서 읽는 게 확실하다.

## 1. Image 받아서 띄우기

```bash
sudo apt install docker.io                       # VM에 아직 없음
gh auth refresh -s read:packages                 # ghcr pull 권한
gh auth token | docker login ghcr.io -u <github-id> --password-stdin
docker pull ghcr.io/rebellions-sw/rbln-build:<tag>-py3.10

# runner fast-3-c12m192 (CPU 12개, 메모리 192GB)에 맞춤
docker run --rm -it --cpus 12 --memory 192g \
  -e GH_TOKEN=$(gh auth token) \
  ghcr.io/rebellions-sw/rbln-build:<tag>-py3.10 bash
```

container 안에서는 작업 트리를 mount하지 말고 새로 clone한다.
CI가 매번 깨끗한 checkout(`submodules: false`, `fetch-depth: 1`)에서 시작하기 때문이다.

```bash
# CI의 "git config" step과 같다
git config --global --add safe.directory '*'
git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "git@github.com:"
git clone https://github.com/rebellions-sw/codesigner && cd codesigner && git checkout <sha>
```

## 2a. Build job: PrecSim (`_build.yml`의 `precsim`)

```bash
source .github/scripts/apt.sh && apt_ensure zstd curl ca-certificates && apt_ensure_gh

# "Compute identity" step
export EXPECTED_SHA=$(git ls-tree HEAD third_party/rebel_prec_sim | awk '{print $3}')
export EXPECTED_IMAGE_HASH=$(printf '%s' "<tag>-py3.10" | sha256sum | cut -c1-12)

make dep-precsim DEP_BUILD=1    # cache된 wheel을 받거나, 없으면 source build
make precsim-wheel              # CI에서 fetch가 miss였던 경우에만
```

- fetch가 cache에 hit하면 build를 건너뛴다. CI log의 `fetched=`가 `false`였는지 먼저 본다.
- 로컬에서 hit해서 build 실패가 재현되지 않으면 Makefile의 `_precsim-source-build` target을 직접 부른다.
  이 target을 단독으로 불러도 잘 도는지는 확인하지 않았다.

## 2b. Build job: gem5 (`_build.yml`의 `gem5-vehicle`)

1. gem5 runtime lib과 zstd를 apt로 설치한다(설치 목록은 그 job의 step에서 그대로 가져온다).
2. `GH_TOKEN=<PAT> make gem5-fetch-overlay`: `rebellions-sw/gem5-rbln` release를 받는다.
3. `make gem5-devices`

## 2c. Lane job (setup이나 test가 깨진 경우)

```bash
# 앞의 build job이 올린 artifact를 ./_dl 에 받아 둔다
gh run download <run_id> -R rebellions-sw/codesigner -n rt-precsim -D _dl
gh run download <run_id> -R rebellions-sw/codesigner -n rt-gem5    -D _dl

# 그 job의 provision step env를 그대로 (job마다 다르다)
GIT_PAT=$GH_TOKEN AARCH64=true MOON=true bash .github/scripts/ci-setup.sh

make ci-<lane>                  # 또는 moon 연결 lane이면 moon run <project>:<task>
```

`ci-setup.sh`가 하는 일:

1. git config
2. `AARCH64`이면 aarch64 cross toolchain 설치
3. `MOON`이면 moon 설치
4. `./_dl/*.tar.zst` 압축 풀기
5. `CONAN`이면 Artifactory conan remote 설정
6. `FULL`이면 RebelOpRegistry `uv sync`

`CONAN`이나 `FULL`이 켜진 job이면 `ARTIFACTORY_USERNAME`/`ARTIFACTORY_PASSWORD`도 본인 것으로 넣어야 한다.

### lane 실행 명령 찾기

lane 하나 = CI job 하나이고, 같은 이름이 세 곳에 적혀 있다(`ci-mirror-check`가 세 곳이 일치하는지 검사한다).

| 위치 | 예: `ci-mcc` |
|---|---|
| `docs/testing/lanes.md` 표 (lane catalog SSOT) | lane이 맡는 범위, 언제 도는지(PR/nightly), 실행 환경 |
| `Makefile`의 lane 목록 (`CI_PR_LANES_*`) | `ci-mcc=moon:mcc:test` → `make` target 없이 moon task를 실행 |
| `.github/workflows/ci-pr.yml`의 job | `if:` 조건, container, `ci-setup.sh` env, 실행 step |

목록 entry가 `moon:<project>:<task>` 형식이면 `moon run <project>:<task>`로 돌린다.
아니면 `make ci-<lane>`으로 돌린다.

## 2d. LLVM build (가상 시나리오)

순서는 같다. image를 띄우고 clone한 다음 `build-llvm.yml`의 step을 차례로 실행한다:
apt로 clang/ninja를 설치하고 `RepoInfra/ci/build_llvm.sh`를 돌린다.
(자세한 내용은 `ci-and-llvm-mlir-notes.md`)

## 로컬과 CI가 달라서 재현되지 않을 수 있는 부분

- **사용자:** runner는 root로 돈다. image의 기본 사용자가 root가 아니면 `--user 0`을 붙인다.
- **secret:** CI의 `GIT_PAT` 대신 본인 token을 쓴다. 권한 때문에 난 실패는 결과가 다를 수 있다.
- **네트워크:** Artifactory나 GitHub Release 접근 여부가 CI와 다를 수 있다.
- **공유 storage:** CI는 `/mnt/shared_data`를 볼 수 없다(2026-10-06 VAST→CephFS 이후). 로컬에서 mount하면 CI와 달라진다.
- **artifact 재다운로드:** `ci-setup.sh`가 깨진 artifact를 다시 받으려면 `GITHUB_RUN_ID`와 `GITHUB_REPOSITORY`가 필요하다.
  처음부터 `_dl`에 직접 받아 두면 이 경로를 타지 않는다.
- **runner 자체:** k8s container hook(`k8s-novolume`)으로 도는 runner에는 들어가 볼 수 없다.
  디버깅은 이렇게 로컬 container에서 하거나, workflow에 진단 step을 넣고 다시 돌려서 한다.
