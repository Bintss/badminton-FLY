/** 투표 설정: 게스트도 정원에 넣을지 */
export function GuestCapacityField({
  checked,
  onChange,
  disabled,
}: {
  checked: boolean
  onChange: (v: boolean) => void
  disabled?: boolean
}) {
  return (
    <label className="flex cursor-pointer items-start gap-2.5 text-ink">
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-5 w-5 shrink-0 accent-court-600"
      />
      <span className="min-w-0">
        <span className="block text-sm font-medium">게스트도 정원에 포함</span>
        <span className="block text-xs leading-relaxed text-ink-faint">
          {checked ? '게스트도 회원과 같은 선착순이에요. 정원이 차면 게스트도 대기로 들어가요.' : '게스트는 정원과 상관없이 참석해요.'}
        </span>
      </span>
    </label>
  )
}

