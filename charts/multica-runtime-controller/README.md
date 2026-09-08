# Multica Runtime Controller

완성된 custom runtime 이미지를 Kubernetes controller와 task Pod에서 실행하는 chart입니다. Chart `0.4.x`는 controller ABI `2`를 사용하며, `appVersion: "2"`는 이미지 버전이 아니라 이 ABI를 나타냅니다.

`ghcr.io/korioinc/multica-runtime:latest`가 기본 이미지이고 pull policy는 `Always`입니다. 다른 이미지는 [controller 베이스](https://github.com/korioinc/multica-runtime-controller)를 상속하고 공식 Multica CLI, 사용할 provider, 도구, runtime descriptor와 검증 기록을 포함해야 합니다. CLI가 없는 controller 베이스를 직접 지정하면 runtime 시작 검증에서 거부됩니다. 제작 방법과 도구 버전은 [runtime 저장소](https://github.com/korioinc/multica-runtime)에서 관리합니다.

Controller는 시작 시 자기 Pod UID, init/main의 실제 imageID, 이미지 receipt와 플랫폼을 검증합니다. 이후 worker와 worker init은 해당 digest와 플랫폼을 사용합니다. `latest`가 바뀌어도 실행 중인 controller의 task 이미지가 바뀌지 않습니다. OCI index digest도 그대로 고정하고 플랫폼을 함께 제한합니다. 새 latest 게시가 기존 Pod를 자동 재생성하지는 않습니다.

## 필수 연결과 이미지 선택

Controller token Secret은 같은 namespace에 미리 준비해야 합니다. 최소 values 예시는 다음과 같습니다.

```yaml
image: ghcr.io/korioinc/multica-runtime:latest
imagePullPolicy: Always
platform: linux/amd64
multica:
  baseURL: https://multica.example.com
  controllerTokenSecret:
    name: multica-runtime-controller-token
    key: token
workspace:
  storage:
    size: 100Gi
    storageClass: shared-workspace
    accessMode: ReadWriteMany
```

```sh
helm repo add korioinc https://korioinc.github.io/helm
helm upgrade --install multica-runtime-controller korioinc/multica-runtime-controller \
  --namespace multica --version 0.4.0 --values values.yaml
```

`image`에는 version tag, `repository@sha256:...`, 또는 tag와 digest가 함께 있는 참조를 지정할 수 있습니다. Private registry의 경우 `imagePullSecrets: [{name: runtime-registry}]`를 추가합니다. `platform`은 `linux/amd64` 또는 `linux/arm64`이며 node selector가 다른 OS/architecture를 지정하면 render가 실패합니다. 모든 이미지에 두 플랫폼이 반드시 존재하는 것은 아니므로 선택한 custom image가 해당 플랫폼을 지원해야 합니다.

Provider 활성 목록과 버전은 이미지 descriptor가 소유합니다. Chart에는 provider 설치 목록이나 bootstrap script 설정이 없습니다.

## ConfigMap 파일과 디렉터리 override

Provider 파일은 native ConfigMap volume으로 제공합니다. `operator.configVolumes`의 `secret`, `projected`, `hostPath`, PVC 입력은 지원하지 않습니다. 환경 변수용 `operator.envFrom`의 Secret 참조와 controller token Secret은 별도 입력입니다.

```yaml
operator:
  configVolumes:
    - name: codex-settings
      configMap:
        name: runtime-codex-settings
        defaultMode: 288 # 0440: non-root init이 fsGroup으로 읽음
        items:
          - key: config
            path: config.toml
    - name: pi-settings
      configMap:
        name: runtime-pi-settings
        defaultMode: 288
  configMounts:
    - name: codex-settings
      subPath: config.toml
      mountPath: /home/multica/agents/.codex/config.toml
      readOnly: true
    - name: pi-settings
      mountPath: /home/multica/agents/.pi/agent
      readOnly: true
```

`configMounts[].mountPath`는 HOME 안의 최종 복사 위치입니다. `subPath`를 생략하면 해당 ConfigMap projection의 전체 디렉터리를 복사합니다. 지정하면 projection 안의 파일 또는 디렉터리를 선택합니다. Chart는 각 volume을 init에 **전체 projection으로 한 번만** 마운트하고, 동일 volume의 복사 입력에 같은 `sourceGroup`을 전달합니다. Kubernetes file subPath mount로 입력 세대를 고정하지 않습니다.

`home layout` init은 이미지 receipt를 확인하고 전체 입력 bundle을 원자적으로 확정한 뒤 HOME에 파일을 복사합니다. 초기화가 중단돼도 retry는 이미 확정한 bundle을 재사용합니다. 원본 ConfigMap이 바뀌어도 두 세대가 섞이지 않습니다. 운영자 파일이 이미지의 기본 seed보다 우선하며, 이미 생성된 HOME 파일은 retry가 덮어쓰지 않습니다.

대상은 canonical HOME 하위 경로여야 합니다. source/target 중복, 부모·자식 충돌, `..`, symlink를 이용한 경로 이탈을 거부합니다. 다음 경로와 그 하위는 controller가 소유합니다. 디렉터리 복사도 포함 파일을 검사합니다.

- `.multica/config.json`, `.multica/pi-sessions`
- `.codex/skills`, `.pi/agent/sessions`
- `.multica-runtime`

Controller는 확정 bundle에서 source group별 immutable ConfigMap snapshot을 만듭니다. 같은 controller의 worker들은 snapshot을 공유하지만 HOME은 각자 가집니다. Snapshot의 UID·owner·내용이 맞지 않거나 없어지면 실행을 거부합니다. 원본 ConfigMap으로 fallback하지 않습니다. Worker에는 Kubernetes API token을 제공하지 않습니다.

Controller의 namespace Role은 snapshot 생성·조회와 `pods/finalizers`의 `update`를 허용합니다. 후자는 `blockOwnerDeletion` 소유 참조가 `OwnerReferencesPermissionEnforcement`를 사용하는 클러스터에서도 승인되도록 하는 권한입니다. Worker에는 이 권한을 부여하지 않습니다. Admission plugin의 기본 활성 여부를 chart의 실행 전제로 삼지 않습니다.

원본을 변경한 뒤 새 controller Pod에서 입력을 다시 선택해야 합니다. Terraform 모듈은 `checksum/provider-config` annotation으로 이 변경을 전달합니다. Controller 또는 worker가 실행 중 HOME 파일을 수정해도 원본이나 다른 HOME으로 전파되지 않습니다. 파일 데이터는 ConfigMap이므로 namespace의 해당 객체 읽기 권한을 가진 주체에게 보입니다.

## HOME, cache, 실행 권한

Controller와 worker는 UID/GID `65532`, 읽기 전용 rootfs로 실행합니다. Init은 Pod-private emptyDir 안에 `agents`, `tmp`, `run`을 만들고 접근 권한을 `0700`으로 맞춥니다. Main에는 이 child만 각각 HOME, `/tmp`, `/run/multica`로 마운트합니다. 파일 기본 권한은 `0600`이며 필요한 owner 실행 비트만 보존합니다.

Go, npm, Corepack, Cargo, Python/uv/pipx, cloud CLI와 CBM의 cache/config/IPC는 이미지가 선언한 private HOME/tmp 경로를 사용해야 합니다. 이미지의 상위 경로도 group/other writable이면 안 됩니다. Pod가 교체되면 HOME/cache 변경은 사라집니다. 지속해야 하는 설정은 ConfigMap 원본에, 작업 파일은 workspace에 보관합니다.

`runtime.startupTimeout`은 기본 `120s`입니다. 양수 duration을 설정하며 chart의 startup probe는 내부 deadline보다 먼저 liveness 재시작을 유발하지 않도록 계산됩니다. 이미지·설정 binding 전에는 준비 완료로 등록하거나 task를 수락하지 않습니다.

## Workspace와 기존 데이터

Workspace PVC만 관리하며, Tools PVC는 만들지 않습니다. Controller는 전체 workspace registry를 소유하고 worker에는 자기 task의 subPath만 제공합니다. 작업 파일은 같은 권한 범위에서 재사용할 수 있고, 이미지·provider·설정 내용이 달라지면 호환되지 않는 Pi 세션은 분리됩니다. Snapshot 이름/UID만 달라지고 내용이 같으면 세션 호환성은 유지됩니다.

기존 claim을 사용할 때는 다음과 같이 chart의 새 PVC 생성을 끕니다.

```yaml
workspace:
  storage:
    existingClaim: retained-task-workspace
    size: ""
    storageClass: ""
    accessMode: ReadWriteOnce
scheduling:
  singleNodeName: worker-node-1
```

`ReadWriteOnce`에는 실제 node metadata.name인 `singleNodeName`이 필수입니다. Controller와 worker 모두 그 node로 제한됩니다. `ReadWriteMany`에서도 task별 subPath 격리는 유지됩니다. Stable daemon identity Secret과 workspace 데이터는 이미지 선택 변경으로 재생성하지 않습니다.

Schema 1 registry는 정상 실행에서 자동 변환하지 않습니다. 기존 writer와 task 자원이 중지되고 미완료 attempt가 해소된 상태에서 controller의 명시적 `workspace migrate --dry-run`과 source digest를 사용하는 `--commit`으로 이관해야 합니다. 명령 형식과 보존 조건은 controller 문서를 따릅니다. Chart rollback이나 workspace PVC 삭제가 migration을 대신하지 않습니다.

이전 chart의 `runtime.image`, `environment`, `replicaCount`는 추가 속성 오류로 거부됩니다. 이전 chart가 소유한 Tools PVC는 새 manifest에서 제거되므로 실제 Helm upgrade의 prune 대상이 될 수 있습니다. 필요한 기존 데이터는 upgrade 전에 별도 보존·소유권 해제 절차로 보호해야 합니다. 이 chart에는 기존 PVC를 삭제하거나 초기화하는 migration hook이 없습니다.

## 진단과 로컬 검증

- Descriptor/CLI hash/ABI 오류: 해당 controller source와 adapter 검증으로 완성 이미지를 다시 만들어야 합니다.
- Image receipt 또는 init/main 불일치: 서로 다른 빌드가 한 Pod에서 선택됐습니다. 현재 latest를 추정해 이어서 실행하지 않습니다.
- Pull 가능한 imageID가 없음: bare config digest는 실행 이미지 증거가 아닙니다. CRI가 repository manifest digest를 보고하는지 확인합니다.
- Snapshot 충돌·UID 교체·payload 불일치: 동명 객체를 덮어쓰거나 임의 채택하지 않습니다. 실패 phase와 소유 controller Pod를 확인합니다.
- Schema 1 또는 미완료 attempt: 파일 삭제로 우회하지 말고 명시적 migration/기존 자원 정리가 필요합니다.

```sh
scripts/verify-chart.sh --ci
```

이 명령은 local Helm lint/render, Kubernetes schema 검증과 package를 수행합니다. Helm, curl, tar, shasum이 필요하며, checksum을 고정한 native kubeconform `v0.7.0`을 임시 디렉터리에 내려받습니다. Go/Python 실행 래퍼나 runtime registry 조회는 사용하지 않습니다. 실제 provider 실행이나 fsGroup 권한 호환성은 controller 저장소의 disposable local Kubernetes 검증에서 별도로 확인합니다. Helm CI는 runtime 버전을 조회하거나 기본 이미지를 자동 갱신하지 않습니다.
