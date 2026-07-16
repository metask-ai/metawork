type IconName =
  "sidebar" | "activity" | "chevron" | "stop" | "send" | "workspace";

const paths: Record<IconName, React.ReactNode> = {
  sidebar: <path d="M3.5 5.5h17v13h-17zM8.5 5.5v13" />,
  activity: <path d="M4 18V9m5 9V5m5 13v-7m5 7V7" />,
  chevron: <path d="m8 10 4 4 4-4" />,
  stop: <rect x="7" y="7" width="10" height="10" rx="1.5" />,
  send: <path d="m4 12 16-8-6 16-2.5-6.5L4 12Zm7.5 1.5L20 4" />,
  workspace: <path d="M3.5 7.5h7l2 2h8v9h-17zM3.5 7.5v-2h6l2 2" />,
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
