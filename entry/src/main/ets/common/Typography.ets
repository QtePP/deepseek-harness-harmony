/**
 * Conversation text size.
 *
 * dsh-go offers four sizes for the transcript; on a phone that is not a
 * cosmetic preference — a long answer is read for minutes at a time, and the
 * system font scale alone cannot help someone who only finds the *chat* too
 * small. The scale therefore applies to transcript content (message body,
 * thinking, tool rows) and deliberately not to chrome: buttons, chips and
 * captions keep their size so the layout does not reflow around the controls
 * the user has to hit.
 *
 * The value lives in AppStorage under `fontScale` so any view binds to it with
 * `@StorageLink`; the chosen level id is persisted by AppConfig.
 */

/** One selectable text size. */
export interface FontLevel {
  id: string
  label: string
  scale: number
}

/** AppStorage key every view binds to. */
export const FONT_SCALE_KEY: string = 'fontScale'

/** 1.0 = the sizes the transcript was designed at. */
export const FONT_SCALE_DEFAULT: number = 1

export const FONT_LEVELS: FontLevel[] = [
  { id: 'small', label: '小', scale: 0.9 },
  { id: 'standard', label: '标准', scale: 1 },
  { id: 'large', label: '大', scale: 1.15 },
  { id: 'xlarge', label: '特大', scale: 1.3 }
]

/** Scale for an id; an unknown id falls back to standard rather than to 0. */
export function fontScaleOf(id: string): number {
  for (const level of FONT_LEVELS) {
    if (level.id === id) {
      return level.scale
    }
  }
  return FONT_SCALE_DEFAULT
}

/** Id for a scale; used when loading a stored value that may be stale. */
export function fontIdOf(scale: number): string {
  for (const level of FONT_LEVELS) {
    if (level.scale === scale) {
      return level.id
    }
  }
  return 'standard'
}

/** Label for an id, for the settings row. */
export function fontLabelOf(id: string): string {
  for (const level of FONT_LEVELS) {
    if (level.id === id) {
      return level.label
    }
  }
  return '标准'
}

/**
 * Scale one transcript size.
 *
 * Rounded to a half point: sub-pixel font sizes make ArkUI's line breaking
 * wobble between paragraphs, and the difference is invisible.
 */
export function scaled(size: number, scale: number): number {
  return Math.round(size * scale * 2) / 2
}
