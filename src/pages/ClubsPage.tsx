import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { Field, Input, Textarea } from '../components/form'
import { IconChevronRight } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'
import { linkLabel } from '../lib/clubLogo'
import { CLUB_COLUMNS, type Club, type ClubPlace, type ClubRequest, type MembershipWithClub } from '../lib/types'
import { ClubLogo } from '../components/ClubLogo'

export default function ClubsPage() {
  const { session, signOut } = useAuth()
  const navigate = useNavigate()
  const toast = useToast()
  const [memberships, setMemberships] = useState<MembershipWithClub[] | null>(null)
  const [clubs, setClubs] = useState<Club[]>([])
  const [places, setPlaces] = useState<ClubPlace[]>([])
  const [expanded, setExpanded] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [newName, setNewName] = useState('')
  const [newNote, setNewNote] = useState('')
  const [platformAdmin, setPlatformAdmin] = useState(false)
  const [myRequest, setMyRequest] = useState<ClubRequest | null>(null)
  const [pendingCount, setPendingCount] = useState(0)

  const uid = session?.user.id

  const load = useCallback(async () => {
    if (!uid) return
    const [mine, all, pl, pa, req] = await Promise.all([
      supabase.from('club_members').select('*, clubs(id, name, logo_path)').eq('user_id', uid).order('requested_at'),
      supabase.from('clubs').select(CLUB_COLUMNS).order('name'),
      supabase.from('club_places').select('*').order('sort'),
      supabase.rpc('is_platform_admin'),
      supabase.from('club_requests').select('*').eq('requested_by', uid).order('created_at', { ascending: false }).limit(1),
    ])
    setPlaces((pl.data as ClubPlace[] | null) ?? [])
    const isPa = pa.data === true
    setPlatformAdmin(isPa)
    setMyRequest(((req.data as ClubRequest[] | null) ?? [])[0] ?? null)
    if (isPa) {
      const { count } = await supabase.from('club_requests').select('id', { count: 'exact', head: true }).eq('status', 'pending')
      setPendingCount(count ?? 0)
    }
    if (mine.error || all.error) {
      toast.error(errorMessage(mine.error ?? all.error))
      return
    }
    setMemberships(mine.data as MembershipWithClub[])
    setClubs(all.data as Club[])
  }, [uid, toast])

  useEffect(() => {
    void load()
  }, [load])

  const requestJoin = async (clubId: string) => {
    setBusyId(clubId)
    const { error } = await supabase.rpc('request_join', { p_club: clubId })
    if (error) toast.error(errorMessage(error))
    else toast.success('가입을 신청했어요. 운영진이 승인하면 들어갈 수 있어요.')
    await load()
    setBusyId(null)
  }

  const createClub = async (e: FormEvent) => {
    e.preventDefault()
    if (!newName.trim()) return
    setBusyId('new')
    const { data, error } = await supabase.rpc('create_club', { p_name: newName.trim() })
    setBusyId(null)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    toast.success('동아리를 만들었어요')
    navigate(`/c/${data as string}`)
  }

  const requestClub = async (e: FormEvent) => {
    e.preventDefault()
    if (!newName.trim()) return
    setBusyId('new')
    const { error } = await supabase.rpc('request_club', { p_name: newName.trim(), p_note: newNote.trim() })
    setBusyId(null)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    toast.success('개설을 신청했어요. 승인되면 알림으로 알려드려요')
    setNewName('')
    setNewNote('')
    await load()
  }

  const cancelRequest = async (id: string) => {
    setBusyId('new')
    const { error } = await supabase.rpc('cancel_club_request', { p_id: id })
    setBusyId(null)
    if (error) toast.error(errorMessage(error))
    else toast.info('개설 신청을 취소했어요')
    await load()
  }

  const signOutButton = (
    <button className="text-sm font-medium text-ink-soft" onClick={() => void signOut()}>
      로그아웃
    </button>
  )

  if (!memberships) return <Page title="동아리" action={signOutButton}><ListSkeleton rows={2} /></Page>

  const visibleMine = memberships.filter((m) => m.status !== 'left')
  const mineIds = new Set(visibleMine.map((m) => m.club_id))
  const others = clubs.filter((c) => !mineIds.has(c.id))

  return (
    <Page title="동아리" action={signOutButton}>
      {visibleMine.length === 0 ? (
        <Empty title="아직 가입한 동아리가 없어요">아래 목록에서 가입을 신청하거나 새 동아리 개설을 신청해 보세요.</Empty>
      ) : (
        <List>
          {visibleMine.map((m) =>
            m.status === 'approved' ? (
              <Link key={m.club_id} to={`/c/${m.club_id}`} className="flex items-center gap-3 px-4 py-3.5 active:bg-floor">
                <ClubLogo club={{ name: m.clubs?.name ?? '?', logo_path: m.clubs?.logo_path }} size={44} />
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-ink">{m.clubs?.name ?? '동아리'}</p>
                  <p className="text-sm text-ink-soft">{m.role === 'admin' ? '운영진' : '회원'}</p>
                </div>
                <IconChevronRight className="h-5 w-5 shrink-0 text-ink-faint" />
              </Link>
            ) : (
              <div key={m.club_id} className="flex items-center gap-3 px-4 py-3.5">
                <ClubLogo club={{ name: m.clubs?.name ?? '?', logo_path: m.clubs?.logo_path }} size={44} />
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-ink">{m.clubs?.name ?? '동아리'}</p>
                  <div className="mt-1">
                    {m.status === 'pending' ? <Badge tone="shuttle">승인 기다리는 중</Badge> : <Badge>거절됨</Badge>}
                  </div>
                </div>
                {m.status === 'pending' ? (
                  <Button variant="ghost" className="h-10" onClick={() => void load()}>
                    새로고침
                  </Button>
                ) : (
                  <Button variant="secondary" className="h-10" disabled={busyId === m.club_id} onClick={() => void requestJoin(m.club_id)}>
                    다시 신청
                  </Button>
                )}
              </div>
            ),
          )}
        </List>
      )}

      {others.length > 0 && (
        <>
          <SectionTitle>다른 동아리</SectionTitle>
          <div className="space-y-2.5">
            {others.map((c) => {
              const open = expanded === c.id
              const cp = places.filter((p) => p.club_id === c.id)
              return (
                <Card key={c.id}>
                  <div className="flex items-center gap-3">
                    <ClubLogo club={c} size={48} />
                    <p className="min-w-0 flex-1 truncate text-[16px] font-bold text-ink">{c.name}</p>
                    <Button variant="secondary" className="h-10 shrink-0" disabled={busyId === c.id} onClick={() => void requestJoin(c.id)}>
                      가입 신청
                    </Button>
                  </div>
                  {c.description && (
                    <p className={`mt-3 whitespace-pre-line text-sm leading-relaxed text-ink-soft ${open ? '' : 'line-clamp-2'}`}>{c.description}</p>
                  )}
                  {open && cp.length > 0 && (
                    <p className="mt-2 text-sm text-ink-soft">
                      <span className="font-semibold text-ink">운동 장소</span> {cp.map((p) => p.name).join(', ')}
                    </p>
                  )}
                  {open && c.link_url && (
                    <a href={c.link_url} target="_blank" rel="noopener noreferrer" className="mt-2 inline-block text-sm font-semibold text-court-600">
                      {linkLabel(c.link_url)}
                    </a>
                  )}
                  {(c.description || cp.length > 0 || c.link_url) && (
                    <button className="mt-2 text-sm font-medium text-ink-faint" onClick={() => setExpanded(open ? null : c.id)} aria-expanded={open}>
                      {open ? '접기' : '자세히'}
                    </button>
                  )}
                </Card>
              )
            })}
          </div>
        </>
      )}

      {platformAdmin ? (
        <>
          <SectionTitle>서비스 관리</SectionTitle>
          <List>
            <Link to="/admin/clubs" className="flex items-center gap-3 px-4 py-3.5 active:bg-floor">
              <div className="min-w-0 flex-1">
                <p className="font-semibold text-ink">개설 신청, 전체 동아리 관리</p>
                <p className="text-sm text-ink-soft">{pendingCount > 0 ? `승인 기다리는 신청 ${pendingCount}건` : '기다리는 신청이 없어요'}</p>
              </div>
              {pendingCount > 0 && <Badge tone="shuttle">{pendingCount}</Badge>}
              <IconChevronRight className="h-5 w-5 shrink-0 text-ink-faint" />
            </Link>
          </List>
          <SectionTitle>새 동아리 바로 만들기</SectionTitle>
          <Card>
            <form onSubmit={createClub} className="flex gap-2">
              <Input value={newName} onChange={(e) => setNewName(e.target.value)} maxLength={50} placeholder="동아리 이름" className="mt-0 min-w-0 flex-1" />
              <Button type="submit" disabled={busyId === 'new' || !newName.trim()}>
                만들기
              </Button>
            </form>
            <p className="mt-2 text-xs text-ink-faint">서비스 관리자는 신청 없이 만들 수 있어요. 만든 사람이 첫 운영진이 돼요.</p>
          </Card>
        </>
      ) : (
        <>
          <SectionTitle>새 동아리 만들기</SectionTitle>
          {myRequest?.status === 'pending' ? (
            <Card>
              <div className="flex items-start gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-ink">{myRequest.name}</p>
                  <div className="mt-1">
                    <Badge tone="shuttle">개설 승인 기다리는 중</Badge>
                  </div>
                  {myRequest.note && <p className="mt-2 text-sm text-ink-soft">{myRequest.note}</p>}
                </div>
                <Button variant="ghost" className="h-10 shrink-0 text-danger" disabled={busyId === 'new'} onClick={() => void cancelRequest(myRequest.id)}>
                  신청 취소
                </Button>
              </div>
              <p className="mt-3 text-xs text-ink-faint">승인되면 동아리가 만들어지고, 신청한 사람이 첫 운영진이 돼요. 알림으로 알려드려요.</p>
            </Card>
          ) : (
            <Card>
              {myRequest?.status === 'rejected' && (
                <p className="mb-3 rounded-lg bg-floor px-3 py-2 text-sm text-ink-soft">
                  '{myRequest.name}' 신청이 거절됐어요{myRequest.reason ? `: ${myRequest.reason}` : '.'} 고쳐서 다시 신청할 수 있어요.
                </p>
              )}
              <form onSubmit={requestClub} className="space-y-3">
                <Field label="동아리 이름">
                  <Input value={newName} onChange={(e) => setNewName(e.target.value)} maxLength={50} placeholder="예: 단국대 배드민턴 FLY" />
                </Field>
                <Field label="소개 (선택)" hint="학교·지역, 운동 요일 등 관리자가 확인할 내용을 적어 주세요.">
                  <Textarea value={newNote} onChange={(e) => setNewNote(e.target.value)} maxLength={300} rows={2} />
                </Field>
                <Button type="submit" className="w-full" disabled={busyId === 'new' || !newName.trim()}>
                  개설 신청
                </Button>
              </form>
              <p className="mt-2 text-xs text-ink-faint">관리자가 승인하면 동아리가 만들어지고, 신청한 사람이 첫 운영진이 돼요.</p>
            </Card>
          )}
        </>
      )}
    </Page>
  )
}
