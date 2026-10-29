import {
  Activity,
  Archive,
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
  Pencil,
  FileDiff,
  Layers3,
  LoaderCircle,
  LogOut,
  Minus,
  PanelLeft,
  PanelRight,
  Plus,
  Puzzle,
  Package,
  Paperclip,
  Plug,
  Radar,
  RefreshCw,
  Search,
  Download,
  ExternalLink,
  Send,
  Settings,
  ShieldCheck,
  Info,
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
  | "archive"
  | "sidebar-right"
  | "loading"
  | "logout"
  | "chevron"
  | "chevron-right"
  | "stop"
  | "send"
  | "workspace"
  | "search"
  | "plus"
  | "settings"
  | "shield"
  | "info"
  | "arrow-left"
  | "close"
  | "warning"
  | "account"
  | "model"
  | "provider"
  | "refresh"
  | "check"
  | "copy"
  | "clock"
  | "new-task"
  | "skills"
  | "skill-file"
  | "file-diff"
  | "upload"
  | "folder-up"
  | "package"
  | "paperclip"
  | "download"
  | "external-link"
  | "trash"
  | "test"
  | "edit"
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
  archive: Archive,
  "sidebar-right": PanelRight,
  loading: LoaderCircle,
  logout: LogOut,
  chevron: ChevronDown,
  "chevron-right": ChevronRight,
  stop: Square,
  send: Send,
  workspace: Folder,
  search: Search,
  plus: Plus,
  settings: Settings,
  shield: ShieldCheck,
  info: Info,
  "arrow-left": ArrowLeft,
  close: X,
  warning: TriangleAlert,
  account: UserRound,
  model: Layers3,
  provider: Plug,
  refresh: RefreshCw,
  check: Check,
  copy: Copy,
  clock: Clock3,
  "new-task": SquarePen,
  skills: Puzzle,
  "skill-file": FileText,
  "file-diff": FileDiff,
  upload: FolderUp,
  "folder-up": FolderUp,
  package: Package,
  paperclip: Paperclip,
  download: Download,
  "external-link": ExternalLink,
  trash: Trash2,
  test: Plug,
  edit: Pencil,
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
