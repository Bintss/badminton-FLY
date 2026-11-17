import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Field, Input, Segmented } from '../components/form'
import { IconChevronLeft } from '../components/icons'
import { useToast } from '../components/toast'
import { Button, Card, ErrorText, Page } from '../components/ui'
import { DEFAULT_TZ, toDateInput, zonedToIso } from '../lib/datetime'
import { serverNow } from '../lib/serverTime'
import { errorMessage, supabase } from '../lib/supabase'

export default function FlashNewPage() {
  const { club } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const navigate = useNavigate()
  const toast = useToast()

  const [title, setTitle] = useState('번개')
  const [date, setDate] = useState(() => toDateInput(serverNow(), tz))
  const [start, setStart] = useState('19:00')
  const [end, setEnd] = useState('21:00')
  const [place, setPlace] = useState('')
  const [capacity, setCapacity] = useState(12)
  const [courts, setCourts] = useState(2)
  const [openNow, setOpenNow] = useState(true)
  const [openDate, setOpenDate] = useState(() => toDateInput(serverNow(), tz))
  const [openTime, setOpenTime] = useState('21:00')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

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
    const { data, error } = await supabase.rpc('create_flash', {
      p_club: club.id,
      p_title: title.trim() || '번개',
      p_place: place,
      p_starts_at: startsAt,
      p_ends_at: endsAt,
      p_capacity: capacity,
      p_court_count: courts,
      p_opens_at: opensAt,
    })
    setBusy(false)
    if (error || !data) {
      setError(errorMessage(error))
      return
    }
    toast.success(openNow ? '번개를 열었어요. 지금부터 신청할 수 있어요' : '번개를 만들었어요. 예약한 시각에 투표가 열려요')
    navigate(`/c/${club.id}/s/${data as string}`)
  }

  return (
    <Page
      title="번개 만들기"
      back={
        <Link to={`/c/${club.id}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
          <IconChevronLeft className="h-4 w-4" />
          일정
        </Link>
      }
    >
      <Card>
        <form onSubmit={submit} className="space-y-4">
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
          <Field label="장소">
            <Input value={place} onChange={(e) => setPlace(e.target.value)} placeholder="예: 학교 체육관" />
          </Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="정원">
              <Input type="number" min={1} max={200} value={capacity} onChange={(e) => setCapacity(Number(e.target.value))} required />
            </Field>
            <Field label="코트 수">
              <Input type="number" min={1} max={30} value={courts} onChange={(e) => setCourts(Number(e.target.value))} required />
            </Field>
          </div>

          <div>
            <span className="text-[13px] font-semibold text-ink-soft">투표 오픈</span>
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

          <Button type="submit" className="h-14 w-full text-[16px]" disabled={busy}>
            {openNow ? '번개 열기' : '번개 만들기'}
          </Button>
          <ErrorText>{error}</ErrorText>
        </form>
      </Card>
    </Page>
  )
}
