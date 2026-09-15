// Turning an organization's chosen accent colour into a usable palette.
// Ref: docs/decisions.md ADR-0020.
//
// The point of this file is that the business picks *one* colour and does
// not get to pick anything that makes the page unreadable. The text
// colour on top of the brand is derived from the brand, never chosen --
// otherwise a pale yellow accent ends up with white text on it.

export interface BrandTheme {
  /** The accent itself, normalized to lowercase #rrggbb. */
  color: string;
  /** Text/icon colour that sits on top of `color`, derived for contrast. */
  foreground: string;
  /** Hover state: darkens a light brand, lightens a dark one. */
  hover: string;
}

const HEX = /^#[0-9a-f]{6}$/;

/** Near-black rather than pure black: pure black on a colour reads harsh. */
const DARK_TEXT = "#111827";
const LIGHT_TEXT = "#ffffff";
/** The escape hatch -- see foregroundFor. */
const PURE_BLACK = "#000000";
/** WCAG AA for body text. */
const AA = 4.5;

function parseHex(hex: string): [number, number, number] {
  return [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
  ];
}

function toHex(rgb: [number, number, number]): string {
  return `#${rgb.map((c) => Math.max(0, Math.min(255, Math.round(c))).toString(16).padStart(2, "0")).join("")}`;
}

/** WCAG relative luminance: the 0..1 the contrast ratio is built from. */
export function relativeLuminance(hex: string): number {
  const [r, g, b] = parseHex(hex).map((channel) => {
    const c = channel / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];

  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio between two colours, 1..21. */
export function contrastRatio(a: string, b: string): number {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  const lighter = Math.max(la, lb);
  const darker = Math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/**
 * Whether a colour can carry legible text at all. Used by the settings
 * screen to warn before saving, not to reject: a business is allowed an
 * awkward brand colour, it just should not find out from its customers.
 * 4.5 is the WCAG AA threshold for body text.
 */
export function isAccessibleAccent(hex: string): boolean {
  const normalized = normalizeBrandColor(hex);
  if (!normalized) return false;
  return contrastRatio(normalized, foregroundFor(normalized)) >= AA;
}

/**
 * White or dark text on the brand, whichever is legible.
 *
 * The softened near-black is preferred because pure black on a colour
 * reads harsh -- but it costs contrast, and there is a band of mid-tone
 * colours (relative luminance roughly 0.18 to 0.24) where neither white
 * nor #111827 reaches AA. Pure black against white always does: their
 * crossover sits at 4.58, above the threshold. So the harsh option is
 * kept as the fallback that makes the guarantee true rather than
 * aspirational.
 */
function foregroundFor(hex: string): string {
  const preferred =
    contrastRatio(hex, LIGHT_TEXT) >= contrastRatio(hex, DARK_TEXT) ? LIGHT_TEXT : DARK_TEXT;

  if (contrastRatio(hex, preferred) >= AA) return preferred;
  return contrastRatio(hex, PURE_BLACK) >= contrastRatio(hex, LIGHT_TEXT) ? PURE_BLACK : LIGHT_TEXT;
}

/** Lowercases and trims; returns null for anything that is not #rrggbb. */
export function normalizeBrandColor(value: string | null | undefined): string | null {
  if (!value) return null;
  const candidate = value.trim().toLowerCase();
  return HEX.test(candidate) ? candidate : null;
}

export function brandTheme(value: string | null | undefined): BrandTheme | null {
  const color = normalizeBrandColor(value);
  if (!color) return null;

  const rgb = parseHex(color);
  // Darkening a colour that is already near-black produces a hover state
  // nobody can see, so the direction of the shift follows the brand.
  const dark = relativeLuminance(color) < 0.2;
  const factor = dark ? 0.18 : -0.12;
  const hover = toHex(rgb.map((c) => c + (dark ? 255 - c : c) * factor) as [number, number, number]);

  return { color, foreground: foregroundFor(color), hover };
}
