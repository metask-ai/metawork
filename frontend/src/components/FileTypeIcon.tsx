import {
  File,
  FileArchive,
  FileAudio,
  FileCode,
  FileImage,
  FileSpreadsheet,
  FileText,
  FileVideo,
  Presentation,
  type LucideIcon,
} from "lucide-react";

type FileType = {
  kind:
    | "code"
    | "document"
    | "sheet"
    | "slides"
    | "pdf"
    | "archive"
    | "media"
    | "other";
  icon: LucideIcon;
};

// Decoration by name only. What a file is, whether it can be previewed and
// whether it can be opened are the Host's answers and never read from here.
const types: [FileType, string][] = [
  [
    { kind: "code", icon: FileCode },
    "html htm css js mjs ts tsx jsx json jsonl yaml yml toml xml py rb go rs zig java c h cpp cs php sh sql",
  ],
  [
    { kind: "document", icon: FileText },
    "md markdown txt log doc docx rtf odt srt vtt",
  ],
  [{ kind: "sheet", icon: FileSpreadsheet }, "xls xlsx ods csv tsv"],
  [{ kind: "slides", icon: Presentation }, "ppt pptx odp key"],
  [{ kind: "pdf", icon: FileText }, "pdf"],
  [{ kind: "archive", icon: FileArchive }, "zip 7z rar tar gz tgz bz2 xz"],
  [{ kind: "media", icon: FileVideo }, "mp4 m4v mov webm mkv avi mpg mpeg wmv"],
  [{ kind: "media", icon: FileAudio }, "mp3 wav m4a aac flac ogg oga opus"],
  [
    { kind: "media", icon: FileImage },
    "png jpg jpeg gif webp bmp tif tiff heic heif avif svg ico",
  ],
];
const other: FileType = { kind: "other", icon: File };
const byExtension = new Map(
  types.flatMap(([type, extensions]) =>
    extensions.split(" ").map((extension) => [extension, type] as const),
  ),
);

export function FileTypeIcon({ name }: { name: string }) {
  const dot = name.lastIndexOf(".");
  const type =
    (dot > 0 && byExtension.get(name.slice(dot + 1).toLowerCase())) || other;
  const Glyph = type.icon;
  return (
    <Glyph
      aria-hidden="true"
      className="file-type-icon"
      data-file-type={type.kind}
      strokeWidth={1.8}
    />
  );
}
