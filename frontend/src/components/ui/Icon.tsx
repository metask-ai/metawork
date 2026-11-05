import {
  Activity,
  Archive,
  ArrowLeft,
  ArrowDown,
  ArrowUp,
  Box,
  CalendarDays,
  Check,
  ChevronRight,
  ChevronDown,
  Clock3,
  Copy,
  Folder,
  FolderMinus,
  FolderUp,
  FileText,
  Pencil,
  FileDiff,
  Layers3,
  ListTree,
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
  Ellipsis,
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
  | "more"
  | "sidebar"
  | "minimize"
  | "maximize"
  | "restore"
  | "activity"
  | "archive"
  | "sidebar-right"
  | "file-tree"
  | "loading"
  | "logout"
  | "chevron"
  | "chevron-right"
  | "stop"
  | "send"
  | "workspace"
  | "folder-minus"
  | "search"
  | "plus"
  | "settings"
  | "shield"
  | "info"
  | "arrow-left"
  | "arrow-down"
  | "close"
  | "warning"
  | "account"
  | "model"
  | "box"
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
  more: Ellipsis,
  sidebar: PanelLeft,
  minimize: Minus,
  maximize: Square,
  restore: Copy,
  activity: Activity,
  archive: Archive,
  "sidebar-right": PanelRight,
  "file-tree": ListTree,
  loading: LoaderCircle,
  logout: LogOut,
  chevron: ChevronDown,
  "chevron-right": ChevronRight,
  stop: Square,
  send: ArrowUp,
  workspace: Folder,
  "folder-minus": FolderMinus,
  search: Search,
  plus: Plus,
  settings: Settings,
  shield: ShieldCheck,
  info: Info,
  "arrow-left": ArrowLeft,
  "arrow-down": ArrowDown,
  close: X,
  warning: TriangleAlert,
  account: UserRound,
  model: Layers3,
  box: Box,
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
