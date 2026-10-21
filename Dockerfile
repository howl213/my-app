# FastAPI 애플리케이션 실행용 경량 Python 이미지
FROM python:3.9-slim

# 컨테이너 내부의 애플리케이션 작업 디렉터리
WORKDIR /app

# Python 의존성 파일을 먼저 복사하면 소스 코드 변경 시 Docker 캐시를 활용할 수 있음
COPY requirements.txt .

# 필요한 Python 패키지 설치
RUN pip install --no-cache-dir -r requirements.txt

# 애플리케이션 소스 복사
COPY . .

# 외부에서 접근 가능한 주소로 FastAPI 실행
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
