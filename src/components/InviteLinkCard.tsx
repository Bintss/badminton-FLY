import { useEffect, useState } from 'react'
import { appRootUrl, errorMessage, supabase } from '../lib/supabase'
import { ConfirmButton } from './ConfirmButton'
import { useToast } from './toast'
import { Button, Card } from './ui'

/** 회원 관리: 초대 링크 (링크로 들어오면 승인 없이 바로 가입). 만들기·공유·새 링크로 바꾸기·끄기 */
export function InviteLinkCard({ clubId, clubName }: { clubId: string; clubName: string }) {
  const toast = useToast()
  const [token, setToken] = useState<string | null | undefined>(undefined)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let alive = true
    void supabase.rpc('get_invite', { p_club: clubId }).then(({ data, error }) => {
      if (!alive) return
      if (error) toast.error(errorMessage(error))
      setToken((data as string | null) ?? null)
    })
    return () => {
      alive = false
    }
  }, [clubId, toast])

  const url = token ? new URL(`join/${token}`, appRootUrl()).toString() : ''

  const reset = async () => {
    setBusy(true)
    const { data, error } = await supabase.rpc('reset_invite', {
      p_club: clubId,
    })
    setBusy(false)
    if (error) return toast.error(errorMessage(error))
    const had = !!token
    setToken(data as string)
    toast.success(had ? '새 링크로 바꿨어요. 예전 링크로는 이제 가입할 수 없어요' : '초대 링크를 만들었어요')
  }

  const disable = async () => {
    setBusy(true)
    const { error } = await supabase.rpc('disable_invite', { p_club: clubId })
    setBusy(false)
    if (error) return toast.error(errorMessage(error))
    setToken(null)
    toast.info('초대 링크를 껐어요')
  }

  const share = async () => {
    const text = `${clubName}에 초대해요. 링크로 들어오면 바로 가입돼요`
    if (navigator.share) {
      try {
        await navigator.share({ title: clubName, text, url })
        return
      } catch (e) {
        if ((e as Error).name === 'AbortError') return // 사용자가 닫음
      }
    }
    try {
      await navigator.clipboard.writeText(url)
      toast.success('링크를 복사했어요')
    } catch {
      toast.error('복사하지 못했어요. 링크를 길게 눌러 복사해 주세요')
    }
  }

  if (token === undefined) return null

  return (
    <Card className="mb-5">
      <p className="font-semibold text-ink">초대 링크</p>
      {!token ? (
        <>
          <p className="mt-1 text-sm text-ink-soft">링크로 들어온 사람은 승인 없이 바로 회원이 돼요. 단톡방에 올려 두기 좋아요.</p>
          <Button className="mt-3 w-full" disabled={busy} onClick={() => void reset()}>
            초대 링크 만들기
          </Button>
        </>
      ) : (
        <>
          <p className="mt-1 text-sm text-ink-soft">이 링크로 들어오면 승인 없이 바로 가입돼요. 강퇴한 사람은 들어올 수 없어요.</p>
          <p className="mt-3 select-all break-all rounded-lg bg-floor px-3 py-2 text-[13px] text-ink-soft">{url}</p>
          <Button className="mt-3 w-full" onClick={() => void share()}>
            링크 공유하기
          </Button>
          <div className="mt-2 flex justify-center gap-1">
            <ConfirmButton
              label="새 링크로 바꾸기"
              confirmLabel="예전 링크는 못 써요. 바꾸기"
              className="h-9 px-3 text-sm font-medium text-ink-soft"
              armedClassName="h-9 bg-danger px-3 text-sm text-white"
              disabled={busy}
              onConfirm={() => void reset()}
            />
            <ConfirmButton
              label="링크 끄기"
              confirmLabel="한 번 더 누르면 끄기"
              className="h-9 px-3 text-sm font-medium text-ink-soft"
              armedClassName="h-9 bg-danger px-3 text-sm text-white"
              disabled={busy}
              onConfirm={() => void disable()}
            />
          </div>
        </>
      )}
    </Card>
  )
}
