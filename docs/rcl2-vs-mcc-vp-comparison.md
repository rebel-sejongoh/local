# rcl2 vs mcc primitive 성능 비교 — 목표와 현황

_2026-10-05 기준_

## 목표

- primitive마다 **rebel_compute_lib2(rcl2)** 가 만든 image와 **mcc** 가 만든 image를 각각 **VP**에서 돌린다.
- 두 결과의 정확도(golden 비교)와 사이클을 비교한다.
- 테스트 코드는 **codesigner의 mcc 쪽**에 둔다.
- rcl2에서는 다음 기능만 라이브러리처럼 가져다 쓴다.
  - binary(init) 생성
  - golden 생성
  - VP 입력 파일 생성
- 첫 대상 op은 **add**.

## 현재 상황

### codesigner 쪽
- CI 흐름: `.github/workflows/ci-*.yml` → `.github/scripts/ci-setup.sh` → `Makefile`의 `ci-*` 타깃 → `moon run ...`
- mcc와 primitives 관련 lane:
  - `ci-mcc`: mcc 단위 테스트
  - `ci-primitives-pytest`: primitives 단위 테스트
  - `ci-primitives-bytes`: sha256 바이트 golden 비교
  - `ci-primitives-precsim`: nightly, numpy ref와 PrecSim 결과 비교
- **rcl2와 결과를 직접 비교하는 테스트는 없다.**
  - rcl2(`spec_source_inventory/rebel_compute_lib2`, submodule)는 docstring에서 참고 자료로만 언급된다.
  - primitives의 `<op>_ref`는 rcl2 golden_models를 numpy로 다시 구현한 것이다.

### rcl2 테스트 구조
- 테스트 위치: `tests/src/develop/rebel/alpha/test_rbln_initgen_<op>.py`
  - REBEL alpha 181개, alpha_evt1 30개
- 실행 단계 (`tests/manager/test_runner.py`):
  1. **info**: `rbln_info_<op>` 호출 → 메모리 배치(`rbln_info`), 예상 사이클
  2. **initgen**: `rebel_args.json`을 만들고 `librebel_primitives.so`를 ctypes로 호출 → `init_0..15.txt`, `MRV_input.txt`
  3. **decoder**: init을 decode하고 오류 검사
  4. **golden**: `golden_models`가 입력 SHM 메모리맵과 golden 생성
  5. **backend**: `vp` / `prec_sim` / `fpga` / `device`
     - VP는 로그의 `DNC_0 Init ... N cycles`에서 사이클을 읽는다.
     - PrecSim은 사이클을 0으로 기록한다. 성능 비교는 VP로 해야 한다.
  6. **evaluator**: `SHM_final`과 golden 비교
- 단계별로 나눠 실행할 수 있다: `--only_compute_lib`, `--only_golden_models`, `--only_backend`, `--only_eval`

### op 기술 방식 (add 기준)
- 원본 정의는 C++ struct다 (`include/rebel_primitives.h`).
  - `RblnAddArgs_t : RblnArithmeticArgs_t : RblnOpArgs_t`
  - 필드: `input1`, `input2`, `output`, `act_type`, `tiling_info`, `ncluster`, `ndnc_per_cluster`, `primitive_config`(device, mode) 등
- Python `RblnAddArgs`는 C++ 헤더에서 **codegen으로 생성**된다 (`build/generated/python/rbln_primitives.py`). 빌드 전에는 import할 수 없다.
- 이름 규칙으로 연결되는 것:
  - initgen key `rbln_initgen_add` → `include/src/initgen_list/src/rebel_initgen_add.cc` → `rebel::alpha::RblnGateArithmetic`
  - golden은 `RblnAddArgs` → `golden_models/models/arithmetic.py:RebelAddGolden`
- `TensorInitgen`의 주요 필드: `dims`, `dtype`(기본 DLFP16), `src_address`/`dst_address`, `align_pad_*`, `value`(scalar), `scale`/`offset`(INT8), `tensor_format`
- **`dims`는 디바이스 메모리 layout의 shape이다** (`RblnDefault` = 마지막 축이 64원소 단위).
  - 모델의 원래 shape은 rcl2에 남지 않는다.
  - add는 원소별 연산이라 transpose 없이 `dims` 그대로 메모리에 놓인다. block 정렬 padding만 추가된다.

