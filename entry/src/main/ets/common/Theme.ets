/**
 * Accent themes.
 *
 * The palette is deliberately small and hand-picked: every value has to read
 * as "the app's colour" against both the light and the dark background, and a
 * generated hue wheel produces several that do not. Only accent surfaces change
 * — buttons, links, the selected row, the context ring, the send key — while
 * backgrounds, bubbles and text keep their neutral resources. That is what
 * makes six themes safe to ship without a second design review per theme.
 *
 * The value lives in AppStorage under `accent` so any component can bind to it
 * with `@StorageLink`; the chosen id is persisted by AppConfig.
 */

/** One selectable accent. */
export interface ThemeOption {
  id: string
  label: string
  value: string
}

/** AppStorage key every component binds to. */
export const ACCENT_KEY: string = 'accent'

/** dsh's own blue: the default when nothing has been chosen. */
export const ACCENT_DEFAULT: string = '#4D6BFE'

export const THEMES: ThemeOption[] = [
  { id: 'blue', label: '深蓝', value: ACCENT_DEFAULT },
  { id: 'indigo', label: '靛紫', value: '#6B5BD2' },
  { id: 'teal', label: '青', value: '#0E9F8E' },
  { id: 'green', label: '松绿', value: '#2F9E5F' },
  { id: 'amber', label: '琥珀', value: '#D98324' },
  { id: 'rose', label: '玫瑰', value: '#D0507A' }
]

/** Colour for an id; an unknown id falls back to the default rather than to black. */
export function accentOf(id: string): string {
  for (const theme of THEMES) {
    if (theme.id === id) {
      return theme.value
    }
  }
  return ACCENT_DEFAULT
}

/** Id for a colour; used when loading a stored value that may be stale. */
export function themeIdOf(value: string): string {
  for (const theme of THEMES) {
    if (theme.value === value) {
      return theme.id
    }
  }
  return 'blue'
}

/** Label for an id, for the settings row. */
export function themeLabelOf(id: string): string {
  for (const theme of THEMES) {
    if (theme.id === id) {
      return theme.label
    }
  }
  return '深蓝'
}
