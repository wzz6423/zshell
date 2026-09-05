import type { ReactNode } from "react";
import {
  Outlet,
  createRootRoute,
  HeadContent,
  Scripts,
  useRouterState,
} from "@tanstack/react-router";
import appCss from "@/styles/app.css?url";
import { DEFAULT_LANGUAGE, isLanguage } from "@/lib/i18n";
import { withBase } from "@/lib/utils";

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
      { name: "theme-color", content: "#0d1117" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", type: "image/png", href: withBase("/zshell-icon.png") },
      { rel: "apple-touch-icon", href: withBase("/zshell-icon.png") },
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
  const prefix = pathname.split("/")[1];
  const language = isLanguage(prefix) ? prefix : DEFAULT_LANGUAGE;

  return (
    <html lang={language} className="dark">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}
