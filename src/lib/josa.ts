/** 받침에 맞는 조사만 돌려준다. particle('셔틀콕', '이', '가') → '이' (DB의 public.josa와 같은 규칙) */
export function particle(word: string, withFinal: string, withoutFinal: string): string {
  const last = word.trim().slice(-1)
  if (!last) return withoutFinal
  const code = last.charCodeAt(0)
  if (code >= 0xac00 && code <= 0xd7a3) return (code - 0xac00) % 28 !== 0 ? withFinal : withoutFinal
  return '013678'.includes(last) ? withFinal : withoutFinal // 숫자는 읽는 소리로 (영·일·삼·육·칠·팔)
}

/** 단어에 조사를 붙인다. josa('죽전 셔틀콕', '이', '가') → '죽전 셔틀콕이' */
export function josa(word: string, withFinal: string, withoutFinal: string): string {
  return word + particle(word, withFinal, withoutFinal)
}