### 첫 대상 케이스
`test_rbln_initgen_add.py::rebel_alpha_ci_add_eltwise_NN_01` (`fast` 마크)
```python
RblnAddArgs(
    tiling_info=Tiling(tiling_order=[0,1,2,3], tiling_iter=[1,16,1,1],
                       tiling_cluster=[1,2,1,1], tiling_dnc=[1,8,1,1]),
    ncluster=2, ndnc_per_cluster=8,
    input1=TensorInitgen(dims=[1,16,2,64]),   # DLFP16
    input2=TensorInitgen(dims=[1,16,2,64]),
)
```
- 2 cluster × 8 DNC를 쓰고, DNC마다 `[1,1,2,64]`를 처리한다.
- 파일의 device 마커는 `rebel_evt0`이다. EVT1로 돌리려면 `--device_mode rebel_evt1`로 덮어쓴다.

### 실행 환경 (2026-10-05 셋업 완료)
| 항목 | 상태 |
|---|---|
| venv | `~/workspaces/.venv-rcl2` (uv, py3.10, conan 2.33 + `requirements.txt`) |
| conan | **artifactory 로그인 없이 ConanCenter만으로 해결됨** (spdlog/fmt/nlohmann_json/magic_enum/benchmark, 고정 revision 포함). profile은 `/tools/lib/rebel_dependency/GCC-12.1.0`로 detect |
| `librebel_primitives.so` | 빌드 완료 (`python build.py`, 7m18s, -j7). Python codegen(`RblnAddArgs`)도 생성됨 |
| VP 바이너리 | `PYTHONPATH=. python tests/helper/install_vp.py`로 rcl2 `vp/`에 복사됨 (gitignore 대상) |
| rcl2 PrecSim | 미빌드 (VP만 쓰므로 불필요) |

환경 변수: `export PATH=~/workspaces/.venv-rcl2/bin:$PATH LD_LIBRARY_PATH=/tools/lib/rebel_dependency/GCC-12.1.0/lib64:$LD_LIBRARY_PATH`

rcl2 단독 실행:
```bash
cd spec_source_inventory/rebel_compute_lib2
python -m pytest tests/src/develop/rebel/alpha/test_rbln_initgen_add.py \
  -k rebel_alpha_ci_add_eltwise_NN_01 --backend vp --device_mode rebel_evt1
# 결과: result/rebel_evt1/alpha/test_rbln_initgen_add/rebel_alpha_ci_add_eltwise_NN_01/
```
- pytest id는 `test_rbln[<case id>]` (함수명은 `test_rbln`). `-k`로 고르는 게 편하다.
- VP 명령: `./260521_vp_rebel_evt1_arbcal <test_dir 상대경로> 2 8 125000 2 0 1 1 0x3f8000 1.9` (cwd = `vp/`)
  - 인자: ncluster, ndnc_per_cluster, timeout cycles, log level, print level, skip_tu, shm_2mb_intrv, init_pos, shm_bus_GHz
- 사이클은 `DNC_0 Init / Exec time: <init> / <exec> cycles`의 **exec** 값 (`run_vp`의 정규식이 `(\d+) cycles` 첫 매치 = exec)

## 첫 비교 결과: add `[1,16,2,64]`, 2×8 DNC (2026-10-05)

| | rcl2 | mcc | 
|---|---|---|
| init 라인 수 / DNC | 10 | 7 |
| VP EVT1 (`260521_..._arbcal`) init / **exec** cycles | 26 / **652** | 23 / **284** |
| VP EVT0 (`250425_..._arbcal`) init / **exec** cycles | 26 / **652** | 23 / **284** |
| Stopping simulation at cycle | 796 | 557 |
| `SHM_final` vs `SHM_golden` | 전 라인 일치 (max err 0) | 전 라인 일치 (pad 라인 포함, bit-exact) |
| rcl2 est_cycles | 586 | – |

- 출력 영역(0x45~0x64)은 `SHM_map`에서 `0xdcba` sentinel로 채워져 있으므로, 일치는 실제로 써진 결과다.
- pre/post dummy pad 라인(`0xeeee`)도 그대로라 out-of-bounds write 없음.
- mcc 실행 방법 (수동, 1회성):
  1. `PrimitiveAuthor/primitives`에서 `uv run --frozen python ~/workspaces/docs/rcl2-vs-mcc-add/build_mcc_add.py <dir>`
     - `AddSpec(1024, 2, in1_addr=0x01, in2_addr=0x23, out_addr=0x45)` → `Image.of(build_add(...))` → `precsim.write_init_txt`로 `init_<d>.txt` 16개
  2. rcl2 결과 디렉터리의 `SHM_map.txt`, `SP_map_*.txt`, `MRV_input.txt`를 복사하고 init만 mcc 것으로 교체
  3. 위 VP 명령을 같은 인자로 실행 → `SHM_final.txt`를 rcl2 `SHM_golden.txt`(주석 제외)와 비교
