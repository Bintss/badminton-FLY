import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Field, Input, Segmented } from '../components/form'
import { IconChevronLeft } from '../components/icons'
import { PlaceInput } from '../components/PlaceInput'
import { ScoreCapField } from '../components/ScoreCapField'
import { useToast } from '../components/toast'
import { Button, Card, Empty, ErrorText, Page } from '../components/ui'
import { DEFAULT_TZ, toDateInput, zonedToIso } from '../lib/datetime'
import { serverNow } from '../lib/serverTime'
import { errorMessage, supabase } from '../lib/supabase'
import { planEstimate } from '../lib/tournament'

/** 자체대회 만들기 (운영진): 운동 정보 + 대회 설정을 한 번에. 참석은 선착순 투표로 받는다 */
export default function TournamentNewPage() {
  const { club, isAdmin } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const navigate = useNavigate()
  const toast = useToast()

  const [title, setTitle] = useState('자체대회')
  const [date, setDate] = useState(() => toDateInput(serverNow() + 7 * 86400000, tz))
  const [start, setStart] = useState('13:00')
  const [end, setEnd] = useState('17:00')
  const [place, setPlace] = useState('')
  const [capacity, setCapacity] = useState(30)
  const [courts, setCourts] = useState(6)
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

  const n = (v: string) => Number.parseInt(v, 10)
  const est = planEstimate(capacity || 0, courts || 0, n(rounds) || 0, n(minutes) || 0)

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
    setBusy(true)
    const { data, error } = await supabase.rpc('create_tournament', {
      p_club: club.id,
      p_title: title.trim() || '자체대회',
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
    })
    setBusy(false)
    if (error || !data) {
      setError(errorMessage(error))
      return
    }
    toast.success(openNow ? '자체대회를 만들었어요. 지금부터 참석 신청을 받아요' : '자체대회를 만들었어요. 예약한 시각에 투표가 열려요')
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
      <Page title="자체대회 만들기" back={back}>
        <Empty title="운영진만 자체대회를 만들 수 있어요" />
      </Page>
    )
  }

  return (
    <Page title="자체대회 만들기" back={back}>
      <form onSubmit={submit} className="space-y-4">
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
            <div className="grid grid-cols-2 gap-3">
              <Field label="정원">
                <Input type="number" min={4} max={200} value={capacity} onChange={(e) => setCapacity(Number(e.target.value))} required />
              </Field>
              <Field label="코트 수">
                <Input type="number" min={1} max={30} value={courts} onChange={(e) => setCourts(Number(e.target.value))} required />
              </Field>
            </div>
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
            정원 {capacity || 0}명이 다 차면 매치마다 {est.perRound}경기{est.restPerRound > 0 && `(${est.restPerRound}명 휴식)`}, {n(rounds) || 0}매치에 모두{' '}
            {est.games}경기예요. 한 사람당 평균 {est.avgPerPlayer.toFixed(1)}게임, 약 {est.minutes}분 걸려요. 대진은 참석자가 정해진 뒤 자동으로 짜고 고칠 수 있어요.
          </p>
        </Card>

        <Button type="submit" className="h-14 w-full text-[16px]" disabled={busy}>
          자체대회 만들기
        </Button>
        <ErrorText>{error}</ErrorText>
      </form>
    </Page>
  )
}
