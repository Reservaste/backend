import { describe, expect, it } from "vitest";
import {
  brandTheme,
  contrastRatio,
  isAccessibleAccent,
  normalizeBrandColor,
  relativeLuminance,
} from "./branding";

describe("normalizeBrandColor", () => {
  it("lowercases and trims a valid hex", () => {
    expect(normalizeBrandColor("  #FFAA00 ")).toBe("#ffaa00");
  });

  it("rejects anything that is not #rrggbb", () => {
    // The last two are the reason this exists: the value lands in a CSS
    // custom property, so a string that escapes it is a style injection.
    for (const value of ["", "  ", "ffaa00", "#fa0", "#gggggg", "red", "#ffaa00; } body {"]) {
      expect(normalizeBrandColor(value)).toBeNull();
    }
    expect(normalizeBrandColor(null)).toBeNull();
    expect(normalizeBrandColor(undefined)).toBeNull();
  });
});

describe("relativeLuminance", () => {
  it("anchors at the extremes", () => {
    expect(relativeLuminance("#000000")).toBeCloseTo(0, 5);
    expect(relativeLuminance("#ffffff")).toBeCloseTo(1, 5);
  });
});

describe("contrastRatio", () => {
  it("is 21 for black on white and 1 for a colour on itself", () => {
    expect(contrastRatio("#000000", "#ffffff")).toBeCloseTo(21, 2);
    expect(contrastRatio("#3366cc", "#3366cc")).toBeCloseTo(1, 5);
  });

  it("is symmetric", () => {
    expect(contrastRatio("#123456", "#abcdef")).toBeCloseTo(contrastRatio("#abcdef", "#123456"), 10);
  });
});

describe("brandTheme", () => {
  it("returns null for an invalid colour so the caller falls back to the product default", () => {
    expect(brandTheme("nope")).toBeNull();
    expect(brandTheme(null)).toBeNull();
  });

  it("puts white on a dark brand and near-black on a light one", () => {
    expect(brandTheme("#0b3d91")!.foreground).toBe("#ffffff");
    // The whole reason the foreground is derived rather than chosen: a
    // pale yellow with white text on it is unreadable.
    expect(brandTheme("#ffe066")!.foreground).toBe("#111827");
  });

  it("always produces a legible pairing, across the hue circle", () => {
    for (let hue = 0; hue < 360; hue += 15) {
      for (const lightness of [0.15, 0.35, 0.55, 0.75, 0.95]) {
        const hex = hslToHex(hue, 0.7, lightness);
        const theme = brandTheme(hex)!;
        expect(contrastRatio(theme.color, theme.foreground)).toBeGreaterThanOrEqual(4.5);
      }
    }
  });

  it("darkens a light brand on hover and lightens a dark one", () => {
    const light = brandTheme("#4f8ef7")!;
    expect(relativeLuminance(light.hover)).toBeLessThan(relativeLuminance(light.color));

    // Darkening near-black gives a hover state nobody can see.
    const dark = brandTheme("#0a0a0a")!;
    expect(relativeLuminance(dark.hover)).toBeGreaterThan(relativeLuminance(dark.color));
  });

  it("keeps the hover state inside the valid hex range at both extremes", () => {
    expect(brandTheme("#000000")!.hover).toMatch(/^#[0-9a-f]{6}$/);
    expect(brandTheme("#ffffff")!.hover).toMatch(/^#[0-9a-f]{6}$/);
  });
});

describe("isAccessibleAccent", () => {
  it("accepts colours that can carry legible text", () => {
    expect(isAccessibleAccent("#0b3d91")).toBe(true);
    expect(isAccessibleAccent("#ffe066")).toBe(true);
  });

  it("rejects an invalid colour", () => {
    expect(isAccessibleAccent("#fff")).toBe(false);
  });
});

/** Test-only: sweeping the hue circle needs colours, not a colour library. */
function hslToHex(h: number, s: number, l: number): string {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  const [r, g, b] = (
    h < 60
      ? [c, x, 0]
      : h < 120
        ? [x, c, 0]
        : h < 180
          ? [0, c, x]
          : h < 240
            ? [0, x, c]
            : h < 300
              ? [x, 0, c]
              : [c, 0, x]
  ) as [number, number, number];

  return `#${[r, g, b]
    .map((channel) =>
      Math.round((channel + m) * 255)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("")}`;
}
