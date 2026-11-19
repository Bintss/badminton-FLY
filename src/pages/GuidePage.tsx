import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { IconChevronDown, IconChevronLeft } from '../components/icons'
import { Card, Page } from '../components/ui'

/** 화면에 있는 버튼·메뉴 이름 */
function K({ children }: { children: ReactNode }) {
  return <span className="whitespace-nowrap rounded-md bg-court-50 px-1.5 py-0.5 text-[0.92em] font-semibold text-court-700">{children}</span>
}

function Section({ id, title, lead, children }: { id: string; title: string; lead: ReactNode; children?: ReactNode }) {
  return (
    <section id={id} className="scroll-mt-4">
      <h2 className="mb-1.5 mt-8 px-1 text-[18px] font-bold text-ink">{title}</h2>
      <Card>
        <p className="text-[15px] leading-relaxed text-ink">{lead}</p>
        {children}
      </Card>
    </section>
  )
}

function Steps({ items }: { items: ReactNode[] }) {
  return (
    <ol className="mt-3 space-y-2.5">
      {items.map((it, i) => (
        <li key={i} className="flex gap-2.5 text-[15px] leading-relaxed text-ink">
          <span className="score mt-px flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-court-600 text-[14px] font-semibold text-white">{i + 1}</span>
          <span className="min-w-0">{it}</span>
        </li>
      ))}
    </ol>
  )
}

function Bullets({ items }: { items: ReactNode[] }) {
  return (
    <ul className="mt-3 space-y-1.5">
      {items.map((it, i) => (
        <li key={i} className="flex gap-2 text-[15px] leading-relaxed text-ink">
          <span className="mt-[0.6em] h-1.5 w-1.5 shrink-0 rounded-full bg-ink-faint" aria-hidden />
          <span className="min-w-0">{it}</span>
        </li>
      ))}
    </ul>
  )
}

function Note({ children }: { children: ReactNode }) {
  return <p className="mt-3 rounded-xl bg-floor px-3 py-2.5 text-sm leading-relaxed text-ink-soft">{children}</p>
}

const TOC = [
  ['start', '시작하기'],
  ['me', '내 정보와 알림'],
  ['vote', '운동 참석'],
  ['flash', '번개 열기'],
  ['board', '운동 당일 대진판'],
  ['tournament', '자체대회'],
  ['faq', '자주 묻는 질문'],
] as const

const FAQ: [string, ReactNode][] = [
  ['폰 알림이 안 와요', <><K>내 정보 › 알림</K>에서 이 기기 알림이 켜져 있는지 확인하세요. 막혀 있다고 나오면 폰 설정의 앱(또는 브라우저) 알림에서 허용해 주세요.</>],
  ['아이폰에서 알림 켜기가 안 돼요', '사파리나 크롬에서 홈 화면에 추가한 뒤, 홈 화면의 앱 아이콘으로 열어서 켜야 해요 (iOS 16.4 이상).'],
  ['카카오톡에서 열었더니 알림을 못 켜요', '카톡 안 브라우저는 알림을 못 받아요. 오른쪽 위 메뉴 → "다른 브라우저로 열기"로 크롬이나 사파리에서 열어 주세요.'],
  ['참석 신청 버튼이 안 눌려요', '투표 오픈 전이에요. 운동 화면에 남은 시간이 보이고, 10분 전에 알림이 와요.'],
  ['대기인데 확정되면 어떻게 알아요?', <>앞사람이 취소하면 자동으로 확정돼요. 운동 화면과 일정 탭의 <K>참석</K> 표시로 확인하세요.</>],
  ['대진판에서 아무것도 안 눌려요', '참석이 확정됐고 운동 시작 3시간 전부터 끝나고 3시간 사이일 때만 다룰 수 있어요. 그 밖에는 보기만 돼요.'],
  ['내 동아리가 목록에 없어요', <><K>동아리</K> 화면 검색칸에 이름의 일부를 입력해 보세요.</>],
  ['다른 동아리도 같이 들 수 있나요?', <>네. <K>내 정보 › 동아리 전환</K>으로 동아리 목록에 가서 가입 신청하면 돼요.</>],
  ['동아리를 나가고 싶어요', <><K>내 정보</K> 맨 아래 <K>동아리 나가기</K>. 예정된 운동 신청은 함께 취소돼요.</>],
]

