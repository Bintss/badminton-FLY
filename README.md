# 배드민턴 동아리 운동 투표·대진 앱

카톡 투표 + 현장 즉석 대진을 대체하는 모바일 웹앱.
요구사항 명세서: https://claude.ai/artifact/WkE9RPvrJZMHE2LG3G91Hp

- 프론트: Vite + React + TypeScript + React Router + Tailwind CSS (GitHub Pages 정적 배포)
- 백엔드: Supabase (Postgres, Auth/Kakao, RLS, RPC)
- 원칙: 클라이언트는 **SELECT만** 직접 한다. 모든 쓰기는 권한을 확인하는 `security definer` RPC로 처리한다.

## 진행 상황

| 단계 | 내용 | 상태 |
| --- | --- | --- |
| M0 | 프로젝트 셋업, 카카오 로그인 | 완료 (실제 카카오 연동은 아래 설정 후 확인) |
| M1 | 스키마 전체 + RLS, 동아리 생성·가입 신청·승인, 운영진 지정, 이름·급수 | 완료 (SQL 테스트 41개 통과) |
| M2 | register / cancel / update_capacity RPC + 동시 신청 부하 테스트 | 다음 |
| M3~M6 | 템플릿·번개, 투표 화면, 대진판, 파일럿 | 예정 |

## 폴더 구조

```
supabase/
  migrations/20261116000000_init.sql   스키마 + RLS + 가입/승인 RPC
  tests/local_stub.sql                 로컬 검증용 Supabase 스텁 (실서버 적용 금지)
  tests/m1_test.sql                    가입/승인/RLS 격리 테스트
  tests/run_local.sh                   로컬 Postgres로 마이그레이션 + 테스트 실행
src/
  lib/supabase.ts       클라이언트(PKCE), 에러 메시지 매핑
  auth/AuthProvider.tsx 세션·프로필
  club/ClubLayout.tsx   /c/:clubId 이하 승인 회원 가드 + 동아리 컨텍스트
  pages/                로그인, 동아리 선택/가입 신청/만들기, 홈, 내 정보, 회원 관리
.github/workflows/deploy.yml   main push → GitHub Pages 배포
```

## 1. Supabase 설정

1. Supabase 프로젝트 생성
2. 마이그레이션 적용 (둘 중 하나)
   - SQL Editor에 `supabase/migrations/20261116000000_init.sql` 내용을 붙여넣고 실행
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
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (anon 키는 공개되는 값. RLS가 보호)
   - 커스텀 도메인을 쓰면 `VITE_BASE_PATH=/` (기본값은 `/<레포명>/`)
4. main에 push하면 자동 배포. 딥링크 새로고침은 `404.html`(= index.html 복사본)로 처리

**service_role 키는 절대 프론트나 레포에 넣지 않는다.**

## 5. 테스트

```bash
# 로컬 Postgres 16 필요
DATABASE_URL=postgres://postgres@localhost:5432/postgres ./supabase/tests/run_local.sh
```

검증 항목: 프로필 자동 생성, 가입 신청 멱등, 승인 전 데이터 차단, 직접 쓰기 차단, 운영진만 승인,
마지막 운영진 해제 차단, 다른 동아리 격리, 거절 후 재신청, anon 차단 등 41개.
로컬 스텁은 Supabase를 흉내 낸 것이라, 실서버 적용 후 앱에서 한 번 더 확인한다.

## 6. 첫 사용 흐름

1. 운영진이 카카오 로그인 → `동아리 만들기` (만든 사람이 첫 운영진)
2. 회원들은 로그인 → 동아리 목록에서 `가입 신청`
3. 운영진이 홈 > `회원 관리`에서 승인
4. 회원은 `내 정보`에서 이름·급수 입력

현재는 로그인한 누구나 동아리를 만들 수 있다 (다른 동아리 확장 대비). 막고 싶으면 `create_club` 권한을 조정한다.
