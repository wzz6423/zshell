import type { ReactNode } from "react";
import { useEffect } from "react";
import {
  Outlet,
  createRootRoute,
  HeadContent,
  Scripts,
  useRouterState,
} from "@tanstack/react-router";
import appCss from "@/styles/app.css?url";
import { languageFromPath, languageTag, languageDirection } from "@/lib/i18n";
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
      { rel: "icon", type: "image/png", href: withBase("/zshell-icon.png?v=3") },
      { rel: "apple-touch-icon", href: withBase("/zshell-icon.png?v=3") },
    ],
    scripts: [
      {
        children: `
          (function() {
            const theme = localStorage.getItem('theme') || 'auto';
            const isDark = theme === 'auto'
              ? window.matchMedia('(prefers-color-scheme: dark)').matches
              : theme === 'dark';
            if (isDark) {
              document.documentElement.classList.add('dark');
            }
          })();
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

  // 自动跟随系统主题（但如果用户有保存的偏好则使用用户偏好）
  useEffect(() => {
    const updateTheme = () => {
      const savedTheme = localStorage.getItem('theme') || 'auto';
      const isDark = savedTheme === 'auto'
        ? window.matchMedia('(prefers-color-scheme: dark)').matches
        : savedTheme === 'dark';
      document.documentElement.classList.toggle('dark', isDark);
    };

    // 监听系统主题变化
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    mediaQuery.addEventListener('change', updateTheme);

    // 监听 localStorage 变化（跨标签页同步）
    const handleStorageChange = (e: StorageEvent) => {
      if (e.key === 'theme') {
        updateTheme();
      }
    };
    window.addEventListener('storage', handleStorageChange);

    return () => {
      mediaQuery.removeEventListener('change', updateTheme);
      window.removeEventListener('storage', handleStorageChange);
    };
  }, []);

  return (
    <html lang={languageTag(language)} dir={languageDirection(language)}>
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
