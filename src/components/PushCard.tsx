import { useEffect, useState } from 'react'
import { disablePush, enablePush, pushState, type PushState } from '../lib/push'
import { useToast } from './toast'
import { Button } from './ui'

const TEXT: Record<PushState, { title: string; body: string }> = {
  unsupported: { title: '이 브라우저는 알림을 못 받아요', body: '카카오톡 안에서 열었다면 오른쪽 위 메뉴의 "다른 브라우저로 열기"로 크롬·사파리에서 열어주세요.' },
  ios_install: {
    title: '아이폰은 홈 화면에 추가해야 알림이 와요',
    body: '사파리 아래쪽 공유 버튼 → "홈 화면에 추가"를 누른 뒤, 홈 화면의 앱으로 열어서 알림을 켜주세요. (iOS 16.4 이상)',
  },
  not_ready: { title: '알림 서버를 준비하고 있어요', body: '운영진이 알림 설정을 마치면 켤 수 있어요. 그동안 앱 안 알림함으로 알려드려요.' },
  denied: { title: '알림이 막혀 있어요', body: '폰 설정 → 앱(또는 브라우저) → 알림에서 이 사이트 알림을 허용해주세요.' },
  off: { title: '알림 받기', body: '투표 오픈 10분 전, 내 경기 코트 배정 등을 폰으로 바로 알려드려요.' },
  on: { title: '이 기기로 알림을 받고 있어요', body: '받을 알림 종류는 아래에서 고를 수 있어요.' },
}

/** 이 기기 웹 푸시 켜기/끄기. compact = 홈 화면 안내용 (켜기 버튼만, 켜지면 숨김) */
export function PushCard({ compact, onDismiss }: { compact?: boolean; onDismiss?: () => void }) {
  const toast = useToast()
  const [state, setState] = useState<PushState | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let alive = true
    pushState()
      .then((s) => alive && setState(s))
      .catch(() => alive && setState('unsupported'))
    return () => {
      alive = false
    }
  }, [])

  if (!state) return null
  if (compact && (state === 'on' || state === 'not_ready' || state === 'unsupported' || state === 'denied')) return null

  const toggle = async () => {
    setBusy(true)
    try {
      const next = state === 'on' ? await disablePush() : await enablePush()
      setState(next)
      if (next === 'on') toast.success('알림을 켰어요')
      else if (next === 'denied') toast.error('알림 권한이 막혔어요. 폰 설정에서 허용해주세요')
      else if (state === 'on') toast.info('이 기기 알림을 껐어요')
    } catch {
      toast.error('알림을 켜지 못했어요. 잠시 뒤 다시 시도해주세요')
    }
    setBusy(false)
  }

  const t = TEXT[state]
  const canToggle = state === 'off' || state === 'on'
  return (
    <div className={`rounded-2xl p-4 ${compact ? 'bg-court-50 ring-1 ring-court-600/15' : 'bg-white ring-1 ring-black/[0.06]'}`}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className={`text-[15px] font-bold ${state === 'on' ? 'text-court-700' : 'text-ink'}`}>{t.title}</p>
          <p className="mt-1 text-[13px] leading-relaxed text-ink-soft">{t.body}</p>
        </div>
        {compact && onDismiss && (
          <button type="button" onClick={onDismiss} className="-mr-1 -mt-1 h-8 shrink-0 rounded-lg px-2 text-xs font-medium text-ink-faint">
            닫기
          </button>
        )}
      </div>
      {canToggle && (
        <Button variant={state === 'on' ? 'secondary' : 'primary'} className="mt-3 h-11 w-full text-[15px]" disabled={busy} onClick={() => void toggle()}>
          {state === 'on' ? '이 기기 알림 끄기' : '알림 켜기'}
        </Button>
      )}
    </div>
  )
}
