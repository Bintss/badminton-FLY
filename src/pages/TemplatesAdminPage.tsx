import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Field, Input, Select } from '../components/form'
import { GuestCapacityField } from '../components/GuestCapacityField'
import { PlaceInput } from '../components/PlaceInput'
import { IconChevronLeft, IconPlus } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, ErrorText, ListSkeleton, Page } from '../components/ui'
import { trimSeconds, WEEKDAYS } from '../lib/datetime'
import { errorMessage, supabase } from '../lib/supabase'
import type { SessionTemplate } from '../lib/types'

type Draft = Omit<SessionTemplate, 'id' | 'club_id'> & { id: string | null }

const EMPTY: Draft = {
  id: null,
  title: '정기운동',
  weekday: 3,
  start_time: '19:00',
  end_time: '22:00',
  place: '',
  capacity: 30,
  court_count: 5,
  open_days_before: 3,
  open_time: '21:00',
  active: true,
  guests_in_capacity: false,
}

function openRuleText(t: Pick<SessionTemplate, 'weekday' | 'open_days_before' | 'open_time'>) {
  const wd = WEEKDAYS[(((t.weekday - t.open_days_before) % 7) + 7) % 7]
  const when = t.open_days_before === 0 ? '당일' : `${t.open_days_before}일 전(${wd})`
  return `${when} ${trimSeconds(t.open_time)} 투표 오픈`
}

