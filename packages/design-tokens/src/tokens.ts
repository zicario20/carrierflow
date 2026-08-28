/**
 * CarrierFlow's light-first operational token contract.
 * UI code consumes these semantic names instead of screen-level color values.
 */
export const operationalTokens = {
  color: {
    primary: "#2563EB",
    onPrimary: "#FFFFFF",
    accent: "#EA580C",
    background: "#F8FAFC",
    foreground: "#1E293B",
    surface: "#FFFFFF",
    muted: "#E9EFF8",
    mutedForeground: "#475569",
    border: "#E2E8F0",
    destructive: "#DC2626",
    onDestructive: "#FFFFFF",
    ring: "#2563EB",
  },
  spacing: {
    compact: "4px",
    standard: "8px",
    comfortable: "16px",
    section: "24px",
    page: "32px",
  },
  radius: {
    control: "8px",
    surface: "12px",
  },
  typography: {
    bodySize: "1rem",
    bodyLineHeight: "1.5",
    bodyFamily: "Inter, ui-sans-serif, system-ui, sans-serif",
  },
  interaction: {
    minimumTarget: "44px",
    focusRingWidth: "3px",
    focusOffset: "2px",
  },
  motion: {
    feedbackDuration: "160ms",
  },
} as const;

export const operationalCssVariables = {
  "--cf-color-primary": operationalTokens.color.primary,
  "--cf-color-on-primary": operationalTokens.color.onPrimary,
  "--cf-color-accent": operationalTokens.color.accent,
  "--cf-color-background": operationalTokens.color.background,
  "--cf-color-foreground": operationalTokens.color.foreground,
  "--cf-color-surface": operationalTokens.color.surface,
  "--cf-color-muted": operationalTokens.color.muted,
  "--cf-color-muted-foreground": operationalTokens.color.mutedForeground,
  "--cf-color-border": operationalTokens.color.border,
  "--cf-color-destructive": operationalTokens.color.destructive,
  "--cf-color-on-destructive": operationalTokens.color.onDestructive,
  "--cf-color-ring": operationalTokens.color.ring,
  "--cf-space-compact": operationalTokens.spacing.compact,
  "--cf-space-standard": operationalTokens.spacing.standard,
  "--cf-space-comfortable": operationalTokens.spacing.comfortable,
  "--cf-space-section": operationalTokens.spacing.section,
  "--cf-space-page": operationalTokens.spacing.page,
  "--cf-radius-control": operationalTokens.radius.control,
  "--cf-radius-surface": operationalTokens.radius.surface,
  "--cf-font-body": operationalTokens.typography.bodyFamily,
  "--cf-font-size-body": operationalTokens.typography.bodySize,
  "--cf-line-height-body": operationalTokens.typography.bodyLineHeight,
  "--cf-control-target": operationalTokens.interaction.minimumTarget,
  "--cf-focus-ring-width": operationalTokens.interaction.focusRingWidth,
  "--cf-focus-offset": operationalTokens.interaction.focusOffset,
  "--cf-motion-feedback": operationalTokens.motion.feedbackDuration,
} as const;

export type OperationalTokens = typeof operationalTokens;
