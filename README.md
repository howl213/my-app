# my-app

CI/CD 전체 흐름은 [실습 시나리오의 흐름도](../CI-CD-SCENARIO.md)를 참고하세요.

FastAPI 애플리케이션을 컨테이너 이미지로 빌드하기 위한 디렉터리입니다.

## 디렉터리 구성

```text
my-app/
├── Dockerfile
├── requirements.txt
├── main.py
├── tests/
│   └── test_main.py
├── .github/
│   └── workflows/
│       └── ci.yml
└── README.md
```

`Dockerfile`은 다음 파일을 실행하도록 구성되어 있습니다.

```text
main:app
```

`main.py`에 `app = FastAPI()` 객체가 있어야 합니다.

## 의존성 사전 준비

실습 중 의존성 오류가 발생하지 않도록 실행 및 테스트 패키지를 미리 설치합니다.

```bash
cd devops/my-app
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pytest -q
```

`requirements.txt` 하나에 컨테이너 실행 패키지와 테스트 패키지를 모두 관리합니다.
GitHub Actions도 동일한 파일을 사용하므로 로컬과 CI의 의존성 구성이 일치합니다.

## Dockerfile 설명

```dockerfile
FROM python:3.9-slim
```

Python 3.9 기반의 경량 이미지를 사용합니다. `python:3.9-slim`은
amd64와 arm64 플랫폼을 지원하므로 멀티플랫폼 빌드에 사용할 수 있습니다.

```dockerfile
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
```

Python 의존성을 `requirements.txt`에서 설치합니다.

```dockerfile
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

컨테이너가 시작되면 FastAPI를 8000번 포트로 실행합니다.

## 멀티플랫폼 이미지 빌드

멀티플랫폼 이미지는 Dockerfile에 플랫폼을 고정하지 않고
`docker buildx build` 명령의 `--platform` 옵션으로 생성합니다.

### 1. Buildx 확인

```bash
docker buildx version
```

Buildx 빌더가 없으면 생성합니다.

```bash
docker buildx create \
  --name multiarch-builder \
  --driver docker-container \
  --use

docker buildx inspect --bootstrap
```

이미 생성된 빌더를 사용하는 경우:

```bash
docker buildx use multiarch-builder
```

### 2. ECR 로그인

```bash
aws ecr get-login-password \
  --region ap-northeast-2 | \
docker login \
  --username AWS \
  --password-stdin 637423638906.dkr.ecr.ap-northeast-2.amazonaws.com
```

### 3. ECR 이미지 빌드 및 Push

프로젝트 루트에서 실행합니다.

```bash
cd devops/my-app

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t 637423638906.dkr.ecr.ap-northeast-2.amazonaws.com/fastapi-backend:v1.0 \
  -t 637423638906.dkr.ecr.ap-northeast-2.amazonaws.com/fastapi-backend:latest \
  --push \
  .
```

플랫폼별 이미지를 하나의 manifest 목록으로 ECR에 업로드합니다.

- `linux/amd64`: 일반 x86 EKS 노드
- `linux/arm64`: AWS Graviton ARM 노드
- `--push`: 멀티플랫폼 이미지를 ECR에 업로드
- `--load`: 단일 플랫폼 로컬 이미지에 사용

멀티플랫폼 빌드에서는 `--load` 대신 반드시 `--push`를 사용합니다.

## 이미지 플랫폼 확인

```bash
docker buildx imagetools inspect \
  637423638906.dkr.ecr.ap-northeast-2.amazonaws.com/fastapi-backend:v1.0
```

다음 플랫폼이 표시되어야 합니다.

```text
linux/amd64
linux/arm64
```

ECR 태그 목록 확인:

```bash
aws ecr describe-images \
  --region ap-northeast-2 \
  --repository-name fastapi-backend \
  --query 'imageDetails[].imageTags' \
  --output table
