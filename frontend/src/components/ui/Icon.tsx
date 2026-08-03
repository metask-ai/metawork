import {
  Activity,
  ArrowLeft,
  CalendarDays,
  Check,
  ChevronDown,
  Clock3,
  Folder,
  Layers3,
  Maximize2,
  Minus,
  PanelLeft,
  Plus,
  Puzzle,
  Radar,
  RefreshCw,
  Search,
  Send,
  Settings,
  Square,
  SquarePen,
  Sunrise,
  TriangleAlert,
  UserRound,
  X,
  type LucideIcon,
} from "lucide-react";

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
  | "clock"
  | "new-task"
  | "skills"
  | "scheduled-tasks"
  | "calendar-days"
  | "radar"
  | "sunrise";

const icons: Record<IconName, LucideIcon> = {
  sidebar: PanelLeft,
  activity: Activity,
  chevron: ChevronDown,
  stop: Square,
  send: Send,
  workspace: Folder,
  search: Search,
  plus: Plus,
  settings: Settings,
  "arrow-left": ArrowLeft,
  close: X,
  minimize: Minus,
  maximize: Maximize2,
  warning: TriangleAlert,
  account: UserRound,
  model: Layers3,
  refresh: RefreshCw,
  check: Check,
  clock: Clock3,
  "new-task": SquarePen,
  skills: Puzzle,
  "scheduled-tasks": Clock3,
  "calendar-days": CalendarDays,
  radar: Radar,
  sunrise: Sunrise,
};

export function Icon({ name }: { name: IconName }) {
  const Glyph = icons[name];

  return (
    <Glyph
      aria-hidden="true"
      className="h-[1em] w-[1em] shrink-0"
      strokeWidth={1.8}
    />
  );
}
