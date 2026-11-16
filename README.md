# 배드민턴 동아리 운동 투표·대진 앱

카톡 투표 + 현장 즉석 대진을 대체하는 모바일 웹앱.
요구사항 명세서: https://claude.ai/artifact/WkE9RPvrJZMHE2LG3G91Hp

- 프론트: Vite + React + TypeScript + React Router + Tailwind CSS (GitHub Pages 정적 배포)
- 백엔드: Supabase (Postgres, Auth/Kakao, RLS, RPC)
- 원칙: 클라이언트는 **SELECT만** 직접 한다. 모든 쓰기는 권한을 확인하는 `security definer` RPC로 처리한다.

## 진행 상황

| 단계 | 내용 | 상태 |
| --- | --- | --- |
| M0 | 프로젝트 셋업, 카카오 로그인 | 완료 (실서버 카카오 로그인 확인) |
| M1 | 스키마 전체 + RLS, 동아리 생성·가입 신청·승인, 운영진 지정, 이름·급수 | 완료 (SQL 테스트 41개) |
| M2 | 신청·취소·정원 변경 RPC, 대기자 자동 승격, 동시 신청 부하 테스트 | 완료 (SQL 테스트 34개 + 동시성 검증 21개, DB만. 화면은 M4) |
| M3 | 정기운동 템플릿 + pg_cron, 번개 개설 | 다음 |
| M4~M6 | 투표 화면, 대진판, 파일럿 | 예정 |

## 폴더 구조

```
supabase/
  migrations/20261116000000_init.sql          스키마 + RLS + 가입/승인 RPC
  migrations/20261116010000_registration.sql  신청/취소/정원 변경 RPC (M2)
  tests/local_stub.sql                 로컬 검증용 Supabase 스텁 (실서버 적용 금지)
  tests/m1_test.sql                    가입/승인/RLS 격리 테스트
  tests/m2_test.sql                    신청/취소/승격/정원 변경 테스트
  tests/run_local.sh                   로컬 Postgres로 마이그레이션 + 테스트 실행
  tests/load/run_load.sh               pgbench 동시 신청 테스트 (100명 동시)
src/
  lib/supabase.ts       클라이언트(PKCE), 에러 메시지 매핑
  auth/AuthProvider.tsx 세션·프로필
  club/ClubLayout.tsx   /c/:clubId 이하 승인 회원 가드 + 동아리 컨텍스트
  pages/                로그인, 동아리 선택/가입 신청/만들기, 홈, 내 정보, 회원 관리
.github/workflows/deploy.yml   main push → GitHub Pages 배포
```

## 1. Supabase 설정

1. Supabase 프로젝트 생성
2. 마이그레이션 적용 (둘 중 하나). `supabase/migrations/`의 파일을 **이름 순서대로** 한 번씩
   - SQL Editor에 각 파일 내용을 붙여넣고 실행 (이미 실행한 파일은 다시 실행하지 않는다)
   - 또는 CLI: `supabase link --project-ref <ref>` → `supabase db push`
3. Authentication > URL Configuration
   - Site URL: `https://<github-id>.github.io/<repo>/`
   - Redirect URLs: 위 주소 + `http://localhost:5173/`

## 2. 카카오 로그인 설정