- 주의: 이건 한 케이스, 한 shape이다. 사이클 차이(652 vs 284)의 원인 분석은 아직 안 했다 (init 디코드 비교 필요).

## 설계 포인트 — add 케이스로 확인된 답
1. **입력 shape과 layout 매핑** → 해결 (elementwise 한정)
   - rcl2 `dims=[1,16,2,64]` = 32 라인. mcc는 `flat_mapping(dims, dncs=16)` → `R=1024, K=2`.
   - rcl2는 `init_<d>` (d = cluster*8 + dnc, cluster-major)가 라인 `base+2d .. base+2d+1`을 처리 (`init_decoded/init_<d>_dec_mem.txt`로 확인). mcc의 fence=16 contiguous split과 동일.
   - mcc는 rcl2식 per-axis tiling이 없다. split이 고정이라 tiling이 다른 케이스(예: `tiling_order=[1,0,2,3]`, broadcast)는 별도로 따져야 한다.
2. **메모리 배치 공유** → mcc가 rcl2 배치를 따르게 함
   - rcl2 배치 (`mem_alloc_info.json`): input1 = SHM line 0x01, input2 = 0x23, output = 0x45 (각 32라인 + mem-check pad 1라인).
   - mcc는 `AddSpec(..., in1_addr, in2_addr, out_addr)`로 SHM 주소를 외부에서 받으므로 그대로 넘기면 된다 (raw line offset 단위로 동작 확인).
   - SP 주소는 mcc가 정한다 (sp_base 984). rcl2 `SP_map_*.txt`는 pad 더미만 있어서 그대로 써도 문제 없었다.
   - 결과적으로 rcl2의 `SHM_map.txt` / `SHM_golden.txt`를 **그대로 재사용** 가능. golden 재배치 불필요.
3. **mcc image → VP 입력 adapter** → 거의 필요 없음
   - `init_<d>.txt` 텍스트 포맷이 rcl2와 동일 (`0x{line:05x}` + word7..word0, 16B 역순). codesigner `precsim.write_init_txt`를 그대로 쓰면 VP가 읽는다.
   - `MRV_input.txt`: rcl2가 만드는 파일(575줄, DNC별 `0x1ff2...` 헤더 `0xf73` + JCR 초기값 0x7b)을 그대로 쓰면 됐다. mcc용으로 따로 만들 필요는 아직 없음.
   - VP 인자의 `skip_tu=1`(rcl2 decoder가 TU 미사용으로 판단)을 mcc에도 그대로 썼다. TU를 쓰는 op에서는 mcc image 기준으로 다시 정해야 한다.
4. **rcl2 기능 호출 방식** → 아직 pytest 러너 경유
   - 지금은 rcl2 pytest를 `--backend vp`로 한 번 돌려 결과 디렉터리를 만들고 거기서 파일을 빌려 쓴다.
   - 비교 테스트로 만들려면 러너 없이 `--only_compute_lib` / `--only_golden_model` 단계 또는 `TensorMaster` + `run_golden_model()`, `run_vp`를 직접 호출하는 쪽으로 정리해야 한다.

## 다음 단계
1. ~~rcl2 빌드~~ (완료)
2. ~~rcl2 단독 add VP 실행, 기준 사이클 확보~~ (652 cycles)
3. ~~mcc add image 형식/배치 확인~~ (완료, 위 표)
4. 사이클 차이 원인 확인: rcl2 init 10라인 vs mcc 7라인 디코드 비교 (rcl2 decoder로 mcc init도 디코드 가능한지 확인)
5. codesigner mcc 쪽에 비교 테스트 작성
   - rcl2 golden 단계 호출 → SHM_map/golden/MRV/SP_map 생성
   - mcc image를 rcl2 주소로 빌드 → `init_<d>.txt`
   - VP 실행(양쪽) → `SHM_final` vs golden, exec cycles 기록
   - VP 바이너리·rcl2 빌드 의존이 있으니 일반 CI lane이 아니라 수동/nightly 타깃으로
6. add 케이스 확장 (broadcast, 다른 tiling, 1 DNC 등) 후 subtract/multiply/divide로