export default function TemplatesAdminPage() {
  const { club, isAdmin } = useClub()
  const [templates, setTemplates] = useState<SessionTemplate[] | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('session_templates')
      .select('*')
      .eq('club_id', club.id)
      .order('weekday')
      .order('start_time')
    if (error) setError(errorMessage(error))
    else setTemplates(data as SessionTemplate[])
  }, [club.id])

  useEffect(() => {
    void load()
  }, [load])

  if (!isAdmin) return <Navigate to={`/c/${club.id}`} replace />

  const set = <K extends keyof Draft>(key: K, value: Draft[K]) => setDraft((d) => (d ? { ...d, [key]: value } : d))

  const save = async (e: FormEvent) => {
    e.preventDefault()
    if (!draft) return
    setBusy(true)
    setError('')
    const { error } = await supabase.rpc('save_template', {
      p_club: club.id,
      p_id: draft.id,
      p_title: draft.title.trim() || '정기운동',
      p_weekday: draft.weekday,
      p_start_time: draft.start_time,
      p_end_time: draft.end_time,
      p_place: draft.place,
      p_capacity: draft.capacity,
      p_court_count: draft.court_count,
      p_open_days_before: draft.open_days_before,
      p_open_time: draft.open_time,
      p_active: draft.active,
      p_guests_in_capacity: draft.guests_in_capacity,
    })
    setBusy(false)
    if (error) {
      setError(errorMessage(error))
      return
    }
    toast.success(draft.id ? '정기운동을 수정했어요. 다음에 만들어지는 일정부터 적용돼요' : '정기운동을 등록했어요')
    setDraft(null)
    await load()
  }

  const back = (
    <Link to={`/c/${club.id}/me`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      내 정보
    </Link>
  )

  if (!templates) return <Page title="정기운동 관리" back={back}><ListSkeleton rows={2} /><ErrorText>{error}</ErrorText></Page>

  return (
    <Page
      title="정기운동 관리"
      back={back}
      action={
        !draft && (
          <Button className="h-10 pl-2.5 pr-3.5" onClick={() => setDraft({ ...EMPTY })}>
            <IconPlus className="h-4 w-4" />
            추가
          </Button>
        )
      }
    >
      <p className="mb-4 text-sm leading-relaxed text-ink-soft">
        등록한 요일마다 운동 일정이 자동으로 만들어지고, 투표 오픈 7일 전부터 홈에 보여요. 수정 내용은 이후에 만들어지는 일정부터 적용돼요.
      </p>
      <ErrorText>{error}</ErrorText>

      {draft && (
        <Card className="mb-4">
          <form onSubmit={save} className="space-y-4">
            <Field label="이름">
              <Input value={draft.title} onChange={(e) => set('title', e.target.value)} maxLength={50} />
            </Field>
            <Field label="요일">
              <Select value={draft.weekday} onChange={(e) => set('weekday', Number(e.target.value))}>
                {WEEKDAYS.map((w, i) => (
                  <option key={w} value={i}>
                    {w}요일
                  </option>
                ))}
              </Select>
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="시작">
                <Input type="time" value={trimSeconds(draft.start_time)} onChange={(e) => set('start_time', e.target.value)} required />
              </Field>
              <Field label="끝">
                <Input type="time" value={trimSeconds(draft.end_time)} onChange={(e) => set('end_time', e.target.value)} required />
              </Field>
            </div>
            <Field label="장소" asGroup>
              <PlaceInput clubId={club.id} value={draft.place} onChange={(v) => set('place', v)} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="정원">
                <Input type="number" min={1} max={200} value={draft.capacity} onChange={(e) => set('capacity', Number(e.target.value))} required />
              </Field>
              <Field label="코트 수">
                <Input type="number" min={1} max={30} value={draft.court_count} onChange={(e) => set('court_count', Number(e.target.value))} required />
              </Field>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Field label="투표 오픈 (며칠 전)">
                <Input type="number" min={0} max={30} value={draft.open_days_before} onChange={(e) => set('open_days_before', Number(e.target.value))} required />
              </Field>
              <Field label="오픈 시각">
                <Input type="time" value={trimSeconds(draft.open_time)} onChange={(e) => set('open_time', e.target.value)} required />
              </Field>
            </div>
            <p className="rounded-lg bg-court-50 px-3 py-2 text-sm font-medium text-court-700">{openRuleText(draft)}</p>
            <GuestCapacityField checked={draft.guests_in_capacity} onChange={(v) => set('guests_in_capacity', v)} />
            <label className="flex items-center gap-2 text-sm text-ink">
              <input type="checkbox" checked={draft.active} onChange={(e) => set('active', e.target.checked)} className="h-5 w-5 accent-court-600" />
              사용 (끄면 새 일정이 만들어지지 않아요)
            </label>
            <div className="flex gap-2">
              <Button type="button" variant="secondary" className="flex-1" onClick={() => setDraft(null)}>
                취소
              </Button>
              <Button type="submit" className="flex-1" disabled={busy}>
                저장
              </Button>
            </div>
          </form>
        </Card>
      )}

      {templates.length === 0 && !draft && <Empty title="등록된 정기운동이 없어요">오른쪽 위 추가 버튼으로 매주 하는 운동을 등록하세요.</Empty>}
      <div className="space-y-2">
        {templates.map((t) => (
          <Card key={t.id} className={t.active ? '' : 'opacity-50'}>
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="flex items-center gap-1.5">
                  <span className="font-semibold text-ink">{t.title}</span>
                  {!t.active && <Badge>꺼짐</Badge>}
                </div>
                <p className="mt-1 text-sm text-ink">
                  매주 {WEEKDAYS[t.weekday]}요일 {trimSeconds(t.start_time)}~{trimSeconds(t.end_time)}
                </p>
                <p className="text-sm text-ink-soft">
                  {t.place || '장소 미정'} · 정원 {t.capacity}{t.guests_in_capacity ? '(게스트 포함)' : ''} · 코트 {t.court_count}면
                </p>
                <p className="text-sm text-ink-soft">{openRuleText(t)}</p>
              </div>
              <button className="shrink-0 rounded-lg px-2 py-1 text-sm font-semibold text-court-600 active:bg-court-50" onClick={() => setDraft({ ...t })}>
                수정
              </button>
            </div>
          </Card>
        ))}
      </div>
    </Page>
  )
}
