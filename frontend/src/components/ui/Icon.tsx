import {
  Activity,
  ArrowLeft,
  CalendarDays,
  Check,
  ChevronRight,
  ChevronDown,
  Clock3,
  Copy,
  Folder,
  FolderUp,
  FileText,
  Layers3,
  LoaderCircle,
  Minus,
  PanelLeft,
  PanelRight,
  Plus,
  Puzzle,
  Package,
  Plug,
  Radar,
  RefreshCw,
  Search,
  Download,
  Send,
  Settings,
  Square,
  SquarePen,
  Sunrise,
  TriangleAlert,
  Trash2,
  UserRound,
  X,
  type LucideIcon,
} from "lucide-react";

type IconName =
  | "sidebar"
  | "minimize"
  | "maximize"
  | "restore"
  | "activity"
  | "sidebar-right"
  | "loading"
  | "chevron"
  | "chevron-right"
  | "stop"
  | "send"
  | "workspace"
  | "search"
  | "plus"
  | "settings"
  | "arrow-left"
  | "close"
  | "warning"
  | "account"
  | "model"
  | "refresh"
  | "check"
  | "clock"
  | "new-task"
  | "skills"
  | "skill-file"
  | "upload"
  | "folder-up"
  | "package"
  | "download"
  | "trash"
  | "scheduled-tasks"
  | "mcp"
  | "calendar-days"
  | "radar"
  | "sunrise";

const icons: Record<IconName, LucideIcon> = {
  sidebar: PanelLeft,
  minimize: Minus,
  maximize: Square,
  restore: Copy,
  activity: Activity,
  "sidebar-right": PanelRight,
  loading: LoaderCircle,
  chevron: ChevronDown,
  "chevron-right": ChevronRight,
  stop: Square,
  send: Send,
  workspace: Folder,
  search: Search,
  plus: Plus,
  settings: Settings,
  "arrow-left": ArrowLeft,
  close: X,
  warning: TriangleAlert,
  account: UserRound,
  model: Layers3,
  refresh: RefreshCw,
  check: Check,
  clock: Clock3,
  "new-task": SquarePen,
  skills: Puzzle,
  "skill-file": FileText,
  upload: FolderUp,
  "folder-up": FolderUp,
  package: Package,
  download: Download,
  trash: Trash2,
  "scheduled-tasks": Clock3,
  mcp: Plug,
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
