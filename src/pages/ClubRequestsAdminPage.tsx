import { useCallback, useEffect, useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { Input } from '../components/form'
import { IconChevronLeft } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
import { DEFAULT_TZ, formatDateTime } from '../lib/datetime'
import { errorMessage, supabase } from '../lib/supabase'
import type { ClubRequest } from '../lib/types'

const STATUS_LABEL: Record<ClubRequest['status'], string> = {
  pending: '대기',
  approved: '승인',
  rejected: '거절',
  canceled: '신청 취소',
}

/** 서비스 관리자: 동아리 개설 신청 승인·거절 */
export default function ClubRequestsAdminPage() {
  const toast = useToast()
  const [allowed, setAllowed] = useState<boolean | null>(null)
  const [items, setItems] = useState<ClubRequest[] | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [rejecting, setRejecting] = useState<string | null>(null)
  const [reason, setReason] = useState('')

  const load = useCallback(async () => {
    const { data: pa } = await supabase.rpc('is_platform_admin')
    setAllowed(pa === true)
    if (pa !== true) return
    const { data, error } = await supabase.from('club_requests').select('*').order('created_at', { ascending: false }).limit(60)
    if (error) toast.error(errorMessage(error))
    setItems((data as ClubRequest[] | null) ?? [])
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

  const back = (
    <Link to="/clubs" className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      동아리
    </Link>
  )

  if (allowed === false) return <Navigate to="/clubs" replace />
  if (!items) return <Page title="개설 신청" back={back}><ListSkeleton rows={2} /></Page>

  const pending = items.filter((r) => r.status === 'pending')
  const done = items.filter((r) => r.status !== 'pending')

  return (
    <Page title="개설 신청" back={back}>
      <p className="mb-4 text-sm leading-relaxed text-ink-soft">승인하면 동아리가 바로 만들어지고, 신청한 사람이 첫 운영진이 돼요. 결과는 신청자에게 알림으로 가요.</p>

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
    </Page>
  )
}