/** 회원용 이용 가이드 (운영진 기능은 다루지 않음) */
export default function GuidePage() {
  const { club } = useClub()
  const back = (
    <Link to={`/c/${club.id}/me`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      내 정보
    </Link>
  )

  return (
    <Page title="이용 가이드" back={back}>
      <p className="px-1 text-[15px] leading-relaxed text-ink-soft">운동 투표부터 대진판, 자체대회까지 회원이 쓰는 기능을 순서대로 정리했어요.</p>

      <nav aria-label="가이드 목차" className="mt-4 flex flex-wrap gap-1.5">
        {TOC.map(([id, label]) => (
          <a key={id} href={`#${id}`} onClick={(e) => { e.preventDefault(); document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' }) }}
            className="rounded-full bg-white px-3 py-1.5 text-sm font-semibold text-ink-soft ring-1 ring-black/[0.08] active:bg-floor">
            {label}
          </a>
        ))}
      </nav>

      <Section id="start" title="시작하기" lead="카카오로 로그인하고 동아리에 가입 신청을 하면, 운영진이 승인한 뒤부터 운동 투표에 참여할 수 있어요.">
        <Steps
          items={[
            <>앱 주소를 <b>크롬이나 사파리</b>에서 열고 <K>카카오 로그인</K>을 눌러요. 카카오톡 안에서 바로 열면 알림을 받을 수 없으니, 오른쪽 위 메뉴의 "다른 브라우저로 열기"를 써 주세요.</>,
            <><K>동아리</K> 화면에서 내 동아리를 찾아요. 목록에는 몇 개만 보이니, 안 보이면 검색칸에 동아리 이름을 입력하세요.</>,
            <><K>가입 신청</K>을 누르고 운영진이 승인할 때까지 기다려요. 승인되면 알림이 와요.</>,
            <>앱처럼 쓰려면 홈 화면에 추가하세요. 아이폰은 사파리 아래쪽 공유 버튼 → "홈 화면에 추가", 안드로이드는 크롬 오른쪽 위 메뉴 → "홈 화면에 추가" 또는 "앱 설치".</>,
          ]}
        />
        <Note>
          새 동아리를 만들고 싶다면 <K>동아리</K> 화면 맨 아래에서 <K>개설 신청</K>을 하세요. 관리자가 승인하면 동아리가 만들어지고, 신청한 사람이 첫 운영진이 돼요.
        </Note>
      </Section>

      <Section id="me" title="내 정보와 알림" lead={<>가입이 승인되면 아래 <K>내 정보</K> 탭에서 이름·급수·성별을 입력하고 알림을 켜 주세요.</>}>
        <Bullets
          items={[
            <><b>이름</b>: 모든 동아리에서 같은 이름으로 보여요. 실명을 권해요.</>,
            <><b>급수</b> (A조·B조·C조·D조·초심): 자체대회 자동 대진에서 두 팀 실력을 맞출 때 써요.</>,
            <><b>성별</b>: 자체대회에서 혼복·남복·여복을 짤 때 써요.</>,
          ]}
        />
        <p className="mt-4 text-[15px] leading-relaxed text-ink">
          <K>내 정보 › 알림</K>에서 <K>알림 켜기</K>를 누르고 폰에서 허용을 눌러요. 기기마다 따로 켜야 하고, 아이폰은 홈 화면에 추가한 앱으로 열어야 켤 수 있어요 (iOS 16.4 이상). 받을 수 있는 알림은 아래와 같고, 같은 화면에서 종류별로 끌 수 있어요.
        </p>
        <Bullets
          items={[
            <><b>새 운동 투표</b>: 정기운동·번개·자체대회가 생겼을 때</>,
            <><b>투표 10분 전</b>: 선착순 투표가 열리기 10분 전</>,
            <><b>코트 배정</b>: 내 경기가 코트에 들어갔을 때</>,
            <><b>코트 대기</b>: 자체대회에서 내 경기가 그 코트의 바로 다음 차례일 때</>,
            <><b>가입 승인</b>: 동아리 가입이 승인됐을 때</>,
          ]}
        />
        <Note>받은 알림은 화면 위 종 모양을 눌러 알림함에서 다시 볼 수 있어요. 빨간 숫자는 안 읽은 알림 수예요.</Note>
      </Section>

      <Section id="vote" title="운동 참석" lead={<>운동은 선착순이에요. 투표가 열리는 시각에 <K>참석 신청</K>을 누른 순서대로 확정되고, 정원이 차면 대기로 들어가요.</>}>
        <p className="mt-3 text-[15px] leading-relaxed text-ink">
          <K>일정</K> 탭에는 앞으로 7일 안의 운동이 보여요. 그 뒤 운동은 맨 아래 <K>7일 뒤 운동 더 보기</K>를 누르면 펼쳐져요. 카드의 막대는 정원이 얼마나 찼는지예요.
        </p>
        <div className="mt-3 overflow-hidden rounded-xl ring-1 ring-black/[0.06]">
          {[
            ['오픈 전', '아직 투표 전. 운동을 눌러 들어가면 열리기까지 남은 시간이 보여요'],
            ['투표 중', '지금 신청하면 바로 확정'],
            ['마감', '정원이 찼어요. 신청하면 대기로 들어가요'],
            ['진행 중', '운동 중. 신청은 닫혔어요'],
          ].map(([k, v]) => (
            <div key={k} className="flex gap-3 border-b border-black/[0.06] px-3 py-2.5 text-sm last:border-0">
              <span className="w-14 shrink-0 font-bold text-ink">{k}</span>
              <span className="min-w-0 text-ink-soft">{v}</span>
            </div>
          ))}
        </div>
        <h3 className="mt-5 text-[15px] font-bold text-ink">신청하기</h3>
        <Steps
          items={[
            <>운동 카드를 눌러 열고, 투표가 열리면 <K>참석 신청</K>(마감이면 <K>대기 신청</K>)을 눌러요.</>,
            '확정이면 몇 번째인지, 대기면 대기 몇 번인지 보여요. 앞사람이 취소하면 대기자는 순서대로 자동 확정돼요.',
            <>늦게 갈 거라면 신청 후 <K>늦참 표시</K>를 눌러 도착 예정 시각을 남겨요. 대진 짤 때 참고해요.</>,
            <>못 가게 되면 <K>참석 취소</K>를 눌러요. 내가 빠지면 대기 1번이 바로 확정돼요.</>,
          ]}
        />
        <h3 className="mt-5 text-[15px] font-bold text-ink">게스트 데려오기</h3>
        <p className="mt-1 text-[15px] leading-relaxed text-ink">
          투표가 열려 있는 동안 운동 화면의 <K>게스트 데려오기</K>에서 이름을 넣고 <K>추가</K>를 눌러요. 성별·급수는 모르면 비워도 돼요.
        </p>
        <Bullets
          items={[
            '한 사람이 한 운동에 3명까지 데려올 수 있어요.',
            '게스트가 정원에 포함되는지는 운동마다 달라요. 포함되는 운동이면 게스트도 선착순이라, 정원이 차면 대기로 들어가요.',
            <>참석 명단에는 "OO님 손님"으로 누가 데려왔는지 보여요. 못 오게 되면 같은 곳에서 <K>빼기</K>를 눌러요.</>,
          ]}
        />
      </Section>

      <Section id="flash" title="번개 열기" lead={<>회원이면 누구나 <K>일정</K> 탭 오른쪽 위 <K>번개</K> 버튼으로 운동을 열 수 있어요.</>}>
        <Steps
          items={[
            '제목, 날짜, 시간, 장소, 정원, 코트 수를 입력해요.',
            <>게스트를 정원에 넣을지 고르고, 투표를 <K>지금 바로</K> 열지 <K>시각 예약</K>으로 열지 정해요.</>,
            '만들면 동아리 회원들에게 새 운동 알림이 가요.',
          ]}
        />
        <Note>
          번개를 연 사람은 그 운동 화면의 <K>운동 관리</K>에서 정원 변경, 일정 수정, 운동 취소를 할 수 있어요. 투표가 이미 열렸다면 오픈 시각은 바꿀 수 없어요.
        </Note>
      </Section>

      <Section id="board" title="운동 당일 대진판" lead={<>운동 시작 3시간 전부터 끝나고 3시간까지, 참석이 확정된 사람은 누구나 대진판을 다룰 수 있어요. 운동 화면의 <K>대진판 열기</K>나 아래 <K>대진판</K> 탭으로 들어가요.</>}>
        <Steps
          items={[
            <><b>도착 처리</b>: 체육관에 오면 <K>참석자</K> 목록에서 내 이름 옆 <K>도착</K>을 눌러요. 쉬는 시간은 도착한 때부터 세요.</>,
            <><b>경기 만들기</b>: 참석자 4명을 눌러 고르고 <K>경기 만들기</K>를 눌러요. 목록은 게임 수가 적고 오래 쉬었던 사람부터 보여요. 30분 넘게 쉰 사람은 노란색이에요.</>,
            <><b>코트 배정</b>: 빈 코트가 있으면 바로 들어가고, 없으면 대기 경기로 줄을 서요. 내 경기가 코트에 들어가면 코트 배정 알림이 와요.</>,
            <><b>경기 끝</b>: 코트의 <K>경기 종료</K>를 누르면 대기 1번 경기가 그 코트로 자동으로 들어가요.</>,
          ]}
        />
        <Note>누가 바꾸든 모든 폰에 바로 반영돼요. 현장에 갑자기 온 게스트는 대진판 아래 게스트 칸에 이름을 넣어 바로 추가할 수 있어요.</Note>
      </Section>

      <Section id="tournament" title="자체대회" lead="자체대회는 운영진이 대진표를 미리 짜서 공개하고, 경기마다 들어갈 코트가 정해져 있어요. 참석 신청은 일반 운동과 같아요.">
        <Steps
          items={[
            <><b>대진표 보기</b>: 대회 운동 화면의 <K>대진표 보기</K>를 눌러요. 경기 왼쪽에 코트 번호가 있고, 내 경기는 연한 초록색이에요.</>,
            <><b>내 다음 경기</b>: 맨 위 <K>내 대회 경기</K>에 다음 경기의 코트·매치·파트너·상대가 나와요.</>,
            <><b>도착 처리</b>: 경기는 4명이 모두 도착해야 시작해요. 오면 꼭 대진판에서 <K>도착</K>을 눌러 주세요.</>,
            <><b>알림</b>: 내 코트의 앞 경기가 시작되면 코트 대기 알림(예: 코트 2 다음 경기)이, 내 경기가 시작되면 코트 배정 알림이 와요.</>,
            <><b>점수 입력</b>: 경기를 마치면 대진판의 <K>경기 종료 · 점수</K>를 눌러 점수를 넣어요. 그 경기에 뛴 사람이면 누구나 넣을 수 있고, 목표 점수·듀스 규칙에 안 맞으면 저장되지 않아요. 나중에 넣거나 고칠 때는 대진표에서 그 경기를 눌러요.</>,
          ]}
        />
        <Note>대회가 진행되는 동안에는 대진판에서 경기를 새로 만들 수 없어요. 못 나오게 되면 바로 참석 취소하고 운영진에게 알려 주세요. 운영진이 다른 사람으로 바꿔야 해요.</Note>
      </Section>

      <section id="faq" className="scroll-mt-4">
        <h2 className="mb-1.5 mt-8 px-1 text-[18px] font-bold text-ink">자주 묻는 질문</h2>
        <div className="divide-y divide-black/[0.06] overflow-hidden rounded-2xl border border-black/[0.06] bg-white">
          {FAQ.map(([q, a]) => (
            <details key={q} className="group">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3.5 text-[15px] font-semibold text-ink active:bg-floor [&::-webkit-details-marker]:hidden">
                {q}
                <IconChevronDown className="h-4 w-4 shrink-0 text-ink-faint transition-transform group-open:rotate-180" />
              </summary>
              <p className="px-4 pb-4 text-[15px] leading-relaxed text-ink-soft">{a}</p>
            </details>
          ))}
        </div>
      </section>
    </Page>
  )
}