```

## Dockerfile 플랫폼 설정 주의사항

다음처럼 Dockerfile에서 플랫폼을 고정하지 않습니다.

```dockerfile
FROM --platform=linux/amd64 python:3.9-slim
```

플랫폼을 고정하면 arm64 이미지를 제대로 생성할 수 없습니다.

다음처럼 기본 이미지만 지정합니다.

```dockerfile
FROM python:3.9-slim
```

## Kubernetes에서 사용

Deployment의 이미지를 ECR 이미지로 지정합니다.

```yaml
containers:
  - name: backend
    image: 637423638906.dkr.ecr.ap-northeast-2.amazonaws.com/fastapi-backend:v1.0
```

Kubernetes가 노드의 아키텍처에 맞는 이미지를 자동으로 선택합니다.

노드 아키텍처 확인:

```bash
kubectl get nodes -L kubernetes.io/arch
```

Pod가 사용하는 이미지 확인:

```bash
kubectl get pods -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,IMAGE:.spec.containers[*].image'
```

## GitHub Actions에서 ECR Push 설정

`.github/workflows/ci.yml`은 다음 조건으로 동작합니다.

- `main` push: AWS OIDC Role을 사용하여 ECR에 이미지 Push

GitHub 저장소의 `Settings → Secrets and variables → Actions`에 다음 Secret을
등록해야 합니다.

```text
AWS_GITHUB_ACTIONS_ROLE_ARN=arn:aws:iam::637423638906:role/<GitHubActions용Role>
```

AWS OIDC Role에는 해당 ECR 저장소에 대한 로그인·이미지 Push 권한이 필요합니다.
장기 AWS Access Key를 GitHub Secret에 저장하는 방식은 사용하지 않습니다.

## ECR Push 후 Manifest 자동 갱신

`main` 브랜치 Push가 성공하면 Workflow가 다음 작업을 자동 수행합니다.

```text
테스트 → 멀티플랫폼 이미지 빌드 → ECR Push
                              ↓
             my-k8s-manifests/monolith/frontend.yml 갱신
                              ↓
                    Manifest 저장소 Push
                              ↓
                         Argo CD Sync
```

App Repo의 GitHub 저장소에 다음 Secret을 추가해야 합니다.

```text
MANIFEST_REPO_TOKEN
```

Secret 등록 위치는 `yundo-main/my-app`입니다. `my-k8s-manifests` 저장소가
아닙니다. 현재 Workflow가 App Repo에서 실행되기 때문에 App Repo의 Secret을
사용해 ECR Push와 Manifest Repo Push를 수행합니다.

필요한 Secret:

| Secret | 용도 |
|---|---|
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | GitHub Actions의 AWS·ECR 접근 |
| `MANIFEST_REPO_TOKEN` | `my-k8s-manifests`에 이미지 태그 Commit·Push |

### Secret 추가 방법

GitHub에서 App Repo `yundo-main/my-app`를 열고 다음 메뉴로 이동합니다.

```text
Settings → Secrets and variables → Actions → New repository secret
```

추가할 값:

```text
Name: AWS_GITHUB_ACTIONS_ROLE_ARN
Value: arn:aws:iam::637423638906:role/<GitHubActions용Role>
```

AWS CLI로 Role ARN을 조회하는 방법:

```bash
aws sts get-caller-identity

aws iam list-roles \
  --query 'Roles[].{Name:RoleName,Arn:Arn}' \
  --output table
```

GitHub 관련 Role만 조회:

```bash
aws iam list-roles \
  --query 'Roles[?contains(RoleName, `GitHub`) || contains(RoleName, `github`)].{Name:RoleName,Arn:Arn}' \
  --output table
```

Role 이름으로 ARN 조회:

```bash
ROLE_NAME="GitHubActionsECRRole"
ROLE_ARN=$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)
echo "$ROLE_ARN"
```

GitHub Secret 등록:

```bash
gh secret set AWS_GITHUB_ACTIONS_ROLE_ARN \
  --repo yundo-main/my-app \
  --body "$ROLE_ARN"
