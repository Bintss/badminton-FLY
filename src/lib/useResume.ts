import { useEffect, useRef, useState } from 'react'

/**
 * 화면을 다시 볼 때 새로 읽기: 폰 화면을 껐다 켜거나(체육관에서 흔함), 앱으로 돌아오거나, 인터넷이 다시 연결될 때.
 * 그사이 놓친 실시간 이벤트를 메운다
 */
export function useRefetchOnResume(load: () => unknown) {
  const ref = useRef(load)
  useEffect(() => {
    ref.current = load
  }, [load])
  useEffect(() => {
    const onVisible = () => document.visibilityState === 'visible' && void ref.current()
    const onOnline = () => void ref.current()
    document.addEventListener('visibilitychange', onVisible)
    window.addEventListener('online', onOnline)
    return () => {
      document.removeEventListener('visibilitychange', onVisible)
      window.removeEventListener('online', onOnline)
    }
  }, [])
}

/**
 * 가장 최근 요청의 응답만 화면에 반영하기 위한 번호표.
 * const take = useLatest(); const ticket = take(); …await…; if (!take.isLatest(ticket)) return
 */
export function useLatest() {
  const [take] = useState(() => {
    let seq = 0
    return Object.assign(() => ++seq, { isLatest: (t: number) => t === seq })
  })
  return take
}

/** 실시간 구독이 끊겼다 다시 붙으면(재연결) 새로 읽는 subscribe 콜백 */
export function resubscribeReload(load: () => unknown) {
  let first = true
  return (status: string) => {
    if (status !== 'SUBSCRIBED') return
    if (!first) void load()
    first = false
  }
}
