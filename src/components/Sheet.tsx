import { useEffect, useRef, type ReactNode } from 'react'
import { IconX } from './icons'

/** 아래에서 올라오는 선택 창. 바깥을 누르거나 Esc로 닫힌다 */
export function Sheet({ title, onClose, children }: { title: ReactNode; onClose: () => void; children: ReactNode }) {
  const panel = useRef<HTMLDivElement>(null)
  // onClose는 부모가 렌더할 때마다 새 함수로 오므로 ref로 들고 있는다.
  // (의존성에 넣으면 입력할 때마다 효과가 다시 돌면서 패널로 포커스를 뺏어, 한 글자만 써지는 버그가 생긴다)
  const closeRef = useRef(onClose)
  useEffect(() => {
    closeRef.current = onClose
  }, [onClose])
  // 열릴 때 한 번만: 포커스 이동, Esc로 닫기, 뒤 화면 스크롤 막기
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && closeRef.current()
    document.addEventListener('keydown', onKey)
    panel.current?.focus()
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [])
  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/30" onClick={onClose}>
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        tabIndex={-1}
        onClick={(e) => e.stopPropagation()}
        className="flex max-h-[82dvh] w-full max-w-md flex-col rounded-t-3xl bg-white pb-[env(safe-area-inset-bottom)] shadow-2xl outline-none"
      >
        <div className="flex items-center justify-between gap-3 border-b border-black/[0.06] px-4 py-3">
          <h2 className="min-w-0 truncate text-[16px] font-bold text-ink">{title}</h2>
          <button type="button" onClick={onClose} aria-label="닫기" className="flex h-10 w-10 items-center justify-center rounded-full text-ink-soft active:bg-black/5">
            <IconX className="h-5 w-5" />
          </button>
        </div>
        <div className="overflow-y-auto overscroll-contain">{children}</div>
      </div>
    </div>
  )
}