```

등록 확인:

```bash
gh secret list --repo yundo-main/my-app
```

`aws iam get-role`에서 `NoSuchEntity`가 발생하면 GitHub OIDC용 IAM Role이 없는
상태입니다. 다음 절차로 생성합니다.

```bash
aws iam list-open-id-connect-providers
```

OIDC Provider가 없으면 생성합니다.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

`github-oidc-trust.json` 파일에 `yundo-main/my-app`의 `main` 브랜치만
허용하는 Trust Policy를 저장한 뒤 Role을 생성합니다. Trust Policy의
Federated 값은 다음 형식입니다.

파일 생성:

```bash
cd devops/my-app
nano github-oidc-trust.json
```

앞에서 설명한 Trust Policy JSON을 붙여넣고 다음 순서로 저장합니다.

```text
Control + O → Enter → Control + X
```

파일 확인:

```bash
python -m json.tool github-oidc-trust.json
ls -l github-oidc-trust.json
```

```text
arn:aws:iam::637423638906:oidc-provider/token.actions.githubusercontent.com
```

Role 생성과 ECR 권한 연결:

```bash
ROLE_NAME="github-actions-ecr"

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://github-oidc-trust.json

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

Role ARN을 다시 조회하고 Secret을 등록합니다.

```bash
ROLE_ARN=$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)

gh secret set AWS_GITHUB_ACTIONS_ROLE_ARN \
  --repo yundo-main/my-app \
  --body "$ROLE_ARN"
```

```text
Name: MANIFEST_REPO_TOKEN
Value: my-k8s-manifests에 Push 권한이 있는 GitHub Fine-grained PAT
```

PAT는 `yundo-main/my-k8s-manifests` 저장소만 선택하고,
`Repository permissions → Contents → Read and write`를 부여합니다.

GitHub CLI로 추가하려면:

```bash
gh secret set AWS_GITHUB_ACTIONS_ROLE_ARN --repo yundo-main/my-app
gh secret set MANIFEST_REPO_TOKEN --repo yundo-main/my-app
gh secret list --repo yundo-main/my-app
```

이 Token은 `yundo-main/my-k8s-manifests` 저장소의 `Contents: Read and write`
권한이 있어야 합니다. Token은 Workflow 로그에 출력하지 않으며 GitHub Secret으로만
사용합니다.

자동 갱신 대상 파일은 다음과 같습니다.

```text
my-k8s-manifests/monolith/frontend.yml
```

자동 갱신 후 확인:

```bash
kubectl get application my-app-monolith -n argocd
kubectl rollout status deployment/fastcgi-backend
kubectl get deployment fastcgi-backend \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\\n"}'
```

## Argo CD GUI 확인

Argo CD GUI는 기본적으로 외부에 공개되지 않으므로 Port Forward로 접속합니다.

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

브라우저에서 다음 주소를 엽니다.

```text
https://localhost:8080
```

관리자 비밀번호 확인:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

로그인 후 `Applications → my-app-monolith`에서 다음 상태를 확인합니다.

```text
Sync Status: Synced
Health Status: Healthy
```

Port Forward를 종료하려면 실행 중인 터미널에서 `Ctrl+C`를 누릅니다.

## 단일 플랫폼 로컬 테스트

멀티플랫폼 이미지는 `--load`로 로컬 Docker에 적재할 수 없으므로,
플랫폼별로 따로 테스트합니다.

```bash
docker buildx build \
  --platform linux/amd64 \
  -t fastapi-backend:test-amd64 \
  --load \
  .
```

```bash
docker run --rm -p 8000:8000 fastapi-backend:test-amd64
```

## 주의사항

- `main.py`가 없으면 이미지 빌드는 되더라도 컨테이너 실행에 실패합니다.
- `secret.yml`은 실습용 평문 Secret이므로 공개 저장소에 업로드하지 않습니다.
- 운영 환경에서는 AWS Secrets Manager 또는 External Secrets를 사용합니다.
- `latest`보다 `v1.0`, Git SHA 같은 고정 태그 사용을 권장합니다.
