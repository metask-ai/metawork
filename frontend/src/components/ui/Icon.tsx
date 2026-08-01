type IconName =
  | "sidebar"
  | "activity"
  | "chevron"
  | "stop"
  | "send"
  | "workspace"
  | "search"
  | "plus"
  | "settings"
  | "arrow-left"
  | "close"
  | "minimize"
  | "maximize"
  | "warning"
  | "account"
  | "model"
  | "refresh"
  | "check"
  | "clock";

const paths: Record<IconName, React.ReactNode> = {
  sidebar: <path d="M3.5 5.5h17v13h-17zM8.5 5.5v13" />,
  activity: <path d="M4 18V9m5 9V5m5 13v-7m5 7V7" />,
  chevron: <path d="m8 10 4 4 4-4" />,
  stop: <rect x="7" y="7" width="10" height="10" rx="1.5" />,
  send: <path d="m4 12 16-8-6 16-2.5-6.5L4 12Zm7.5 1.5L20 4" />,
  workspace: <path d="M3.5 7.5h7l2 2h8v9h-17zM3.5 7.5v-2h6l2 2" />,
  search: <path d="m19 19-4.2-4.2m1.7-4.3a6 6 0 1 1-12 0 6 6 0 0 1 12 0Z" />,
  plus: <path d="M12 5v14M5 12h14" />,
  settings: (
    <path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Zm7 3.5 1.3-2.1-2-3.4-2.5.1-1.2-.7L13.5 3h-4L8.4 5.9l-1.2.7-2.5-.1-2 3.4L4 12l-1.3 2.1 2 3.4 2.5-.1 1.2.7 1.1 2.9h4l1.1-2.9 1.2-.7 2.5.1 2-3.4L19 12Z" />
  ),
  "arrow-left": <path d="m14.5 6-6 6 6 6" />,
  close: <path d="m6.5 6.5 11 11m0-11-11 11" />,
  minimize: <path d="M6 12h12" />,
  maximize: <rect x="6.5" y="6.5" width="11" height="11" rx="0.5" />,
  warning: <path d="M12 4 21 20H3L12 4Zm0 5.5v4.5m0 3h.01" />,
  account: <path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm7 8a7 7 0 0 0-14 0" />,
  model: (
    <path d="m12 3 8 4.5-8 4.5-8-4.5L12 3Zm-8 9 8 4.5 8-4.5M4 16.5 12 21l8-4.5" />
  ),
  refresh: <path d="M19 7v5h-5m4.2-4a7.5 7.5 0 1 0 .7 7" />,
  check: <path d="m5 12.5 4.2 4.2L19 7" />,
  clock: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </>
  ),
};

export function Icon({ name }: { name: IconName }) {
  return (
    <svg
      aria-hidden="true"
      className="h-[1em] w-[1em] shrink-0"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {paths[name]}
    </svg>
  );
}
