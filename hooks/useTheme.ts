import { colors, spacing, radii, typography } from "../constants/theme";

// Single dark theme for now — FieldOps is dark-first for the MVP.
// Structured as a hook (not a flat import) so a light variant or
// system-preference switching can be added later without changing
// every screen that consumes it.
export function useTheme() {
  return {
    colors,
    spacing,
    radii,
    typography,
  };
}