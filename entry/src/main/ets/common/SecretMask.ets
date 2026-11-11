/**
 * Secret masking for rendered message text.
 *
 * A prompt often carries a key — pasted by the user, or echoed back by a tool
 * that read a config file — and the transcript is the one place it should not
 * sit in plain sight: screenshots, screen sharing and shoulder surfing all
 * start there. The desktop client masks credentials in sent text; this is the
 * same rule, applied at render time so the stored text and the clipboard stay
 * whole (masking the data would break a re-send or a copy the user asked for).
 *
 * Patterns are deliberately narrow: a false positive hides ordinary prose, and
 * a key that is not matched is still only one tap away from being shown.
 */

/** Token shapes worth hiding. Ordered longest-prefix first. */
const PATTERNS: RegExp[] = [
  // DeepSeek / OpenAI style: sk- followed by a long opaque run.
  /sk-[A-Za-z0-9_-]{12,}/g,
  // GitHub tokens.
  /gh[pousr]_[A-Za-z0-9]{20,}/g,
  // AWS access key id.
  /AKIA[0-9A-Z]{16}/g,
  // JWT: three dot-separated base64url segments.
  /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
  // Generic bearer/authorization header values.
  /(?:Bearer|bearer)\s+[A-Za-z0-9._~+/=-]{16,}/g
]

/** How many leading characters survive; enough to recognise which key it is. */
const KEEP_HEAD = 8

/** Whether anything in this text looks like a credential. */
export function hasSecret(text: string): boolean {
  if (text.length < 12) {
    return false
  }
  for (const pattern of PATTERNS) {
    pattern.lastIndex = 0
    if (pattern.test(text)) {
      return true
    }
  }
  return false
}

/** Replace every credential-looking run with `<head>…`. */
export function maskSecrets(text: string): string {
  if (text.length < 12) {
    return text
  }
  let out = text
  for (const pattern of PATTERNS) {
    pattern.lastIndex = 0
    out = out.replace(pattern, (match: string): string => {
      if (match.length <= KEEP_HEAD) {
        return '…'
      }
      return `${match.substring(0, KEEP_HEAD)}…`
    })
  }
  return out
}

/** Number of distinct-looking credentials, for the "隐藏了 N 处" caption. */
export function secretCount(text: string): number {
  if (text.length < 12) {
    return 0
  }
  let count = 0
  for (const pattern of PATTERNS) {
    pattern.lastIndex = 0
    const found = text.match(pattern)
    if (found !== null) {
      count += found.length
    }
  }
  return count
}