1. [Kakao Developers](https://developers.kakao.com)에서 애플리케이션 생성
2. 앱 설정 > 플랫폼 > Web: 사이트 도메인에 `https://<github-id>.github.io`, `http://localhost:5173` 등록
3. 카카오 로그인 > 활성화 ON, Redirect URI: `https://<project-ref>.supabase.co/auth/v1/callback`
4. 카카오 로그인 > 보안 > Client Secret 발급 후 활성화
5. 동의항목: 닉네임(필수)
6. Supabase > Authentication > Providers > Kakao 켜고
   - Client ID = 앱 키의 **REST API 키**
   - Client Secret = 4번에서 발급한 값

> **이메일 동의항목 주의**: 카카오는 비즈 앱이 아니면 이메일(account_email) 동의항목을 받기 어렵고,
> Supabase Kakao provider는 기본적으로 이메일을 요청한다. 로그인 시 이메일 관련 오류가 나면
> ① Supabase Kakao provider 설정에 이메일 없는 사용자 허용 옵션이 있는지 확인하고,
> ② 없으면 카카오 앱을 비즈 앱으로 전환(개인 개발자도 가능)해 이메일 동의항목을 설정한다.
> M0에서 가장 먼저 확인할 항목.

프로필 이름은 카카오 닉네임으로 자동 생성되고, 앱의 `내 정보`에서 바꿀 수 있다.

## 3. 로컬 실행

```bash
cp .env.example .env.local   # Supabase URL, anon 키 입력
npm install
npm run dev                  # http://localhost:5173
```

## 4. GitHub Pages 배포

1. 레포를 **public**으로 생성 (무료 플랜 Pages 조건) 후 push
2. Settings > Pages > Source: **GitHub Actions**
3. Settings > Secrets and variables > Actions > **Variables**에 등록
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` (`sb_publishable_...`, 공개되는 값. RLS가 보호)
   - 예전 이름 `VITE_SUPABASE_ANON_KEY`로 등록했다면 그대로 둬도 동작한다
   - 커스텀 도메인을 쓰면 `VITE_BASE_PATH=/` (기본값은 `/<레포명>/`)
4. main에 push하면 자동 배포. 딥링크 새로고침은 `404.html`(= index.html 복사본)로 처리

**service_role 키는 절대 프론트나 레포에 넣지 않는다.**

## 5. 테스트

```bash
# 로컬 Postgres 16 필요
DATABASE_URL=postgres://postgres@localhost:5432/postgres ./supabase/tests/run_local.sh        # 기능 (M1 41개 + M2 34개)
DATABASE_URL=postgres://postgres@localhost:5432/postgres ./supabase/tests/load/run_load.sh   # 동시성 (max_connections ≥ 150)
```

로컬 스텁은 Supabase를 흉내 낸 것이라, 실서버 적용 후 앱에서 한 번 더 확인한다.

### 투표 동시성 설계 (M2)

- 신청·취소·정원 변경은 모두 **세션 행을 `FOR UPDATE`로 잠근 뒤** 처리 → 같은 운동에 대한 요청은 한 줄로 서서 하나씩 처리된다
- 오픈 판정은 `now()` = 서버가 요청을 받은 시각. 단말 시계와 무관
- 접수 순서 = `seq` (서버 처리 순서). 확정/대기 순번은 이 값으로 계산
- 확정자가 취소하거나 정원이 늘면 같은 트랜잭션에서 대기 1순위부터 승격
- 정원은 회원 신청만 센다 (게스트 제외). 같은 사람이 동시에 여러 번 눌러도 신청은 1건

### 동시 신청 테스트 결과 (로컬 2코어 컨테이너, pgbench)

| 시나리오 | 결과 | DB 처리 지연 |
| --- | --- | --- |
| 서로 다른 100명 동시 신청, 정원 30 | 확정 30 / 대기 70, 초과 0, 순서 역전 0 | p50 317ms, p95 471ms |
| 50명이 각자 2번씩 동시 신청 | 신청 50건만 생성, 중복 0 | p95 465ms |
| 확정자 20명 취소 + 신규 40명 신청 동시 | 확정 30 유지, 승격 20명 = 기존 대기 1~20순위 | p95 303ms |

- 지연은 100건이 한 줄로 처리되는 대기 시간이 대부분이다. 1건 처리는 약 1.6ms(연결 재사용 시)
- 이 값에는 **네트워크가 빠져 있다.** 실제 p95(목표 1초 미만)는 M4 투표 화면이 나온 뒤 실서버에서 측정한다
- Supabase 프로젝트 리전은 **Northeast Asia (Seoul)** 권장 (리전은 프로젝트 생성 후 변경 불가)

## 6. 첫 사용 흐름

1. 운영진이 카카오 로그인 → `동아리 만들기` (만든 사람이 첫 운영진)
2. 회원들은 로그인 → 동아리 목록에서 `가입 신청`
3. 운영진이 홈 > `회원 관리`에서 승인
4. 회원은 `내 정보`에서 이름·급수 입력

현재는 로그인한 누구나 동아리를 만들 수 있다 (다른 동아리 확장 대비). 막고 싶으면 `create_club` 권한을 조정한다.
