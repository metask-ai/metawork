import { useEffect, useState } from "react";
import type {
  FileDescriptionResult,
  FileTarget,
} from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import { formatFileSize } from "../../i18n/formatters.ts";
import { FileCard, fileName } from "./FileCard.tsx";
import {
  descriptionFailure,
  menuFile,
  type FileDescriber,
} from "./reply-files.ts";

/**
 * A file that was to be shown in place and cannot be. It is a card like any
 * other, whose size is asked for here, and never something to preview.
 */
export function DescribedFileCard({
  target,
  displayPath,
  openable,
  describe,
}: {
  target: FileTarget;
  displayPath: string;
  openable?: boolean;
  describe?: FileDescriber;
}) {
  const { locale, t } = useI18n();
  const identity = JSON.stringify(target);
  const [result, setResult] = useState<{
    identity: string;
    value: FileDescriptionResult;
  } | null>(null);
  useEffect(() => {
    if (!describe) return;
    const controller = new AbortController();
    describe(JSON.parse(identity) as FileTarget, {
      signal: controller.signal,
      priority: "prefetch",
    }).then(
      (value) => {
        if (!controller.signal.aborted) setResult({ identity, value });
      },
      () => {
        if (!controller.signal.aborted)
          setResult({ identity, value: { state: "error", file: null } });
      },
    );
    return () => controller.abort();
  }, [identity, describe]);
  const value = result?.identity === identity ? result.value : null;
  return (
    <FileCard
      name={fileName(displayPath)}
      detail={
        value === null
          ? []
          : [
              value.state === "ready"
                ? formatFileSize(locale, value.file.sizeBytes)
                : t(descriptionFailure(value.state)),
            ]
      }
      menu={menuFile(target, displayPath, {
        openable,
        available: value === null || value.state === "ready",
      })}
    />
  );
}
