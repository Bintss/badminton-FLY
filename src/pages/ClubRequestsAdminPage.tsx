import { useCallback, useEffect, useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { ClubLogo } from '../components/ClubLogo'
import { Input } from '../components/form'
import { IconChevronLeft } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
import { DEFAULT_TZ, formatDateTime } from '../lib/datetime'
import { LOGO_BUCKET } from '../lib/clubLogo'
import { getLastClubId, setLastClubId } from '../lib/lastClub'
import { errorMessage, supabase } from '../lib/supabase'
import { CLUB_COLUMNS, type Club, type ClubRequest } from '../lib/types'

const STATUS_LABEL: Record<ClubRequest['status'], string> = {
  pending: '대기',
  approved: '승인',
  rejected: '거절',
  canceled: '신청 취소',
}

/** 서비스 관리자: 동아리 개설 신청 승인·거절, 전체 동아리 삭제 */
export default function ClubRequestsAdminPage() {
  const toast = useToast()
  const [allowed, setAllowed] = useState<boolean | null>(null)
  const [items, setItems] = useState<ClubRequest[] | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [rejecting, setRejecting] = useState<string | null>(null)
  const [reason, setReason] = useState('')
  const [clubs, setClubs] = useState<Club[]>([])
  const [deleting, setDeleting] = useState<string | null>(null)
  const [confirm, setConfirm] = useState('')

  const load = useCallback(async () => {
    const { data: pa } = await supabase.rpc('is_platform_admin')
    setAllowed(pa === true)
    if (pa !== true) return
    const [req, cl] = await Promise.all([
      supabase.from('club_requests').select('*').order('created_at', { ascending: false }).limit(60),
      supabase.from('clubs').select(CLUB_COLUMNS).order('created_at', { ascending: false }),
    ])
    if (req.error || cl.error) toast.error(errorMessage(req.error ?? cl.error))
    setItems((req.data as ClubRequest[] | null) ?? [])
    setClubs((cl.data as Club[] | null) ?? [])
  }, [toast])

  useEffect(() => {
    void load()
  }, [load])

  const decide = async (r: ClubRequest, approve: boolean) => {
    setBusy(r.id)
    const { error } = await supabase.rpc('decide_club_request', { p_id: r.id, p_approve: approve, p_reason: approve ? null : reason.trim() || null })
    setBusy(null)
    if (error) toast.error(errorMessage(error))
    else toast.success(approve ? `'${r.name}' 동아리를 만들었어요. ${r.requester_name}님이 운영진이에요` : `'${r.name}' 신청을 거절했어요`)
    setRejecting(null)
    setReason('')
    await load()
  }

  const removeClub = async (c: Club) => {
    setBusy(c.id)
    // Storage 정책이 권한을 보므로 동아리를 지우기 전에 로고부터 (실패해도 동아리 삭제는 진행)
    const { data: files } = await supabase.storage.from(LOGO_BUCKET).list(c.id)
    if (files && files.length > 0) await supabase.storage.from(LOGO_BUCKET).remove(files.map((f) => `${c.id}/${f.name}`))
    const { error } = await supabase.rpc('delete_club', { p_club: c.id, p_confirm_name: confirm })
    setBusy(null)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    if (getLastClubId() === c.id) setLastClubId(null)
    toast.success(`${c.name}을(를) 삭제했어요`)
    setDeleting(null)
    setConfirm('')
    await load()
  }

  const back = (
    <Link to="/clubs" className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      동아리
    </Link>
  )

  if (allowed === false) return <Navigate to="/clubs" replace />
  if (!items) return <Page title="서비스 관리" back={back}><ListSkeleton rows={2} /></Page>

  const pending = items.filter((r) => r.status === 'pending')
  const done = items.filter((r) => r.status !== 'pending')

  return (
    <Page title="서비스 관리" back={back}>
      <SectionTitle>개설 신청</SectionTitle>
      <p className="mb-3 text-sm leading-relaxed text-ink-soft">승인하면 동아리가 바로 만들어지고, 신청한 사람이 첫 운영진이 돼요. 결과는 신청자에게 알림으로 가요.</p>

      {pending.length === 0 ? (
        <Empty title="기다리는 신청이 없어요" />
      ) : (
        <div className="space-y-2.5">
          {pending.map((r) => (
            <Card key={r.id}>
              <p className="text-[17px] font-bold text-ink">{r.name}</p>
              <p className="mt-0.5 text-sm text-ink-soft">
                {r.requester_name}님, {formatDateTime(r.created_at, DEFAULT_TZ)}
              </p>
              {r.note && <p className="mt-2 whitespace-pre-line rounded-lg bg-floor px-3 py-2 text-sm text-ink">{r.note}</p>}

              {rejecting === r.id ? (
                <div className="mt-3 space-y-2">
                  <Input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} placeholder="거절 이유 (선택, 신청자에게 보여요)" aria-label="거절 이유" className="!mt-0" />
                  <div className="flex gap-2">
                    <Button variant="secondary" className="flex-1" onClick={() => setRejecting(null)}>
                      돌아가기
                    </Button>
                    <Button variant="danger" className="flex-1" disabled={busy === r.id} onClick={() => void decide(r, false)}>
                      거절하기
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="mt-3 flex gap-2">
                  <Button variant="secondary" className="flex-1" disabled={busy === r.id} onClick={() => { setRejecting(r.id); setReason('') }}>
                    거절
                  </Button>
                  <Button className="flex-1" disabled={busy === r.id} onClick={() => void decide(r, true)}>
                    승인
                  </Button>
                </div>
              )}
            </Card>
          ))}
        </div>
      )}

      {done.length > 0 && (
        <>
          <SectionTitle>처리한 신청</SectionTitle>
          <List>
            {done.map((r) => (
              <div key={r.id} className="flex items-center gap-3 px-4 py-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium text-ink">{r.name}</p>
                  <p className="truncate text-xs text-ink-faint">
                    {r.requester_name}님{r.reason ? `, ${r.reason}` : ''}
                  </p>
                </div>
                {r.status === 'approved' && r.club_id ? (
                  <Badge tone="court">{STATUS_LABEL[r.status]}</Badge>
                ) : (
                  <Badge>{STATUS_LABEL[r.status]}</Badge>
                )}
              </div>
            ))}
          </List>
        </>
      )}

      <SectionTitle right={`${clubs.length}개`}>전체 동아리</SectionTitle>
      <List>
        {clubs.map((c) => (
          <div key={c.id} className="px-4 py-3">
            <div className="flex items-center gap-3">
              <ClubLogo club={c} size={40} />
              <div className="min-w-0 flex-1">
                <p className="truncate font-semibold text-ink">{c.name}</p>
                <p className="text-xs text-ink-faint">{formatDateTime(c.created_at, DEFAULT_TZ)} 만듦</p>
              </div>
              {deleting !== c.id && (
                <Button variant="ghost" className="h-10 shrink-0 text-danger" onClick={() => { setDeleting(c.id); setConfirm('') }}>
                  삭제
                </Button>
              )}
            </div>
            {deleting === c.id && (
              <div className="mt-3 space-y-2 rounded-xl bg-floor p-3">
                <p className="text-sm leading-relaxed text-ink-soft">
                  운동 일정, 참석 신청, 경기·대회 기록, 회원 명단이 모두 지워지고 되돌릴 수 없어요. 그 동아리 운영진에게는 삭제 알림이 가요.
                </p>
                <Input
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  autoComplete="off"
                  placeholder={c.name}
                  aria-label={`확인을 위해 동아리 이름 ${c.name} 입력`}
                  className="!mt-0"
                />
                <p className="text-xs text-ink-faint">확인을 위해 동아리 이름을 그대로 입력하세요.</p>
                <div className="flex gap-2">
                  <Button variant="secondary" onClick={() => setDeleting(null)}>
                    그만두기
                  </Button>
                  <Button variant="danger" className="flex-1" disabled={busy === c.id || confirm !== c.name} onClick={() => void removeClub(c)}>
                    영구 삭제
                  </Button>
                </div>
              </div>
            )}
          </div>
        ))}
      </List>
    </Page>
  )
}
