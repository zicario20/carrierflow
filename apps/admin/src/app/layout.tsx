import type { Metadata } from "next";
import type { CSSProperties, ReactNode } from "react";

import { operationalCssVariables, operationalTokens } from "../../../../packages/design-tokens/src/tokens";
import englishMessages from "../i18n/en.json";
import spanishMessagesSource from "../i18n/es.json";

export const metadata: Metadata = {
  title: "CarrierFlow",
  description: "Carrier operations platform",
};

export type AdminLocale = "en" | "es";

type Translation = typeof englishMessages;
type CssVariables = CSSProperties & Record<`--${string}`, string>;

const spanishMessages: Translation = spanishMessagesSource;
const messages: Record<AdminLocale, Translation> = {
  en: englishMessages,
  es: spanishMessages,
};

export const adminShellCss = `
  *, *::before, *::after { box-sizing: border-box; }
  .carrierflow-shell { min-block-size: 100dvh; overflow-x: hidden; }
  .carrierflow-navigation { display: flex; flex-wrap: wrap; gap: var(--cf-space-standard); }
  .carrierflow-control {
    align-items: center;
    border: 1px solid transparent;
    border-radius: var(--cf-radius-control);
    color: var(--cf-color-foreground);
    cursor: pointer;
    display: inline-flex;
    font: inherit;
    font-weight: 600;
    gap: var(--cf-space-standard);
    justify-content: center;
    min-inline-size: var(--cf-control-target);
    min-block-size: var(--cf-control-target);
    padding-inline: var(--cf-space-comfortable);
    text-decoration: none;
    touch-action: manipulation;
    transition: background-color var(--cf-motion-feedback) ease, color var(--cf-motion-feedback) ease;
  }
  .carrierflow-control:hover { background-color: var(--cf-color-muted); }
  .carrierflow-control:focus-visible {
    outline: var(--cf-focus-ring-width) solid var(--cf-color-ring);
    outline-offset: var(--cf-focus-offset);
  }
  @media (prefers-reduced-motion: reduce) {
    .carrierflow-control { transition: none; }
  }
`;

const tokenizedBodyStyle: CssVariables = {
  ...operationalCssVariables,
  backgroundColor: operationalTokens.color.background,
  color: operationalTokens.color.foreground,
  fontFamily: operationalTokens.typography.bodyFamily,
  fontSize: operationalTokens.typography.bodySize,
  lineHeight: operationalTokens.typography.bodyLineHeight,
  margin: 0,
};

type AdminShellProps = Readonly<{
  children?: ReactNode;
  locale: AdminLocale;
}>;

function ShellContent({ children, locale }: AdminShellProps) {
  const copy = messages[locale];
  const navigationItems = [
    { href: "/operations", label: copy.navigation.operations },
    { href: "/loads", label: copy.navigation.loads },
    { href: "/drivers", label: copy.navigation.drivers },
    { href: "/vehicles", label: copy.navigation.vehicles },
  ];

  return (
    <div className="carrierflow-shell" style={tokenizedBodyStyle}>
      <style>{adminShellCss}</style>
      <header
        style={{
          backgroundColor: operationalTokens.color.surface,
          borderBottom: `1px solid ${operationalTokens.color.border}`,
          padding: operationalTokens.spacing.comfortable,
        }}
      >
        <div
          style={{
            alignItems: "center",
            display: "flex",
            flexWrap: "wrap",
            gap: operationalTokens.spacing.comfortable,
            justifyContent: "space-between",
            margin: "0 auto",
            maxWidth: "80rem",
          }}
        >
          <strong>{copy.brand}</strong>
          <nav aria-label={copy.navigation.label} className="carrierflow-navigation">
            {navigationItems.map((item) => (
              <a className="carrierflow-control" href={item.href} key={item.href}>
                {item.label}
              </a>
            ))}
          </nav>
        </div>
      </header>
      <main
        aria-label={copy.main.label}
        style={{
          margin: "0 auto",
          maxWidth: "80rem",
          padding: operationalTokens.spacing.page,
        }}
      >
        {children ?? (
          <section aria-labelledby="operations-overview-heading">
            <h1 id="operations-overview-heading">{copy.main.heading}</h1>
            <p>{copy.main.description}</p>
          </section>
        )}
        <p aria-label={`${copy.status.label}: ${copy.status.onTime}`} role="status">
          <span>{copy.status.label}: </span>
          <strong>{copy.status.onTime}</strong>
        </p>
      </main>
    </div>
  );
}

export function AdminShell({ children, locale }: AdminShellProps) {
  return <ShellContent locale={locale}>{children}</ShellContent>;
}

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <body style={{ margin: 0 }}>
        <AdminShell locale="en">{children}</AdminShell>
      </body>
    </html>
  );
}
