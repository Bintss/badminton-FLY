import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Field, Input, Segmented } from '../components/form'
import { IconChevronLeft } from '../components/icons'
import { GuestCapacityField } from '../components/GuestCapacityField'
import { PlaceInput } from '../components/PlaceInput'
import { ScoreCapField } from '../components/ScoreCapField'
import { useToast } from '../components/toast'
import { Button, Card, Empty, ErrorText, Page } from '../components/ui'
import { DEFAULT_TZ, toDateInput, zonedToIso } from '../lib/datetime'
import { serverNow } from '../lib/serverTime'
import { errorMessage, supabase } from '../lib/supabase'
import { planEstimate } from '../lib/tournament'

/**
 * 대회 만들기 (운영진): 운동 정보 + 대회 설정을 한 번에. 참석은 선착순 투표로 받는다
 *   자체대회 = 우리 동아리끼리, 교류전 = 다른 동아리를 초대 (상대 운영진이 수락해야 상대 회원이 신청)
 */
export default function TournamentNewPage() {
  const { club, isAdmin } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const navigate = useNavigate()
  const toast = useToast()

  const [kind, setKind] = useState<'tournament' | 'exchange'>('tournament')
  const [title, setTitle] = useState('자체대회')
  const [partner, setPartner] = useState<{ id: string; name: string } | null>(null)
  const [partnerQuery, setPartnerQuery] = useState('')
  const [partnerHits, setPartnerHits] = useState<{ id: string; name: string }[]>([])
  const [partnerCapacity, setPartnerCapacity] = useState(15)
  const [date, setDate] = useState(() => toDateInput(serverNow() + 7 * 86400000, tz))
  const [start, setStart] = useState('13:00')
  const [end, setEnd] = useState('17:00')
  const [place, setPlace] = useState('')
  const [capacity, setCapacity] = useState(30)
  const [courts, setCourts] = useState(6)
  const [guestsIn, setGuestsIn] = useState(false)
  const [openNow, setOpenNow] = useState(true)
  const [openDate, setOpenDate] = useState(() => toDateInput(serverNow(), tz))
  const [openTime, setOpenTime] = useState('21:00')
  const [rounds, setRounds] = useState('5')
  const [target, setTarget] = useState('25')
  const [capOn, setCapOn] = useState(true)
  const [cap, setCap] = useState('30')
  const [minutes, setMinutes] = useState('15')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const exchange = kind === 'exchange'
  const switchKind = (k: 'tournament' | 'exchange') => {
    setKind(k)
    // 제목을 안 바꿨으면 종류에 맞게
    if (title === '자체대회' || title === '교류전') setTitle(k === 'exchange' ? '교류전' : '자체대회')
    if (k === 'exchange' && capacity === 30) setCapacity(15)
  }

  // 상대 동아리 찾기: 이름 일부로 10개까지 (우리 동아리 제외)
  useEffect(() => {
    if (!exchange || partner) return
    const q = partnerQuery.trim().replace(/[%_,()*\\]/g, '')
    if (!q) {
      setPartnerHits([])
      return
    }
    let stale = false
    const t = setTimeout(async () => {
      const { data } = await supabase.from('clubs').select('id, name').neq('id', club.id).ilike('name', `%${q}%`).order('name').limit(10)
      if (!stale) setPartnerHits((data ?? []) as { id: string; name: string }[])
    }, 250)
    return () => {
      stale = true
      clearTimeout(t)
    }
  }, [exchange, partner, partnerQuery, club.id])

  const n = (v: string) => Number.parseInt(v, 10)
  const total = exchange ? (capacity || 0) + (partnerCapacity || 0) : capacity || 0
  const est = planEstimate(total, courts || 0, n(rounds) || 0, n(minutes) || 0)
  const label = exchange ? '교류전' : '자체대회'

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setError('')
    const startsAt = zonedToIso(date, start, tz)
    const endsAt = zonedToIso(date, end, tz)
    const opensAt = openNow ? null : zonedToIso(openDate, openTime, tz)
    if (Date.parse(endsAt) <= Date.parse(startsAt)) {
      setError('끝나는 시각이 시작보다 늦어야 해요.')
      return
    }
    if (exchange && !partner) {
      setError('초대할 동아리를 골라주세요.')
      return
    }
    setBusy(true)
    const common = {
      p_club: club.id,
      p_title: title.trim() || label,
      p_place: place,
      p_starts_at: startsAt,
      p_ends_at: endsAt,
      p_capacity: capacity,
      p_court_count: courts,
      p_opens_at: opensAt,
      p_round_count: n(rounds),
      p_score_target: n(target),
      p_score_cap: capOn ? n(cap) : null,
      p_minutes_per_game: n(minutes),
      p_guests_in_capacity: guestsIn,
    }
    const { data, error } = exchange
      ? await supabase.rpc('create_exchange', { ...common, p_partner: partner!.id, p_partner_capacity: partnerCapacity })
      : await supabase.rpc('create_tournament', common)
    setBusy(false)
    if (error || !data) {
      setError(errorMessage(error))
      return
    }
    toast.success(
      exchange
        ? `교류전을 만들고 ${partner!.name}에 초대를 보냈어요. 상대 운영진이 수락하면 그 동아리 회원도 신청할 수 있어요`
        : openNow
          ? '자체대회를 만들었어요. 지금부터 참석 신청을 받아요'
          : '자체대회를 만들었어요. 예약한 시각에 투표가 열려요',
    )
    navigate(`/c/${club.id}/s/${data as string}`)
  }

  const back = (
    <Link to={`/c/${club.id}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      일정
    </Link>
  )

  if (!isAdmin) {
    return (
      <Page title="대회 만들기" back={back}>
        <Empty title="운영진만 대회를 만들 수 있어요" />
      </Page>
    )
  }

  return (
    <Page title="대회 만들기" back={back}>
      <form onSubmit={submit} className="space-y-4">
        <Segmented
          value={kind}
          options={[
            { value: 'tournament', label: '자체대회' },
            { value: 'exchange', label: '교류전' },
          ]}
          onChange={(v) => switchKind(v as 'tournament' | 'exchange')}
        />

        {exchange && (
          <Card>
            <h2 className="text-[15px] font-bold text-ink">상대 동아리</h2>
            <p className="mt-1 text-[13px] leading-relaxed text-ink-soft">
              초대를 받은 동아리 운영진이 수락하면 그 동아리 회원도 신청할 수 있어요. 경기는 모두 우리 2명 vs 상대 2명이고, 대진은 우리 운영진이 짜요.
            </p>
            {partner ? (
              <div className="mt-3 flex items-center justify-between gap-2 rounded-xl bg-court-50 px-3 py-2.5">
                <span className="min-w-0 truncate font-semibold text-court-700">{partner.name}</span>
                <button type="button" className="shrink-0 text-sm font-semibold text-ink-soft" onClick={() => setPartner(null)}>
                  바꾸기
                </button>
              </div>
            ) : (
              <>
                <Input
                  type="search"
                  value={partnerQuery}
                  onChange={(e) => setPartnerQuery(e.target.value)}
                  placeholder="동아리 이름으로 찾기"
                  aria-label="초대할 동아리 찾기"
                  className="mt-3"
                />
                {partnerHits.length > 0 && (
                  <div className="mt-2 divide-y divide-black/[0.06] overflow-hidden rounded-xl ring-1 ring-black/[0.06]">
                    {partnerHits.map((c) => (
                      <button key={c.id} type="button" onClick={() => setPartner(c)} className="block w-full px-3 py-3 text-left text-[15px] font-semibold text-ink active:bg-floor">
                        {c.name}
                      </button>
                    ))}
                  </div>
                )}
                {partnerQuery.trim() && partnerHits.length === 0 && <p className="mt-2 text-sm text-ink-faint">찾는 동아리가 없어요</p>}
              </>
            )}
          </Card>
        )}

        <Card>
          <h2 className="mb-3 text-[15px] font-bold text-ink">운동</h2>
          <div className="space-y-4">
            <Field label="제목">
              <Input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={50} />
            </Field>
            <Field label="날짜">
              <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="시작">
                <Input type="time" value={start} onChange={(e) => setStart(e.target.value)} required />
              </Field>
              <Field label="끝">
                <Input type="time" value={end} onChange={(e) => setEnd(e.target.value)} required />
              </Field>
            </div>
            <Field label="장소" asGroup>
              <PlaceInput clubId={club.id} value={place} onChange={setPlace} />
            </Field>
            {exchange ? (
              <div className="grid grid-cols-3 gap-3">
                <Field label="우리 정원">
                  <Input type="number" min={2} max={200} value={capacity} onChange={(e) => setCapacity(Number(e.target.value))} required />
                </Field>
                <Field label="상대 정원">
                  <Input type="number" min={2} max={200} value={partnerCapacity} onChange={(e) => setPartnerCapacity(Number(e.target.value))} required />
                </Field>
                <Field label="코트 수">
                  <Input type="number" min={1} max={30} value={courts} onChange={(e) => setCourts(Number(e.target.value))} required />
                </Field>
              </div>
            ) : (
              <div className="grid grid-cols-2 gap-3">
                <Field label="정원">
                  <Input type="number" min={4} max={200} value={capacity} onChange={(e) => setCapacity(Number(e.target.value))} required />
                </Field>
                <Field label="코트 수">
                  <Input type="number" min={1} max={30} value={courts} onChange={(e) => setCourts(Number(e.target.value))} required />
                </Field>
              </div>
            )}
            <GuestCapacityField checked={guestsIn} onChange={setGuestsIn} />
            <div>
              <span className="text-[13px] font-semibold text-ink-soft">참석 투표 오픈</span>
              <Segmented
                value={openNow ? 'now' : 'later'}
                options={[
                  { value: 'now', label: '지금 바로' },
                  { value: 'later', label: '시각 예약' },
                ]}
                onChange={(v) => setOpenNow(v === 'now')}
              />
              {!openNow && (
                <div className="mt-2 grid grid-cols-2 gap-2">
                  <Input type="date" value={openDate} onChange={(e) => setOpenDate(e.target.value)} required aria-label="오픈 날짜" />
                  <Input type="time" value={openTime} onChange={(e) => setOpenTime(e.target.value)} required aria-label="오픈 시각" />
                </div>
              )}
            </div>
          </div>
        </Card>

        <Card>
          <h2 className="mb-3 text-[15px] font-bold text-ink">대회</h2>
          <div className="grid grid-cols-2 gap-3">
            <Field label="매치 수">
              <Input type="number" inputMode="numeric" min={1} max={20} value={rounds} onChange={(e) => setRounds(e.target.value)} required />
            </Field>
            <Field label="경기당 시간 (분)">
              <Input type="number" inputMode="numeric" min={5} max={60} value={minutes} onChange={(e) => setMinutes(e.target.value)} required />
            </Field>
            <Field label="목표 점수">
              <Input type="number" inputMode="numeric" min={5} max={50} value={target} onChange={(e) => setTarget(e.target.value)} required />
            </Field>
            <ScoreCapField capOn={capOn} setCapOn={setCapOn} cap={cap} setCap={setCap} />
          </div>
          <p className="mt-4 rounded-xl bg-floor px-3 py-2.5 text-[13px] leading-relaxed text-ink-soft">
            정원 {total}명이 다 차면 매치마다 {est.perRound}경기{est.restPerRound > 0 && `(${est.restPerRound}명 휴식)`}, {n(rounds) || 0}매치에 모두{' '}
            {est.games}경기예요. 한 사람당 평균 {est.avgPerPlayer.toFixed(1)}게임, 약 {est.minutes}분 걸려요. 대진은 참석자가 정해진 뒤 자동으로 짜고 고칠 수 있어요.
          </p>
        </Card>

        <Button type="submit" className="h-14 w-full text-[16px]" disabled={busy}>
          {exchange ? '교류전 만들고 초대하기' : '자체대회 만들기'}
        </Button>
        <ErrorText>{error}</ErrorText>
      </form>
    </Page>
  )
}
