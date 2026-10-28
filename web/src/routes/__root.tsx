import type { ReactNode } from "react";
import {
  Outlet,
  createRootRoute,
  HeadContent,
  Scripts,
  useRouterState,
} from "@tanstack/react-router";
import { RootProvider } from "fumadocs-ui/provider/base";
import appCss from "@/styles/app.css?url";
import { languageFromPath, languageTag, languageDirection } from "@/lib/i18n";
import { withBase } from "@/lib/utils";
import { SiteParticles } from "@/components/site-particles";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Zshell — A native terminal workspace for macOS" },
      {
        name: "description",
        content:
          "Zshell is a fast, keyboard-first terminal workspace for macOS. Projects, sessions, a command palette, and inline git diffs — all in one native window.",
      },
      { name: "theme-color", content: "#0a0a0a" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", type: "image/png", href: withBase("/zshell-icon.png?v=3") },
      { rel: "apple-touch-icon", href: withBase("/zshell-icon.png?v=3") },
    ],
    scripts: [
      {
        children: `
          try {
            if (localStorage.getItem('theme') === 'auto') {
              localStorage.setItem('theme', 'system');
            }
          } catch {}
        `,
      },
    ],
  }),
  component: RootComponent,
});

function RootComponent() {
  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  );
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  // Read from the path rather than a route param: translated pages are a mix
  // of `/$lang/docs/…` and spelled-out routes like `/en`, and only the URL is
  // common to both. Chinese is unprefixed, so anything else is Chinese.
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const language = languageFromPath(pathname);

  return (
    <html lang={languageTag(language)} dir={languageDirection(language)} suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        <RootProvider dir={languageDirection(language)} theme={{ hotKey: false }} search={{ enabled: false }}>
          <SiteParticles />
          <div className="site-content">{children}</div>
        </RootProvider>
        <Scripts />
      </body>
    </html>
  );
}
